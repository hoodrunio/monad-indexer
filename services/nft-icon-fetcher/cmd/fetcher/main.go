package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/hoodrunio/nft-icon-fetcher/internal/blockscout"
	"github.com/hoodrunio/nft-icon-fetcher/internal/db"
	"github.com/hoodrunio/nft-icon-fetcher/internal/fetcher"
	"github.com/hoodrunio/nft-icon-fetcher/internal/rpc"
)

func main() {
	log.Println("NFT Icon Fetcher starting...")

	// Load configuration from environment
	config := loadConfig()

	// Create context with cancellation
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Println("Shutdown signal received, stopping...")
		cancel()
	}()

	// Initialize database client
	dbClient, err := db.NewClient(config.DatabaseURL)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer dbClient.Close()

	// Initialize other clients
	blockscoutClient := blockscout.NewClient(config.BlockscoutAPIURL, config.BlockscoutAPIKey)
	rpcClient := rpc.NewClient(config.RPCURL)

	// Create fetcher
	f := fetcher.New(fetcher.Config{
		DBClient:         dbClient,
		BlockscoutClient: blockscoutClient,
		RPCClient:        rpcClient,
		IPFSGateway:      config.IPFSGateway,
		Concurrency:      config.Concurrency,
		RequestTimeout:   config.RequestTimeout,
		DryRun:           config.DryRun,
		Limit:            config.Limit,
		OutputFile:       config.OutputFile,
	})

	// Run fetcher
	if err := f.Run(ctx); err != nil {
		log.Fatalf("Fetcher failed: %v", err)
	}

	log.Println("NFT Icon Fetcher completed successfully")
}

type Config struct {
	DatabaseURL      string
	BlockscoutAPIURL string
	BlockscoutAPIKey string
	RPCURL           string
	IPFSGateway      string
	Concurrency      int
	RequestTimeout   time.Duration
	DryRun           bool
	Limit            int
	OutputFile       string
}

func loadConfig() Config {
	return Config{
		DatabaseURL:      getEnv("DATABASE_URL", ""),
		BlockscoutAPIURL: getEnv("BLOCKSCOUT_API_URL", "https://monad-mainnet-indexer.hoodscan.io/api/v2"),
		BlockscoutAPIKey: getEnv("BLOCKSCOUT_API_KEY", ""),
		RPCURL:           getEnv("RPC_URL", "https://monad-rpc.huginn.tech"),
		IPFSGateway:      getEnv("IPFS_GATEWAY", "https://ipfs.io/ipfs/"),
		Concurrency:      getEnvInt("CONCURRENCY", 5),
		RequestTimeout:   time.Duration(getEnvInt("REQUEST_TIMEOUT_SECONDS", 30)) * time.Second,
		DryRun:           getEnvBool("DRY_RUN", false),
		Limit:            getEnvInt("LIMIT", 0), // 0 = no limit
		OutputFile:       getEnv("OUTPUT_FILE", "results.json"),
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
	}
	return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
	if value := os.Getenv(key); value != "" {
		if boolVal, err := strconv.ParseBool(value); err == nil {
			return boolVal
		}
	}
	return defaultValue
}
