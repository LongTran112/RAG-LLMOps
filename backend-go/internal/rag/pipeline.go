package rag

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/config"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/llm"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/models"
	wv "github.com/LongTran112/RAG-LLMOps/backend-go/internal/weaviate"
)

type Pipeline struct {
	cfg      *config.Config
	llm      *llm.OllamaClient
	weaviate *wv.Client
}

func NewPipeline(cfg *config.Config, l *llm.OllamaClient, w *wv.Client) *Pipeline {
	return &Pipeline{cfg: cfg, llm: l, weaviate: w}
}

func (p *Pipeline) resolveModel(answerMode string) string {
	mode := strings.ToLower(strings.TrimSpace(answerMode))
	if mode == "complex" {
		return p.cfg.ReasoningModel
	}
	return p.cfg.PrimaryModel
}

func buildPrompt(query string, sources []models.Source) string {
	var b strings.Builder
	b.WriteString("You are a helpful assistant for a master's thesis RAG PoC.\n")
	b.WriteString("Use the context to answer the question. If context is insufficient, say so.\n")
	b.WriteString("Be concise when the question allows it.\n\nContext:\n")

	for _, s := range sources {
		b.WriteString(s.ContentPreview)
		b.WriteString("\n\n")
	}

	b.WriteString("Question:\n")
	b.WriteString(query)
	b.WriteString("\n\nAnswer:")
	return b.String()
}

func (p *Pipeline) Query(ctx context.Context, req models.QueryRequest) (*models.QueryResponse, error) {
	t0 := time.Now()

	vector, err := p.llm.Embed(ctx, req.Query)
	if err != nil {
		return nil, fmt.Errorf("embedding failed: %w", err)
	}
	tEmbed := time.Since(t0)

	tSearchStart := time.Now()
	sources, err := p.weaviate.Search(ctx, vector, p.cfg.RetrieveTopK)
	if err != nil {
		return nil, fmt.Errorf("search failed: %w", err)
	}
	tSearch := time.Since(tSearchStart)

	prompt := buildPrompt(req.Query, sources)
	model := p.resolveModel(req.AnswerMode)

	genStart := time.Now()
	answer, err := p.llm.Generate(ctx, prompt, model)
	genDur := time.Since(genStart)

	timing := models.Timing{
		Embedding:      tEmbed.Milliseconds(),
		WeaviateSearch: tSearch.Milliseconds(),
		RetrievalTotal: time.Since(t0).Milliseconds(),
		Generation:     genDur.Milliseconds(),
	}

	if err != nil {
		return &models.QueryResponse{
			Answer:  "[LLM unavailable, returning retrieved context only]",
			Sources: sources,
			LLM: models.LLMStats{
				ModelUsed: "",
				Attempts:  1,
				Fallback:  false,
			},
			TimingMS: timing,
		}, nil
	}

	return &models.QueryResponse{
		Answer:   answer,
		Sources:  sources,
		LLM:      models.LLMStats{ModelUsed: model, Attempts: 1, Fallback: false},
		TimingMS: timing,
	}, nil
}

func (p *Pipeline) RetrieveOnly(ctx context.Context, req models.QueryRequest) (*models.QueryResponse, error) {
	t0 := time.Now()

	vector, err := p.llm.Embed(ctx, req.Query)
	if err != nil {
		return nil, fmt.Errorf("embedding failed: %w", err)
	}
	tEmbed := time.Since(t0)

	tSearchStart := time.Now()
	sources, err := p.weaviate.Search(ctx, vector, p.cfg.RetrieveTopK)
	if err != nil {
		return nil, fmt.Errorf("search failed: %w", err)
	}
	tSearch := time.Since(tSearchStart)

	return &models.QueryResponse{
		Sources: sources,
		TimingMS: models.Timing{
			Embedding:      tEmbed.Milliseconds(),
			WeaviateSearch: tSearch.Milliseconds(),
			RetrievalTotal: time.Since(t0).Milliseconds(),
		},
	}, nil
}

func (p *Pipeline) StreamQuery(ctx context.Context, req models.QueryRequest, onEvent func(eventType, payload string) error) error {
	t0 := time.Now()

	vector, err := p.llm.Embed(ctx, req.Query)
	if err != nil {
		return fmt.Errorf("embedding failed: %w", err)
	}
	tEmbed := time.Since(t0)

	tSearchStart := time.Now()
	sources, err := p.weaviate.Search(ctx, vector, p.cfg.RetrieveTopK)
	if err != nil {
		return fmt.Errorf("search failed: %w", err)
	}
	tSearch := time.Since(tSearchStart)

	sourcesJSON, err := json.Marshal(sources)
	if err != nil {
		return err
	}
	if err := onEvent("sources", string(sourcesJSON)); err != nil {
		return err
	}

	prompt := buildPrompt(req.Query, sources)
	model := p.resolveModel(req.AnswerMode)

	genStart := time.Now()
	err = p.llm.GenerateStream(ctx, prompt, model, func(token string) error {
		payload, _ := json.Marshal(map[string]string{"t": token})
		return onEvent("token", string(payload))
	})
	genDur := time.Since(genStart)
	if err != nil {
		return err
	}

	timing := models.Timing{
		Embedding:      tEmbed.Milliseconds(),
		WeaviateSearch: tSearch.Milliseconds(),
		RetrievalTotal: time.Since(t0).Milliseconds(),
		Generation:     genDur.Milliseconds(),
	}
	timingJSON, err := json.Marshal(timing)
	if err != nil {
		return err
	}
	return onEvent("timing", string(timingJSON))
}
