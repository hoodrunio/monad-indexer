package blockscout

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Token represents a token from database
type Token struct {
	Address string
	Name    string
	Symbol  string
	Type    string
}

// Client is a Blockscout API client (for updates only)
type Client struct {
	baseURL    string
	apiKey     string
	httpClient *http.Client
}

// NewClient creates a new Blockscout API client
func NewClient(baseURL, apiKey string) *Client {
	return &Client{
		baseURL: baseURL,
		apiKey:  apiKey,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// UpdateTokenIcon updates ONLY the icon_url via the admin API
// Uses the token's existing name/symbol from DB to avoid overwriting with wrong values
func (c *Client) UpdateTokenIcon(ctx context.Context, token Token, iconURL string) error {
	endpoint := fmt.Sprintf("%s/import/token-info", c.baseURL)

	// Build payload with DB values - only icon_url is new
	// Blockscout API requires all fields but ignores empty strings for name/symbol
	payload := map[string]string{
		"token_address": token.Address,
		"icon_url":      iconURL,
		"token_symbol":  token.Symbol, // From DB - keeps existing value
		"token_name":    token.Name,   // From DB - keeps existing value
		"api_key":       c.apiKey,
	}

	jsonData, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshaling payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", endpoint, bytes.NewReader(jsonData))
	if err != nil {
		return fmt.Errorf("creating request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("executing request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %d: %s", resp.StatusCode, string(body))
	}

	return nil
}
