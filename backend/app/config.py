from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import model_validator
from typing import Optional

DEFAULT_SECRET_KEY = "change-me-in-production-use-openssl-rand-hex-32"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # Application
    APP_NAME: str = "Cyclux Notes API"
    ENVIRONMENT: str = "development"  # "development" | "production"
    DEBUG: bool = True
    SECRET_KEY: str = DEFAULT_SECRET_KEY
    API_V1_PREFIX: str = "/api"

    @property
    def is_production(self) -> bool:
        return self.ENVIRONMENT.lower() == "production"

    # Database
    DATABASE_URL: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/cyclux"

    # JWT
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    ALGORITHM: str = "HS256"

    # Google OAuth
    GOOGLE_CLIENT_ID: Optional[str] = None
    GOOGLE_CLIENT_SECRET: Optional[str] = None

    # File Storage
    UPLOAD_DIR: str = "uploads"
    MAX_UPLOAD_SIZE_MB: int = 50

    # CORS
    CORS_ORIGINS: list[str] = ["*"]

    @model_validator(mode="after")
    def _enforce_production_safety(self) -> "Settings":
        """Refuse to run in production with insecure defaults.

        Fails loudly at import/startup rather than silently shipping a guessable
        signing key or a wildcard CORS policy that leaks credentials. Local dev
        (ENVIRONMENT=development) is unaffected and works with defaults.
        """
        if not self.is_production:
            return self

        problems: list[str] = []
        if self.SECRET_KEY == DEFAULT_SECRET_KEY or len(self.SECRET_KEY) < 32:
            problems.append(
                "SECRET_KEY must be set to a strong, non-default value "
                "(e.g. `openssl rand -hex 32`)."
            )
        if "*" in self.CORS_ORIGINS:
            problems.append(
                "CORS_ORIGINS must list explicit origins in production; "
                "'*' is invalid together with credentialed requests."
            )
        if problems:
            raise ValueError(
                "Insecure configuration for a non-DEBUG deployment:\n  - "
                + "\n  - ".join(problems)
                + "\nSet DEBUG=true for local development, or provide these via environment/.env."
            )
        return self


settings = Settings()
