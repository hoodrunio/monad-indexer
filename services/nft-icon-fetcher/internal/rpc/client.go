package rpc

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"time"
)

// Client is an Ethereum JSON-RPC client
type Client struct {
	rpcURL     string
	httpClient *http.Client
}

// NewClient creates a new RPC client
func NewClient(rpcURL string) *Client {
	return &Client{
		rpcURL: rpcURL,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// RPCRequest represents a JSON-RPC request
type RPCRequest struct {
	JSONRPC string        `json:"jsonrpc"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
	ID      int           `json:"id"`
}

// RPCResponse represents a JSON-RPC response
type RPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *RPCError       `json:"error"`
}

// RPCError represents a JSON-RPC error
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// GetTokenURI fetches the tokenURI for ERC-721 or uri for ERC-1155
// It tries tokenURI(tokenId) first, then uri(tokenId) if that fails
func (c *Client) GetTokenURI(ctx context.Context, contractAddress string, tokenID *big.Int) (string, error) {
	// Try ERC-721 tokenURI(uint256) first
	// Function selector: 0xc87b56dd
	uri, err := c.callTokenURIMethod(ctx, contractAddress, tokenID, "0xc87b56dd")
	if err == nil && uri != "" {
		return uri, nil
	}

	// Try ERC-1155 uri(uint256)
	// Function selector: 0x0e89341c
	uri, err = c.callTokenURIMethod(ctx, contractAddress, tokenID, "0x0e89341c")
	if err == nil && uri != "" {
		return uri, nil
	}

	return "", fmt.Errorf("could not fetch tokenURI: %w", err)
}

func (c *Client) callTokenURIMethod(ctx context.Context, contractAddress string, tokenID *big.Int, selector string) (string, error) {
	// Encode the call data: selector + tokenId (padded to 32 bytes)
	tokenIDBytes := tokenID.Bytes()
	paddedTokenID := make([]byte, 32)
	copy(paddedTokenID[32-len(tokenIDBytes):], tokenIDBytes)

	callData := selector + hex.EncodeToString(paddedTokenID)

	// Prepare eth_call parameters
	callParams := map[string]string{
		"to":   contractAddress,
		"data": callData,
	}

	req := RPCRequest{
		JSONRPC: "2.0",
		Method:  "eth_call",
		Params:  []interface{}{callParams, "latest"},
		ID:      1,
	}

	jsonData, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("marshaling request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", c.rpcURL, bytes.NewReader(jsonData))
	if err != nil {
		return "", fmt.Errorf("creating request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("executing request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading response: %w", err)
	}

	var rpcResp RPCResponse
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return "", fmt.Errorf("parsing response: %w", err)
	}

	if rpcResp.Error != nil {
		return "", fmt.Errorf("RPC error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}

	// Parse the result - it's an ABI-encoded string
	uri, err := decodeABIString(rpcResp.Result)
	if err != nil {
		return "", fmt.Errorf("decoding ABI string: %w", err)
	}

	return uri, nil
}

// decodeABIString decodes an ABI-encoded string from hex
func decodeABIString(result json.RawMessage) (string, error) {
	var hexStr string
	if err := json.Unmarshal(result, &hexStr); err != nil {
		return "", err
	}

	// Remove 0x prefix
	hexStr = strings.TrimPrefix(hexStr, "0x")

	if len(hexStr) < 128 {
		return "", fmt.Errorf("response too short")
	}

	// Decode hex to bytes
	data, err := hex.DecodeString(hexStr)
	if err != nil {
		return "", err
	}

	// ABI string encoding:
	// - First 32 bytes: offset to string data (usually 0x20 = 32)
	// - Next 32 bytes at offset: length of string
	// - Following bytes: string data

	if len(data) < 64 {
		return "", fmt.Errorf("data too short for ABI string")
	}

	// Read offset (first 32 bytes)
	offset := new(big.Int).SetBytes(data[0:32]).Uint64()
	if offset >= uint64(len(data)) {
		return "", fmt.Errorf("invalid offset")
	}

	// Read length at offset
	if offset+32 > uint64(len(data)) {
		return "", fmt.Errorf("data too short for length")
	}
	length := new(big.Int).SetBytes(data[offset : offset+32]).Uint64()

	// Read string data
	stringStart := offset + 32
	stringEnd := stringStart + length
	if stringEnd > uint64(len(data)) {
		return "", fmt.Errorf("data too short for string content")
	}

	return string(data[stringStart:stringEnd]), nil
}
