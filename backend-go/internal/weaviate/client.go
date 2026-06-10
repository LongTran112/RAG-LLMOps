package weaviate

import (
	"context"
	"fmt"

	wmodels "github.com/weaviate/weaviate/entities/models"
	"github.com/weaviate/weaviate-go-client/v4/weaviate"
	"github.com/weaviate/weaviate-go-client/v4/weaviate/graphql"

	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/models"
)

type Client struct {
	wv      *weaviate.Client
	baseURL string // for error hints only
}

const ClassName = "DocumentChunk"

func NewClient(host, scheme string) (*Client, error) {
	cfg := weaviate.Config{
		Host:   host,
		Scheme: scheme,
	}
	client, err := weaviate.NewClient(cfg)
	if err != nil {
		return nil, err
	}
	return &Client{wv: client, baseURL: scheme + "://" + host}, nil
}

func (c *Client) EnsureSchema(ctx context.Context) error {
	if _, err := c.wv.Misc().MetaGetter().Do(ctx); err != nil {
		return fmt.Errorf(
			"weaviate REST API not reachable at %s (GET /v1/meta failed): %w\n"+
				"hint: start Weaviate first (e.g. from repo root: docker compose up -d weaviate).\n"+
				"WEAVIATE_HOST must be hostname:port only (no http://). WEAVIATE_SCHEME must match (http/https).",
			c.baseURL, err,
		)
	}

	ready, err := c.wv.Misc().ReadyChecker().Do(ctx)
	if err != nil {
		return fmt.Errorf("weaviate readiness check failed at %s: %w", c.baseURL, err)
	}
	if !ready {
		return fmt.Errorf("weaviate not ready at %s (/.well-known/ready returned false)", c.baseURL)
	}

	ok, err := c.wv.Schema().ClassExistenceChecker().WithClassName(ClassName).Do(ctx)
	if err != nil {
		return fmt.Errorf("check class existence: %w", err)
	}
	if ok {
		return nil
	}

	classObj := &wmodels.Class{
		Class:       ClassName,
		Description: "RAG document chunks (vectors supplied by application)",
		Vectorizer:  "none",
		Properties: []*wmodels.Property{
			{Name: "text", DataType: []string{"text"}},
			{Name: "source", DataType: []string{"text"}},
			{Name: "chunk_index", DataType: []string{"int"}},
		},
	}

	err = c.wv.Schema().ClassCreator().WithClass(classObj).Do(ctx)
	if err != nil {
		return fmt.Errorf(
			"create class %s at %s: %w\n"+
				"hint: confirm this URL is Weaviate (curl %s/v1/meta). If you use another port/proxy, fix WEAVIATE_HOST / WEAVIATE_SCHEME.",
			ClassName, c.baseURL, err, c.baseURL,
		)
	}
	return nil
}

func (c *Client) Search(ctx context.Context, vector []float32, topK int) ([]models.Source, error) {
	nearVector := c.wv.GraphQL().NearVectorArgBuilder().WithVector(vector)

	fields := []graphql.Field{
		{Name: "text"},
		{Name: "source"},
		{Name: "chunk_index"},
		{
			Name: "_additional",
			Fields: []graphql.Field{
				{Name: "certainty"},
				{Name: "distance"},
			},
		},
	}

	result, err := c.wv.GraphQL().Get().
		WithClassName(ClassName).
		WithNearVector(nearVector).
		WithLimit(topK).
		WithFields(fields...).
		Do(ctx)
	if err != nil {
		return nil, err
	}

	getMap, ok := result.Data["Get"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("unexpected graphql shape: missing Get")
	}

	rawChunks, ok := getMap[ClassName].([]interface{})
	if !ok || rawChunks == nil {
		return []models.Source{}, nil
	}

	out := make([]models.Source, 0, len(rawChunks))
	for _, rc := range rawChunks {
		item, ok := rc.(map[string]interface{})
		if !ok {
			continue
		}

		text, _ := item["text"].(string)
		source, _ := item["source"].(string)

		var chunkIdx int
		switch v := item["chunk_index"].(type) {
		case float64:
			chunkIdx = int(v)
		case int:
			chunkIdx = v
		case int64:
			chunkIdx = int(v)
		}

		var score float32
		if add, ok := item["_additional"].(map[string]interface{}); ok {
			if cert, ok := add["certainty"].(float64); ok {
				score = float32(cert)
			} else if dist, ok := add["distance"].(float64); ok {
				score = float32(1.0 / (1.0 + dist))
			}
		}

		preview := text
		const maxPreview = 220
		rs := []rune(preview)
		if len(rs) > maxPreview {
			preview = string(rs[:maxPreview])
		}

		out = append(out, models.Source{
			ContentPreview: preview,
			Metadata: models.Metadata{
				Source:     source,
				ChunkIndex: chunkIdx,
				Score:      score,
			},
		})
	}

	return out, nil
}

// BatchCreateObjects upserts objects with caller-supplied vectors (vectorizer must be "none").
func (c *Client) BatchCreateObjects(ctx context.Context, objects []*wmodels.Object) ([]wmodels.ObjectsGetResponse, error) {
	if len(objects) == 0 {
		return nil, nil
	}
	return c.wv.Batch().ObjectsBatcher().WithObjects(objects...).Do(ctx)
}
