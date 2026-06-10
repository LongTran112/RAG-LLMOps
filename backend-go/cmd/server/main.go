package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/api"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/config"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/llm"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/rag"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/weaviate"
)

func main() {
	cfg := config.Load()

	wvClient, err := weaviate.NewClient(cfg.WeaviateHost, cfg.WeaviateScheme)
	if err != nil {
		log.Fatalf("weaviate client: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := wvClient.EnsureSchema(ctx); err != nil {
		log.Fatalf("weaviate schema: %v", err)
	}

	llmClient := llm.NewOllamaClient(cfg.OllamaBaseURL, cfg.EmbeddingModel)
	pipeline := rag.NewPipeline(cfg, llmClient, wvClient)
	router := api.NewRouter(pipeline)

	srv := &http.Server{
		Addr:              cfg.HTTPListenAddr,
		Handler:           router,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       5 * time.Minute,
		WriteTimeout:      15 * time.Minute,
	}

	go func() {
		log.Printf("backend-go listening on %s", cfg.HTTPListenAddr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server: %v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}
