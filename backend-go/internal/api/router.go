package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/models"
	"github.com/LongTran112/RAG-LLMOps/backend-go/internal/rag"
)

var inflight = promauto.NewGaugeVec(prometheus.GaugeOpts{
	Name: "rag_inflight_requests",
	Help: "Requests currently executing the RAG pipeline.",
}, []string{"endpoint"})

type API struct {
	pipeline *rag.Pipeline
}

func track(endpoint string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			inflight.WithLabelValues(endpoint).Inc()
			defer inflight.WithLabelValues(endpoint).Dec()
			next.ServeHTTP(w, r)
		})
	}
}

func normalizeQuery(req *models.QueryRequest) error {
	req.Query = strings.TrimSpace(req.Query)
	if len(req.Query) < 3 {
		return fmt.Errorf("query must be at least 3 characters")
	}
	if len(req.Query) > 4000 {
		return fmt.Errorf("query exceeds maximum length")
	}
	mode := strings.ToLower(strings.TrimSpace(req.AnswerMode))
	if mode == "" {
		req.AnswerMode = "fast"
		return nil
	}
	if mode != "fast" && mode != "complex" {
		return fmt.Errorf("answer_mode must be fast or complex")
	}
	req.AnswerMode = mode
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func NewRouter(p *rag.Pipeline) http.Handler {
	api := &API{pipeline: p}
	r := chi.NewRouter()
	r.Use(middleware.Recoverer)

	r.Use(cors.Handler(cors.Options{
		AllowedOrigins: []string{
			"http://localhost:3000",
			"http://127.0.0.1:3000",
			"http://localhost:8501",
			"http://127.0.0.1:8501",
		},
		AllowedMethods:   []string{"GET", "POST", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type"},
		AllowCredentials: true,
		MaxAge:           300,
	}))

	r.Get("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	r.Handle("/metrics", promhttp.Handler())

	r.With(track("/query")).Post("/query", api.HandleQuery)
	r.With(track("/retrieve")).Post("/retrieve", api.HandleRetrieve)
	r.With(track("/query/stream")).Post("/query/stream", api.HandleQueryStream)

	return r
}

func (a *API) HandleQuery(w http.ResponseWriter, r *http.Request) {
	var req models.QueryRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"detail": "invalid JSON body"})
		return
	}
	if err := normalizeQuery(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"detail": err.Error()})
		return
	}

	resp, err := a.pipeline.Query(r.Context(), req)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"detail": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (a *API) HandleRetrieve(w http.ResponseWriter, r *http.Request) {
	var req models.QueryRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"detail": "invalid JSON body"})
		return
	}
	if err := normalizeQuery(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"detail": err.Error()})
		return
	}

	resp, err := a.pipeline.RetrieveOnly(r.Context(), req)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"detail": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (a *API) HandleQueryStream(w http.ResponseWriter, r *http.Request) {
	var req models.QueryRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	if err := normalizeQuery(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	onEvent := func(eventType, payload string) error {
		_, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", eventType, payload)
		flusher.Flush()
		return err
	}

	if err := a.pipeline.StreamQuery(r.Context(), req, onEvent); err != nil {
		b, _ := json.Marshal(map[string]string{"error": err.Error()})
		_, _ = fmt.Fprintf(w, "event: error\ndata: %s\n\n", string(b))
		flusher.Flush()
		return
	}

	_, _ = fmt.Fprintf(w, "event: done\ndata: {}\n\n")
	flusher.Flush()
}
