package fetcher

import (
	"context"
	"encoding/json"
	"log"
	"math/big"
	"os"
	"sync"
	"time"

	"github.com/hoodrunio/nft-icon-fetcher/internal/blockscout"
	"github.com/hoodrunio/nft-icon-fetcher/internal/db"
	"github.com/hoodrunio/nft-icon-fetcher/internal/metadata"
	"github.com/hoodrunio/nft-icon-fetcher/internal/rpc"
)

// Config holds the fetcher configuration
type Config struct {
	DBClient         *db.Client
	BlockscoutClient *blockscout.Client
	RPCClient        *rpc.Client
	IPFSGateway      string
	Concurrency      int
	RequestTimeout   time.Duration
	DryRun           bool
	Limit            int
	OutputFile       string
}

// Fetcher handles fetching and updating NFT icons
type Fetcher struct {
	db             *db.Client
	blockscout     *blockscout.Client
	rpc            *rpc.Client
	metadataParser *metadata.Parser
	concurrency    int
	dryRun         bool
	limit          int
	outputFile     string
}

// New creates a new Fetcher
func New(cfg Config) *Fetcher {
	return &Fetcher{
		db:             cfg.DBClient,
		blockscout:     cfg.BlockscoutClient,
		rpc:            cfg.RPCClient,
		metadataParser: metadata.NewParser(cfg.IPFSGateway, cfg.RequestTimeout),
		concurrency:    cfg.Concurrency,
		dryRun:         cfg.DryRun,
		limit:          cfg.Limit,
		outputFile:     cfg.OutputFile,
	}
}

// TokenJob represents a token to process
type TokenJob struct {
	Token blockscout.Token
}

// TokenResult represents the result of processing a token
type TokenResult struct {
	Token    blockscout.Token
	ImageURL string
	TokenURI string
	Error    error
}

// OutputResult represents the output JSON structure
type OutputResult struct {
	Address  string `json:"address"`
	Name     string `json:"name"`
	Symbol   string `json:"symbol"`
	Type     string `json:"type"`
	TokenURI string `json:"token_uri,omitempty"`
	ImageURL string `json:"image_url,omitempty"`
	Error    string `json:"error,omitempty"`
	Status   string `json:"status"`
}

// Run executes the fetcher
func (f *Fetcher) Run(ctx context.Context) error {
	if f.dryRun {
		log.Println("[DRY RUN MODE] Results will be written to file, no DB updates")
	}

	log.Println("Fetching NFT tokens without icons from database...")

	// Get tokens without icon_url from database
	tokens, err := f.db.GetNFTTokensWithoutIcon(ctx, f.limit)
	if err != nil {
		return err
	}

	log.Printf("Found %d NFT tokens without icons", len(tokens))

	if len(tokens) == 0 {
		log.Println("No tokens to process")
		return nil
	}

	// Create job and result channels
	jobs := make(chan TokenJob, len(tokens))
	results := make(chan TokenResult, len(tokens))

	// Start workers
	var wg sync.WaitGroup
	for i := 0; i < f.concurrency; i++ {
		wg.Add(1)
		go f.worker(ctx, &wg, jobs, results)
	}

	// Send jobs
	for _, token := range tokens {
		jobs <- TokenJob{Token: token}
	}
	close(jobs)

	// Wait for workers to finish
	go func() {
		wg.Wait()
		close(results)
	}()

	// Collect results
	var outputResults []OutputResult
	var successCount, failCount int

	for result := range results {
		outResult := OutputResult{
			Address:  result.Token.Address,
			Name:     result.Token.Name,
			Symbol:   result.Token.Symbol,
			Type:     result.Token.Type,
			TokenURI: result.TokenURI,
		}

		if result.Error != nil {
			log.Printf("Failed to process %s (%s): %v", result.Token.Symbol, result.Token.Address, result.Error)
			outResult.Error = result.Error.Error()
			outResult.Status = "failed"
			failCount++
		} else {
			outResult.ImageURL = result.ImageURL
			outResult.Status = "success"
			successCount++

			if !f.dryRun {
				// Update token icon in Blockscout (only icon_url, preserves existing name/symbol)
				err := f.blockscout.UpdateTokenIcon(ctx, result.Token, result.ImageURL)
				if err != nil {
					log.Printf("Failed to update %s (%s): %v", result.Token.Symbol, result.Token.Address, err)
					outResult.Error = "update failed: " + err.Error()
					outResult.Status = "update_failed"
				} else {
					log.Printf("Updated %s (%s) -> %s", result.Token.Symbol, result.Token.Address, truncateURL(result.ImageURL))
				}
			} else {
				log.Printf("[DRY RUN] Would update %s (%s) -> %s", result.Token.Symbol, result.Token.Address, truncateURL(result.ImageURL))
			}
		}

		outputResults = append(outputResults, outResult)
	}

	// Write results to file
	if f.outputFile != "" {
		if err := f.writeResults(outputResults); err != nil {
			log.Printf("Failed to write results file: %v", err)
		} else {
			log.Printf("Results written to %s", f.outputFile)
		}
	}

	log.Printf("Completed: %d success, %d failed", successCount, failCount)
	return nil
}

// writeResults writes the results to a JSON file
func (f *Fetcher) writeResults(results []OutputResult) error {
	data, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(f.outputFile, data, 0644)
}

// worker processes tokens from the jobs channel
func (f *Fetcher) worker(ctx context.Context, wg *sync.WaitGroup, jobs <-chan TokenJob, results chan<- TokenResult) {
	defer wg.Done()

	for job := range jobs {
		select {
		case <-ctx.Done():
			return
		default:
		}

		tokenURI, imageURL, err := f.processToken(ctx, job.Token)
		results <- TokenResult{
			Token:    job.Token,
			TokenURI: tokenURI,
			ImageURL: imageURL,
			Error:    err,
		}
	}
}

// processToken fetches the token URI and resolves it to an image URL
func (f *Fetcher) processToken(ctx context.Context, token blockscout.Token) (tokenURI string, imageURL string, err error) {
	// Build list of token IDs to try
	var tokenIDs []*big.Int

	// For ERC-1155 tokens, try to get a real token instance ID from DB first
	if token.Type == "ERC-1155" {
		realID, err := f.db.GetFirstTokenInstanceID(ctx, token.Address)
		if err == nil && realID != nil {
			tokenIDs = append(tokenIDs, realID)
		}
	}

	// Fallback token IDs (1, 0, 2)
	tokenIDs = append(tokenIDs, big.NewInt(1), big.NewInt(0), big.NewInt(2))

	var lastErr error
	for _, tokenID := range tokenIDs {
		// Get tokenURI from contract
		uri, uriErr := f.rpc.GetTokenURI(ctx, token.Address, tokenID)
		if uriErr != nil {
			lastErr = uriErr
			continue
		}

		if uri == "" {
			continue
		}

		tokenURI = uri

		// Resolve tokenURI to image URL (pass tokenID and type for {id} placeholder replacement)
		imgURL, imgErr := f.metadataParser.ResolveImageURL(ctx, uri, tokenID, token.Type)
		if imgErr != nil {
			lastErr = imgErr
			continue
		}

		if imgURL != "" {
			return tokenURI, imgURL, nil
		}
	}

	if lastErr != nil {
		return tokenURI, "", lastErr
	}
	return tokenURI, "", nil
}

// truncateURL truncates URL for logging
func truncateURL(url string) string {
	if len(url) > 80 {
		return url[:77] + "..."
	}
	return url
}
