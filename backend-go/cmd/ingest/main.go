package main

import (
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/go-openapi/strfmt"
	"github.com/google/uuid"
	"github.com/ledongthuc/pdf"
	wmodels "github.com/weaviate/weaviate/entities/models"

	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/chunk"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/config"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/llm"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/weaviate"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	ctx := context.Background()
	cfg := config.Load()

	dataDir := cfg.DataDir
	if st, err := os.Stat(dataDir); err != nil || !st.IsDir() {
		log.Fatalf("DATA_DIR not a directory: %q (%v)", dataDir, err)
	}

	chunkSize := getenvIntPositive("CHUNK_SIZE", 800)
	overlap := getenvIntNonNegative("CHUNK_OVERLAP", 100)
	batchSize := getenvIntPositive("BATCH_WEAVIATE", 32)
	maxFiles := getenvIntNonNegative("MAX_FILES", 0)
	embedCap := getenvEmbedMaxRunes()
	splitSize := chunkSize
	if embedCap > 0 && splitSize > embedCap {
		splitSize = embedCap
	}

	wvClient, err := weaviate.NewClient(cfg.WeaviateHost, cfg.WeaviateScheme)
	if err != nil {
		log.Fatal(err)
	}
	if err := wvClient.EnsureSchema(ctx); err != nil {
		log.Fatal(err)
	}

	paths, err := collectPaths(dataDir, maxFiles)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("ingest: %d files under %s (chunk=%d split=%d overlap=%d embed_max_run=%d batch=%d)",
		len(paths), dataDir, chunkSize, splitSize, overlap, embedCap, batchSize)

	ollama := llm.NewOllamaClient(cfg.OllamaBaseURL, cfg.EmbeddingModel)

	var batch []*wmodels.Object
	totalChunks := 0
	globalIdx := 0

	for _, path := range paths {
		raw, err := loadText(path)
		if err != nil {
			log.Printf("skip %s: %v", path, err)
			continue
		}
		absPath, err := filepath.Abs(path)
		if err != nil {
			absPath = path
		}

		pieces := chunk.Split(strings.TrimSpace(raw), splitSize, overlap)
		for _, piece := range pieces {
			piece = strings.TrimSpace(piece)
			if piece == "" {
				continue
			}
			if embedCap > 0 {
				piece = truncateRunes(piece, embedCap)
				piece = strings.TrimSpace(piece)
				if piece == "" {
					continue
				}
			}

			vec, err := ollama.Embed(ctx, piece)
			if err != nil {
				log.Fatalf("embed chunk idx=%d file=%s: %v", globalIdx, absPath, err)
			}

			obj := &wmodels.Object{
				Class: weaviate.ClassName,
				ID:    chunkObjectID(absPath, globalIdx, piece),
				Properties: map[string]interface{}{
					"text":        piece,
					"source":      absPath,
					"chunk_index": globalIdx,
				},
				Vector: wmodels.C11yVector(vec),
			}
			batch = append(batch, obj)
			globalIdx++
			totalChunks++

			if len(batch) >= batchSize {
				if err := flushBatch(ctx, wvClient, batch); err != nil {
					log.Fatal(err)
				}
				log.Printf("progress: %d chunks written", totalChunks)
				batch = batch[:0]
			}
		}
	}

	if err := flushBatch(ctx, wvClient, batch); err != nil {
		log.Fatal(err)
	}
	log.Printf("done: %d chunks", totalChunks)
}

func flushBatch(ctx context.Context, client *weaviate.Client, batch []*wmodels.Object) error {
	if len(batch) == 0 {
		return nil
	}
	resp, err := client.BatchCreateObjects(ctx, batch)
	if err != nil {
		return err
	}
	for i, r := range resp {
		if r.Result == nil || r.Result.Status == nil {
			continue
		}
		if *r.Result.Status != wmodels.ObjectsGetResponseAO2ResultStatusSUCCESS {
			log.Printf("batch[%d]: status=%s errors=%v", i, *r.Result.Status, r.Result.Errors)
		}
	}
	return nil
}

func chunkObjectID(source string, chunkIdx int, textSample string) strfmt.UUID {
	rs := []rune(textSample)
	if len(rs) > 128 {
		textSample = string(rs[:128])
	}
	id := uuid.NewSHA1(uuid.NameSpaceDNS, []byte(fmt.Sprintf("%s|%d|%s", source, chunkIdx, textSample)))
	return strfmt.UUID(id.String())
}

func collectPaths(root string, maxFiles int) ([]string, error) {
	var paths []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if ext != ".pdf" && ext != ".txt" {
			return nil
		}
		paths = append(paths, path)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	if maxFiles > 0 && len(paths) > maxFiles {
		paths = paths[:maxFiles]
	}
	return paths, nil
}

func loadText(path string) (string, error) {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".txt":
		b, err := os.ReadFile(path)
		return string(b), err
	case ".pdf":
		f, r, err := pdf.Open(path)
		if err != nil {
			return "", err
		}
		defer f.Close()
		rd, err := r.GetPlainText()
		if err != nil {
			return "", err
		}
		var buf bytes.Buffer
		if _, err := buf.ReadFrom(rd); err != nil {
			return "", err
		}
		return buf.String(), nil
	default:
		return "", fmt.Errorf("unsupported extension %s", ext)
	}
}

func truncateRunes(s string, max int) string {
	if max <= 0 {
		return s
	}
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return strings.TrimSpace(string(r[:max]))
}

func getenvIntPositive(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func getenvIntNonNegative(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return fallback
	}
	return n
}

// getenvEmbedMaxRunes caps chunk length so Ollama's embedding model stays within its context window.
// Default 256 (conservative: some strings tokenize to many more tokens than rune count). Set EMBED_MAX_RUNES=0 to disable embedding cap (use CHUNK_SIZE only; may fail on token-heavy text).
func getenvEmbedMaxRunes() int {
	const defaultCap = 256
	v, ok := os.LookupEnv("EMBED_MAX_RUNES")
	if !ok {
		return defaultCap
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < 0 {
		return defaultCap
	}
	return n
}
