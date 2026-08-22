import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import text

from app.api.v1.router import api_router
from app.core.config import settings
from app.db.session import SessionLocal, engine
from app.services.yandex import seed_tokens_from_settings

logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("laxify")


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with SessionLocal() as session:
        added = await seed_tokens_from_settings(session)
        if added:
            await session.commit()
            logger.info("Добавлено ключей из окружения: %s", added)

    yield

    await engine.dispose()


app = FastAPI(
    title=settings.project_name,
    version="1.0.0",
    docs_url=None if settings.is_prod else "/docs",
    redoc_url=None,
    openapi_url=None if settings.is_prod else "/openapi.json",
    lifespan=lifespan,
)

if settings.cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    # Log the detail, return a neutral message: stack traces and driver errors
    # must never reach a client.
    logger.exception("Необработанная ошибка на %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"detail": "Внутренняя ошибка сервера"},
    )


@app.get("/health", tags=["system"])
async def health() -> dict[str, str]:
    async with SessionLocal() as session:
        await session.execute(text("SELECT 1"))
    return {"status": "ok"}


app.include_router(api_router, prefix=settings.api_prefix)
