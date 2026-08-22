from datetime import UTC, datetime
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models import YandexToken

YANDEX_API_BASE = "https://api.music.yandex.net"
MAX_TOKEN_FAILURES = 5


class MusicUpstreamError(Exception):
    """Raised when the upstream music service cannot serve a request."""


class RegionBlockedError(MusicUpstreamError):
    """The upstream refused on geography grounds (HTTP 451 and friends).

    Worth its own type because the fix is completely different from a normal
    failure: it needs a Russian-facing egress, not a retry.
    """


async def pick_token(session: AsyncSession) -> YandexToken:
    """Take the healthiest active token.

    Least-recently-used ordering spreads load across the pool, so no single
    account looks like it is serving an entire app.
    """
    token = await session.scalar(
        select(YandexToken)
        .where(YandexToken.is_active.is_(True), YandexToken.disabled_at.is_(None))
        .order_by(YandexToken.failure_count.asc(), YandexToken.last_used_at.asc().nullsfirst())
        .limit(1)
    )
    if token is None:
        raise MusicUpstreamError("Нет доступных ключей для загрузки музыки")
    return token


async def note_success(session: AsyncSession, token: YandexToken) -> None:
    token.last_used_at = datetime.now(UTC)
    token.failure_count = 0
    token.last_error = None


async def note_failure(session: AsyncSession, token: YandexToken, error: str) -> None:
    token.failure_count += 1
    token.last_error = error[:500]
    token.last_used_at = datetime.now(UTC)
    if token.failure_count >= MAX_TOKEN_FAILURES:
        # Park it rather than keep hammering a credential that is clearly
        # broken; an admin can re-enable it after fixing the cause.
        token.disabled_at = datetime.now(UTC)
        token.is_active = False


async def request(
    session: AsyncSession,
    method: str,
    path: str,
    *,
    params: dict[str, Any] | None = None,
    json: dict[str, Any] | None = None,
) -> Any:
    """Call the upstream music API on behalf of the app.

    Only used when `music_proxy_enabled` is on. While it is off the client
    talks to the source directly and this never runs — which is the current
    setup, because the server's egress IP is not in a region the upstream
    serves.
    """
    if not settings.music_proxy_enabled:
        raise MusicUpstreamError("Проксирование музыки отключено в конфигурации")

    token = await pick_token(session)
    base = settings.music_proxy_upstream or YANDEX_API_BASE

    try:
        async with httpx.AsyncClient(timeout=20, base_url=base) as client:
            response = await client.request(
                method,
                path,
                params=params,
                json=json,
                headers={
                    "Authorization": f"OAuth {token.token}",
                    "Accept-Language": "ru",
                },
            )
    except httpx.HTTPError as exc:
        await note_failure(session, token, str(exc))
        raise MusicUpstreamError("Источник музыки недоступен") from exc

    if response.status_code == 451:
        await note_failure(session, token, "HTTP 451 region blocked")
        raise RegionBlockedError(
            "Источник музыки недоступен из региона сервера"
        )

    if response.status_code in (401, 403):
        await note_failure(session, token, f"HTTP {response.status_code}")
        raise MusicUpstreamError("Ключ доступа отклонён источником")

    if response.status_code >= 400:
        await note_failure(session, token, f"HTTP {response.status_code}")
        raise MusicUpstreamError("Источник музыки вернул ошибку")

    await note_success(session, token)
    payload = response.json()
    return payload.get("result", payload)


async def seed_tokens_from_settings(session: AsyncSession) -> int:
    """Copy tokens supplied via environment into the pool on first boot."""
    if not settings.yandex_tokens:
        return 0

    existing = set(
        (await session.scalars(select(YandexToken.token))).all()
    )
    added = 0
    for index, raw in enumerate(settings.yandex_tokens):
        if raw in existing:
            continue
        session.add(YandexToken(label=f"env-{index + 1}", token=raw))
        added += 1
    return added
