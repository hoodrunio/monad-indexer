package db

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"

	_ "github.com/lib/pq"

	"github.com/hoodrunio/nft-icon-fetcher/internal/blockscout"
)

// Client is a PostgreSQL client for reading tokens
type Client struct {
	db *sql.DB
}

// NewClient creates a new database client
func NewClient(databaseURL string) (*Client, error) {
	db, err := sql.Open("postgres", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("opening database: %w", err)
	}

	// Test connection
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("pinging database: %w", err)
	}

	return &Client{db: db}, nil
}

// Close closes the database connection
func (c *Client) Close() error {
	return c.db.Close()
}

// GetNFTTokensWithoutIcon fetches ERC-721 and ERC-1155 tokens without icon_url
func (c *Client) GetNFTTokensWithoutIcon(ctx context.Context, limit int) ([]blockscout.Token, error) {
	query := `
		SELECT
			encode(contract_address_hash, 'hex') as address,
			COALESCE(name, '') as name,
			COALESCE(symbol, '') as symbol,
			type
		FROM tokens
		WHERE type IN ('ERC-721', 'ERC-1155')
		AND (icon_url IS NULL OR icon_url = '')
		ORDER BY holder_count DESC NULLS LAST
	`

	if limit > 0 {
		query += fmt.Sprintf(" LIMIT %d", limit)
	}

	rows, err := c.db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("querying tokens: %w", err)
	}
	defer rows.Close()

	var tokens []blockscout.Token
	for rows.Next() {
		var token blockscout.Token
		if err := rows.Scan(&token.Address, &token.Name, &token.Symbol, &token.Type); err != nil {
			return nil, fmt.Errorf("scanning token: %w", err)
		}
		// Add 0x prefix to address
		token.Address = "0x" + token.Address
		tokens = append(tokens, token)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterating tokens: %w", err)
	}

	return tokens, nil
}

// GetFirstTokenInstanceID returns the first token_id from token_instances for a given contract
// This is useful for ERC-1155 tokens where we need a real token ID to fetch metadata
func (c *Client) GetFirstTokenInstanceID(ctx context.Context, contractAddress string) (*big.Int, error) {
	// Remove 0x prefix if present
	address := contractAddress
	if len(address) > 2 && address[:2] == "0x" {
		address = address[2:]
	}

	query := `
		SELECT token_id
		FROM token_instances
		WHERE token_contract_address_hash = decode($1, 'hex')
		LIMIT 1
	`

	var tokenIDStr string
	err := c.db.QueryRowContext(ctx, query, address).Scan(&tokenIDStr)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, nil // No instances found
		}
		return nil, fmt.Errorf("querying token instance: %w", err)
	}

	tokenID := new(big.Int)
	tokenID.SetString(tokenIDStr, 10)
	return tokenID, nil
}
