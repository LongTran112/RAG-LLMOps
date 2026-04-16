from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "rag-k8s-thesis-backend"
    environment: str = "dev"
    log_level: str = "INFO"

    qdrant_host: str = "qdrant"
    qdrant_port: int = 6333
    qdrant_collection: str = "thesis_docs"
    # Used when product_latency_mode is false (e.g. thesis benchmarks).
    qdrant_top_k: int = 4
    # Narrower retrieval for interactive / product-style latency.
    qdrant_top_k_product: int = 3

    embedding_model_name: str = "sentence-transformers/all-MiniLM-L6-v2"

    # Inference provider: "ollama" (default) or "vllm" (OpenAI-compatible endpoint).
    llm_provider: str = "ollama"
    llm_base_url: str = "http://ollama:11434"
    llm_model: str = "qwen2.5:3b"

    # Large local models (especially on CPU) can take many minutes for a first response.
    request_timeout_seconds: int = 1800

    # When true: smaller retrieval budget + capped decoder output (unless max tokens is 0).
    product_latency_mode: bool = True
    # Max new tokens from LLM provider; set 0 to disable the cap (benchmark / quality runs).
    ollama_max_output_tokens: int = 256
    ollama_temperature: float = 0.1

    # Loads the configured model once at startup to reduce first-user cold latency.
    warmup_llm_on_startup: bool = True

    model_config = SettingsConfigDict(env_file=".env", env_prefix="", case_sensitive=False)


settings = Settings()
