from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "rag-k8s-thesis-backend"
    environment: str = "dev"
    log_level: str = "INFO"

    qdrant_host: str = "qdrant"
    qdrant_port: int = 6333
    qdrant_collection: str = "thesis_docs"
    qdrant_top_k: int = 4

    embedding_model_name: str = "sentence-transformers/all-MiniLM-L6-v2"

    ollama_base_url: str = "http://ollama:11434"
    ollama_model: str = "mistral:7b-instruct"

    request_timeout_seconds: int = 60

    model_config = SettingsConfigDict(env_file=".env", env_prefix="", case_sensitive=False)


settings = Settings()
