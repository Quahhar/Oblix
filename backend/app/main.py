from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, status
from fastapi.responses import ORJSONResponse
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.config import settings
from app.database import Base, engine
from app.routers import (
    ai,
    auth,
    collaboration,
    files,
    notebooks,
    notes,
    shares,
    sync,
    tags,
    tasks,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Dev convenience only: auto-create tables. In production the schema is
    # owned by Alembic migrations (`alembic upgrade head`), never create_all.
    if not settings.is_production:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
    await collaboration.start_collaboration_maintenance()
    try:
        yield
    finally:
        await collaboration.stop_collaboration_maintenance()
        await engine.dispose()


app = FastAPI(
    title=settings.APP_NAME,
    version="1.0.0",
    lifespan=lifespan,
    root_path=settings.ROOT_PATH,
    # Response models are already converted to JSON-compatible values by
    # FastAPI; encode the final payload with orjson to reduce CPU time for
    # large note lists and first-sync responses.
    default_response_class=ORJSONResponse,
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Routers
app.include_router(auth.router, prefix=settings.API_V1_PREFIX)
app.include_router(notes.router, prefix=settings.API_V1_PREFIX)
app.include_router(notebooks.router, prefix=settings.API_V1_PREFIX)
app.include_router(tags.router, prefix=settings.API_V1_PREFIX)
app.include_router(files.router, prefix=settings.API_V1_PREFIX)
app.include_router(sync.router, prefix=settings.API_V1_PREFIX)
app.include_router(shares.router, prefix=settings.API_V1_PREFIX)
app.include_router(tasks.router, prefix=settings.API_V1_PREFIX)
app.include_router(ai.router, prefix=settings.API_V1_PREFIX)
app.include_router(collaboration.router, prefix=settings.API_V1_PREFIX)


@app.get("/")
async def root():
    return {"app": settings.APP_NAME, "status": "running"}


@app.get("/health")
async def health():
    try:
        async with engine.connect() as connection:
            await connection.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Database unavailable",
        ) from exc
    return {"status": "healthy", "database": "connected"}
