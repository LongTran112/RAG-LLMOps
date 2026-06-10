package config

import (
	"os"
	"strconv"
	"strings"
)

type Config struct {
	WeaviateHost   string
	WeaviateScheme string
	OllamaBaseURL  string
	EmbeddingModel string
	PrimaryModel   string
	ReasoningModel string
	DataDir        string
	HTTPListenAddr string
	RetrieveTopK   int
}

func Load() *Config {
	return &Config{
		WeaviateHost:   normalizeWeaviateHost(getEnv("WEAVIATE_HOST", "localhost:8080")),
		WeaviateScheme: strings.ToLower(strings.TrimSpace(getEnv("WEAVIATE_SCHEME", "http"))),
		OllamaBaseURL:  getEnv("OLLAMA_BASE_URL", "http://localhost:11434"),
		EmbeddingModel: getEnv("EMBEDDING_MODEL", "all-minilm"),
		PrimaryModel:   getEnv("PRIMARY_MODEL", "llama3"),
		ReasoningModel: getEnv("REASONING_MODEL", "deepseek-r1"),
		DataDir:        getEnv("DATA_DIR", "../data"),
		HTTPListenAddr: getEnv("HTTP_LISTEN_ADDR", ":8000"),
		RetrieveTopK:   getEnvInt("RETRIEVE_TOP_K", 4),
	}
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if value, exists := os.LookupEnv(key); exists {
		n, err := strconv.Atoi(value)
		if err == nil && n > 0 {
			return n
		}
	}
	return fallback
}

// normalizeWeaviateHost strips accidental URL prefixes so the Go client's Host is hostname:port only.
func normalizeWeaviateHost(raw string) string {
	h := strings.TrimSpace(strings.TrimSuffix(raw, "/"))
	h = strings.TrimPrefix(h, "http://")
	h = strings.TrimPrefix(h, "https://")
	if i := strings.Index(h, "/"); i >= 0 {
		h = h[:i]
	}
	return h
}
