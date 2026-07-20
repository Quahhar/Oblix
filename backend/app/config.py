from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import model_validator
from typing import Optional

DEFAULT_SECRET_KEY = "change-me-in-production-use-openssl-rand-hex-32"


class Settings(BaseSettings):
    # extra="ignore": the .env is shared with docker-compose, which owns keys
    # (POSTGRES_*, DOMAIN, ...) that are not app settings — don't choke on them.
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # Application
    APP_NAME: str = "Oblix Notes API"
    ENVIRONMENT: str = "development"  # "development" | "production"
    DEBUG: bool = True
    SECRET_KEY: str = DEFAULT_SECRET_KEY
    API_V1_PREFIX: str = "/api"

    @property
    def is_production(self) -> bool:
        return self.ENVIRONMENT.lower() == "production"

    # Database
    DATABASE_URL: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/oblix"

    # JWT
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    ALGORITHM: str = "HS256"
    # Grace window for refresh-token rotation: if a just-rotated token is
    # replayed within this many seconds AND its successor is still unused, treat
    # it as a benign client retry (a lost rotation response) and re-hand the
    # successor tokens, instead of assuming theft and logging the user out of
    # every device. Real reuse (stale replay, or a successor already rotated on)
    # still revokes the whole family.
    REFRESH_REUSE_GRACE_SECONDS: int = 60

    # Google OAuth
    GOOGLE_CLIENT_ID: Optional[str] = None
    GOOGLE_CLIENT_SECRET: Optional[str] = None

    # File Storage
    UPLOAD_DIR: str = "uploads"
    MAX_UPLOAD_SIZE_MB: int = 50

    # CORS
    CORS_ORIGINS: list[str] = ["*"]

    # Auth rate limiting (in-process sliding window; see app/utils/rate_limit.py).
    # Disable for load tests / multi-worker deployments where it can't be fair.
    RATE_LIMIT_ENABLED: bool = True

    # AI features (app/services/ai_service.py). Disabled unless the key is set.
    ANTHROPIC_API_KEY: Optional[str] = None
    AI_MODEL: str = "claude-sonnet-5"
    # Messages-API-compatible endpoint; override to route through a proxy.
    AI_BASE_URL: str = "https://api.anthropic.com"
    AI_TIMEOUT_SECONDS: float = 60.0
    # Hard cap on note characters sent per request (cost control).
    AI_MAX_INPUT_CHARS: int = 150_000
    # Per-user AI calls per hour (in-process sliding window, like auth limits).
    AI_RATE_LIMIT_PER_HOUR: int = 30

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
