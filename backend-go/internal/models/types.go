package models

type QueryRequest struct {
	Query       string `json:"query"`
	AnswerMode  string `json:"answer_mode"` // "fast" | "complex"
}

type Metadata struct {
	Source     string   `json:"source"`
	ChunkIndex int      `json:"chunk_index"`
	Page       *float64 `json:"page,omitempty"`
	Score      float32  `json:"score"`
}

type Source struct {
	ContentPreview string   `json:"content_preview"`
	Metadata       Metadata `json:"metadata"`
}

type LLMStats struct {
	ModelUsed string `json:"model_used"`
	Attempts  int    `json:"attempts"`
	Fallback  bool   `json:"fallback"`
}

type Timing struct {
	Embedding       int64 `json:"embedding"`
	WeaviateSearch  int64 `json:"weaviate_search"`
	RetrievalTotal  int64 `json:"retrieval_total"`
	Generation      int64 `json:"generation,omitempty"`
}

type QueryResponse struct {
	Answer   string   `json:"answer"`
	Sources  []Source `json:"sources"`
	LLM      LLMStats `json:"llm"`
	TimingMS Timing   `json:"timing_ms"`
}
