# Monad Staking Precompile ABI Setup

## 📋 Overview

This implementation automatically seeds the Monad Staking Precompile ABI into Blockscout's database, allowing proper decoding of staking-related transactions on the Monad blockchain.

**Precompile Address:** `0x0000000000000000000000000000000000001000`
**Display Name:** Staking Precompile

---

## 🏗️ Architecture

### Components Created

1. **ABI ConfigMap** (`templates/jobs/precompile-abi-configmap.yaml`)
   - Stores the complete Staking ABI JSON
   - Mounted into the seeding job pod at `/mnt/abi/staking_abi.json`

2. **SQL Script ConfigMap** (`templates/jobs/precompile-seed-sql-configmap.yaml`)
   - Contains idempotent SQL for inserting ABI into `smart_contracts` table
   - Uses PostgreSQL's `ON CONFLICT DO UPDATE` for safe re-runs
   - Includes verification query

3. **Kubernetes Job** (`templates/jobs/seed-precompile-abis-job.yaml`)
   - Runs as Helm hook: `post-install`, `post-upgrade`
   - Hook weight: `5` (runs before most other post-install hooks)
   - Automatically executes after every deployment
   - Uses `postgresql.image.*` configuration (same as database cluster)
   - Image is already cached from PostgreSQL pods (no redundant pulls)

4. **Configuration** (`values.yaml`)
   - New `precompile` section for configuration
   - Customizable job resources and timeouts
   - Easy to enable/disable via `precompile.enabled`

5. **JSON Schema** (`values.schema.json`)
   - Complete validation schema for `precompile` configuration
   - Ensures address format, resource limits, etc.

---

## 🚀 Deployment

### Automatic Deployment (Recommended)

The precompile ABI will be automatically seeded when you deploy or upgrade the chart:

```bash
# Deploy to production
helm upgrade --install monad-indexer charts/monad-indexer \
  -f environments/production/values-production.yaml \
  -n monad-indexer-prod

# The job will run automatically after deployment
```

### Manual Job Execution

If you need to manually trigger the seeding job:

```bash
# Delete existing job (if any)
kubectl delete job monad-indexer-seed-precompile-abis -n monad-indexer-prod

# Trigger Helm upgrade to recreate the job
helm upgrade monad-indexer charts/monad-indexer \
  -f environments/production/values-production.yaml \
  -n monad-indexer-prod
```

---

## 🔍 Verification

### 1. Check Job Status

```bash
# Check if the job completed successfully
kubectl get jobs -n monad-indexer-prod | grep seed-precompile

# View job logs
kubectl logs job/monad-indexer-seed-precompile-abis -n monad-indexer-prod
```

**Expected output:**
```
================================================================
SUCCESS: Precompile ABI seeded successfully!
Completed: 2025-11-08 16:30:00 UTC
================================================================
```

### 2. Verify in Database

```bash
# Connect to PostgreSQL
kubectl exec -it monad-indexer-postgresql-1 -n monad-indexer-prod -- \
  psql -U blockscout -d blockscout

# Query the precompile contract
SELECT
  encode(address_hash, 'hex') as address,
  name,
  compiler_version,
  jsonb_array_length(abi) as abi_entries
FROM smart_contracts
WHERE address_hash = decode('0000000000000000000000000000000000001000', 'hex');
```

**Expected result:**
```
                  address                   |       name        | compiler_version | abi_entries
--------------------------------------------+-------------------+------------------+-------------
 0000000000000000000000000000000000001000 | Staking Precompile | precompile      |          31
```

### 3. Verify in Blockscout UI

1. Navigate to: `https://monad-tn1-indexer.hoodscan.io/address/0x0000000000000000000000000000000000001000`
2. Check the **Contract** tab
3. You should see:
   - Contract name: **Staking Precompile**
   - All staking functions (delegate, undelegate, claimRewards, etc.)
   - All events (ValidatorCreated, Delegate, Undelegate, etc.)

4. Transaction decoding should now work automatically for all staking operations

---

## ⚙️ Configuration

### values.yaml

```yaml
precompile:
  enabled: true  # Set to false to disable seeding

  # Precompile contract details
  address: "0x0000000000000000000000000000000000001000"
  name: "Staking Precompile"

  # Job configuration
  job:
    # Note: Job uses postgresql.image.* configuration (same as pg-partman job)
    # This ensures consistency and avoids redundant image pulls

    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "256Mi"

    backoffLimit: 3          # Retry up to 3 times
    timeoutSeconds: 300      # 5 minute timeout

    nodeSelector: {}
    tolerations: []
```

### Container Image

The Job uses the same PostgreSQL image as your database cluster (configured at `postgresql.image.*`). This provides:
- **Image cache efficiency**: Image is already pulled by PostgreSQL pods
- **Version consistency**: Same PostgreSQL client version as your database
- **Simplified maintenance**: Single image configuration to manage

Default image: `ghcr.io/cloudnative-pg/postgresql:17`

### Customization

**To disable the seeding job:**
```yaml
precompile:
  enabled: false
```

**To adjust timeouts:**
```yaml
precompile:
  job:
    timeoutSeconds: 600  # 10 minutes
    backoffLimit: 5      # More retries
```

**To increase resources:**
```yaml
precompile:
  job:
    resources:
      requests:
        cpu: "200m"
        memory: "256Mi"
      limits:
        cpu: "1000m"
        memory: "512Mi"
```

---

## 🔧 Troubleshooting

### Job Fails: Database Not Ready

**Symptom:**
```
ERROR: Database not available after 30 attempts
```

**Solution:**
The job waits for PostgreSQL to be ready. If it still fails:
1. Increase `timeoutSeconds` in values.yaml
2. Check PostgreSQL pod status: `kubectl get pods -n monad-indexer-prod | grep postgresql`
3. Check PostgreSQL logs for issues

### Job Fails: Table Not Found

**Symptom:**
```
ERROR: smart_contracts table does not exist!
```

**Solution:**
This means Blockscout hasn't initialized the database schema yet.
1. Ensure the backend pod is running: `kubectl get pods -n monad-indexer-prod | grep backend`
2. Check backend logs for migration errors
3. The job will automatically retry when the table exists

### ABI Not Visible in UI

**Symptom:**
Job succeeds, but transactions aren't decoded in UI

**Solution:**
1. Verify database insertion (see Verification section above)
2. Clear Blockscout cache:
   ```bash
   kubectl exec -it monad-indexer-backend-0 -n monad-indexer-prod -- \
     redis-cli -h monad-indexer-redis-master FLUSHALL
   ```
3. Restart backend pods:
   ```bash
   kubectl rollout restart deployment/monad-indexer-backend -n monad-indexer-prod
   ```

### Need to Update ABI

**Scenario:**
The staking precompile ABI changes in a future Monad upgrade

**Solution:**
1. Update `/Users/errorist/Documents/new-projects/monad-indexer/abi/staking_abi.json`
2. Update the ABI in `templates/jobs/precompile-abi-configmap.yaml`
3. Deploy the update:
   ```bash
   helm upgrade monad-indexer charts/monad-indexer \
     -f environments/production/values-production.yaml \
     -n monad-indexer-prod
   ```
4. The job will re-run and update the ABI in the database

---

## 📊 SQL Schema Details

The precompile ABI is stored in the `smart_contracts` table with these values:

| Column                          | Value                                           |
|---------------------------------|------------------------------------------------|
| `address_hash`                  | `\x0000...1000` (bytea)                        |
| `name`                          | "Staking Precompile"                           |
| `abi`                           | Full ABI JSON array (31 entries)               |
| `compiler_version`              | "precompile"                                   |
| `optimization`                  | false                                          |
| `contract_source_code`          | Documentation comment                          |
| `is_vyper_contract`             | false                                          |
| `partially_verified`            | false                                          |
| `verified_via_sourcify`         | false                                          |
| `verified_via_eth_bytecode_db`  | false                                          |
| `verified_via_verifier_alliance`| false                                          |

---

## 🎯 Next Steps

### Adding More Precompiles

To add additional precompiles in the future:

1. Update `values.yaml` to support multiple precompiles:
   ```yaml
   precompile:
     enabled: true
     contracts:
       - address: "0x0000000000000000000000000000000000001000"
         name: "Staking Precompile"
         abiFile: "staking_abi.json"
       - address: "0x0000000000000000000000000000000000002000"
         name: "Governance Precompile"
         abiFile: "governance_abi.json"
   ```

2. Modify templates to loop over `contracts` array
3. Add new ABI files to ConfigMap

### Integration with CI/CD

The current setup works seamlessly with ArgoCD:
- Job runs automatically on every sync
- Idempotent design ensures safe re-runs
- No manual intervention required

---

## 📚 References

- [Blockscout Database Schema](https://blockscout.github.io/blockscout-db-schema/tables/smart_contracts.html)
- [Monad Staking Documentation](https://docs.monad.xyz/)
- [Helm Hooks Documentation](https://helm.sh/docs/topics/charts_hooks/)
- [CloudNative-PG](https://cloudnative-pg.io/)

---

## ✅ Implementation Checklist

- [x] Created ABI ConfigMap
- [x] Created SQL seed script ConfigMap
- [x] Created Kubernetes Job with Helm hooks
- [x] Added configuration to values.yaml
- [x] Updated values.schema.json for validation
- [x] Tested Helm template rendering
- [x] Validated JSON schema syntax
- [x] Documented deployment and verification steps

**Status:** ✅ Ready for deployment
