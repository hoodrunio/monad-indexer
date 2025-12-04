#!/bin/bash
#
# Contract Code Backfill Script
#
# Bu script, boş contract_code olan kontratları RPC'den fetch edip DB'ye yazar.
#
# Kullanım:
#   ./backfill-contract-codes.sh [--dry-run] [--limit N]
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# RPC endpoints
RPC1="https://rpc3.monad.xyz"
RPC2="https://rpc1.monad.xyz"
RPC3="https://rpc-mainnet.monadinfra.com"
RPC4="https://rpc.monad.xyz"

# Database connection
DB_HOST="${DB_HOST:-monad-indexer-production-pooler}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-blockscout}"
DB_USER="${DB_USER:-blockscout}"
DB_PASS="${DB_PASS:-hOGqmZSflFzlY3EjRZBpOFFEJT6M2EEsMDLQK2D78o}"

# Script settings
LIMIT=""
DRY_RUN=false
RPC_TIMEOUT=5

# Counters
SUCCESS=0
FAILED=0
SKIPPED=0

# ============================================================================
# Argument parsing
# ============================================================================

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ============================================================================
# Helper functions
# ============================================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

psql_cmd() {
  PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A "$@"
}

to_hex() {
  printf "0x%x" "$1"
}

# Fetch code from a single RPC
try_rpc() {
  local rpc="$1"
  local address="$2"
  local block="$3"

  local response
  response=$(curl -s --max-time $RPC_TIMEOUT -X POST "$rpc" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"0x$address\",\"$block\"],\"id\":1}" 2>/dev/null || echo "")

  if [[ -n "$response" ]] && ! echo "$response" | grep -q '"error"'; then
    local code=$(echo "$response" | grep -o '"result":"[^"]*"' | sed 's/"result":"//;s/"$//')
    if [[ -n "$code" && "$code" != "0x" ]]; then
      echo "$code"
      return 0
    fi
  fi
  return 1
}

# Fetch contract code - try all RPCs with historical then latest
fetch_code() {
  local address="$1"
  local block_hex="$2"
  local code

  # Try historical block first
  for rpc in "$RPC1" "$RPC2" "$RPC3" "$RPC4"; do
    if code=$(try_rpc "$rpc" "$address" "$block_hex"); then
      echo "$code"
      return 0
    fi
  done

  # Fallback to latest
  for rpc in "$RPC1" "$RPC2" "$RPC3" "$RPC4"; do
    if code=$(try_rpc "$rpc" "$address" "latest"); then
      echo "$code"
      return 0
    fi
  done

  return 1
}

# ============================================================================
# Main logic
# ============================================================================

main() {
  log "Starting contract code backfill"
  log "Dry run: $DRY_RUN"
  [[ -n "$LIMIT" ]] && log "Limit: $LIMIT"

  # Build query
  local limit_clause=""
  [[ -n "$LIMIT" ]] && limit_clause="LIMIT $LIMIT"

  # Get contracts needing code
  log "Fetching contracts with missing code..."

  local contracts
  contracts=$(psql_cmd -c "
    SELECT
      encode(t.created_contract_address_hash, 'hex') as address,
      t.block_number
    FROM transactions t
    JOIN addresses a ON a.hash = t.created_contract_address_hash
    WHERE t.created_contract_address_hash IS NOT NULL
      AND t.status = 1
      AND (a.contract_code IS NULL OR length(a.contract_code) = 0)
    ORDER BY t.block_number DESC
    $limit_clause;
  ")

  local total=$(echo "$contracts" | grep -c '|' || echo 0)
  log "Found $total contracts to process"

  if [[ $total -eq 0 ]]; then
    log "No contracts to process"
    exit 0
  fi

  local count=0
  echo "$contracts" | while IFS='|' read -r address block_number; do
    [[ -z "$address" ]] && continue

    ((count++)) || true

    local block_hex=$(to_hex "$block_number")
    local code

    if code=$(fetch_code "$address" "$block_hex"); then
      if [[ "$DRY_RUN" == "true" ]]; then
        log "[$count/$total] 0x$address: would update (${#code} chars)"
        ((SUCCESS++)) || true
      else
        # Update DB
        if PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c "
          UPDATE addresses
          SET contract_code = decode('${code#0x}', 'hex'), updated_at = NOW()
          WHERE hash = decode('$address', 'hex')
            AND (contract_code IS NULL OR length(contract_code) = 0);
        " 2>/dev/null; then
          log "[$count/$total] 0x$address: updated (${#code} chars)"
          ((SUCCESS++)) || true
        else
          log "[$count/$total] 0x$address: DB error"
          ((FAILED++)) || true
        fi
      fi
    else
      log "[$count/$total] 0x$address: no code found (skipped)"
      ((SKIPPED++)) || true
    fi

    # Progress every 100
    if [[ $((count % 100)) -eq 0 ]]; then
      log "Progress: $count/$total processed"
    fi
  done

  log "Completed! success=$SUCCESS failed=$FAILED skipped=$SKIPPED"
}

# ============================================================================
# Entry point
# ============================================================================

main "$@"
