package metadata

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"time"
)

// UTF-8 BOM bytes
var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

// Parser handles metadata URI parsing and image URL extraction
type Parser struct {
	ipfsGateway string
	httpClient  *http.Client
}

// NewParser creates a new metadata parser
func NewParser(ipfsGateway string, timeout time.Duration) *Parser {
	return &Parser{
		ipfsGateway: ipfsGateway,
		httpClient: &http.Client{
			Timeout: timeout,
		},
	}
}

// NFTMetadata represents standard NFT metadata
type NFTMetadata struct {
	Name         string `json:"name"`
	Description  string `json:"description"`
	Image        string `json:"image"`
	ImageURL     string `json:"image_url"`
	AnimationURL string `json:"animation_url"`
	Properties   struct {
		Image string `json:"image"`
	} `json:"properties"`
}

// ResolveImageURL takes a tokenURI and resolves it to a final image URL
// tokenID is used to replace {id} placeholders
// tokenType should be "ERC-721" or "ERC-1155" to determine ID format
func (p *Parser) ResolveImageURL(ctx context.Context, tokenURI string, tokenID *big.Int, tokenType string) (string, error) {
	if tokenURI == "" {
		return "", fmt.Errorf("empty tokenURI")
	}

	// Replace {id} placeholder with actual token ID
	// ERC-1155 uses hex-padded format (64 char hex), ERC-721 uses decimal
	if strings.Contains(tokenURI, "{id}") {
		decimalID := tokenID.String()

		// Edge case: Some contracts return URI with {id} AND the token ID already appended
		// e.g., "https://api.example.com/metadata?tokenId={id}12345"
		// In this case, just remove {id} instead of replacing it
		if strings.Contains(tokenURI, "{id}"+decimalID) {
			tokenURI = strings.ReplaceAll(tokenURI, "{id}", "")
		} else {
			var idStr string
			if tokenType == "ERC-1155" {
				// ERC-1155 standard: 64 char hex without 0x prefix
				idStr = fmt.Sprintf("%064x", tokenID)
			} else {
				// ERC-721 or unknown: use decimal format
				idStr = decimalID
			}
			tokenURI = strings.ReplaceAll(tokenURI, "{id}", idStr)
		}
	}

	switch {
	case strings.HasPrefix(tokenURI, "ipfs://"):
		return p.resolveIPFS(ctx, tokenURI)

	case strings.HasPrefix(tokenURI, "https://"), strings.HasPrefix(tokenURI, "http://"):
		return p.resolveHTTP(ctx, tokenURI)

	case strings.HasPrefix(tokenURI, "data:application/json"):
		return p.resolveDataJSON(tokenURI)

	case strings.HasPrefix(tokenURI, "data:image/"):
		// Already an image data URI, return as-is
		return tokenURI, nil

	default:
		return "", fmt.Errorf("unsupported URI scheme: %s", tokenURI[:min(50, len(tokenURI))])
	}
}

// resolveIPFS converts an IPFS URI to HTTP and fetches metadata
func (p *Parser) resolveIPFS(ctx context.Context, ipfsURI string) (string, error) {
	// Convert ipfs:// to HTTP gateway URL
	// ipfs://CID/path -> https://ipfs.io/ipfs/CID/path
	path := strings.TrimPrefix(ipfsURI, "ipfs://")
	httpURL := p.ipfsGateway + path

	return p.resolveHTTP(ctx, httpURL)
}

// resolveHTTP fetches metadata from HTTP URL and extracts image
func (p *Parser) resolveHTTP(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", fmt.Errorf("creating request: %w", err)
	}

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("fetching URL: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP status %d", resp.StatusCode)
	}

	contentType := resp.Header.Get("Content-Type")

	// If response is an image, return the URL directly
	if strings.HasPrefix(contentType, "image/") {
		return url, nil
	}

	// Otherwise, parse as JSON metadata
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("reading response: %w", err)
	}

	return p.extractImageFromJSON(body)
}

// resolveDataJSON decodes a data:application/json URI and extracts image
func (p *Parser) resolveDataJSON(dataURI string) (string, error) {
	// Remove the data: prefix and get the content
	// Format: data:application/json;base64,<base64data>
	// or: data:application/json,<jsondata>

	content := strings.TrimPrefix(dataURI, "data:application/json")

	var jsonData []byte
	if strings.HasPrefix(content, ";base64,") {
		// Base64 encoded
		base64Data := strings.TrimPrefix(content, ";base64,")
		var err error
		jsonData, err = base64.StdEncoding.DecodeString(base64Data)
		if err != nil {
			return "", fmt.Errorf("decoding base64: %w", err)
		}
	} else if strings.HasPrefix(content, ",") {
		// URL encoded or plain JSON
		jsonData = []byte(strings.TrimPrefix(content, ","))
	} else {
		return "", fmt.Errorf("invalid data URI format")
	}

	return p.extractImageFromJSON(jsonData)
}

// extractImageFromJSON extracts the image URL from NFT metadata JSON
func (p *Parser) extractImageFromJSON(jsonData []byte) (string, error) {
	// Strip UTF-8 BOM if present (some servers add it incorrectly)
	jsonData = bytes.TrimPrefix(jsonData, utf8BOM)

	var metadata NFTMetadata
	if err := json.Unmarshal(jsonData, &metadata); err != nil {
		return "", fmt.Errorf("parsing metadata JSON: %w", err)
	}

	// Try different image fields in order of preference
	imageURL := metadata.Image
	if imageURL == "" {
		imageURL = metadata.ImageURL
	}
	if imageURL == "" && metadata.Properties.Image != "" {
		imageURL = metadata.Properties.Image
	}
	if imageURL == "" {
		imageURL = metadata.AnimationURL
	}

	if imageURL == "" {
		return "", fmt.Errorf("no image field found in metadata")
	}

	// If image is IPFS, convert to HTTP URL
	if strings.HasPrefix(imageURL, "ipfs://") {
		path := strings.TrimPrefix(imageURL, "ipfs://")
		imageURL = p.ipfsGateway + path
	}

	return imageURL, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
