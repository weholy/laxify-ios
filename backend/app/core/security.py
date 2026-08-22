import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

import jwt
from jwt.exceptions import InvalidTokenError

from app.core.config import settings

ACCESS_TOKEN_TYPE = "access"
REFRESH_TOKEN_TYPE = "refresh"


class TokenError(Exception):
    pass


def _encode(payload: dict[str, Any], expires_delta: timedelta, token_type: str) -> str:
    now = datetime.now(UTC)
    claims = {
        **payload,
        "iat": now,
        "exp": now + expires_delta,
        "typ": token_type,
        # A random id per token lets a single leaked token be revoked without
        # invalidating every session the user has.
        "jti": secrets.token_urlsafe(16),
    }
    return jwt.encode(claims, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def create_access_token(user_id: UUID, device_id: UUID | None = None) -> str:
    payload: dict[str, Any] = {"sub": str(user_id)}
    if device_id:
        payload["did"] = str(device_id)
    return _encode(payload, timedelta(minutes=settings.access_token_ttl_minutes), ACCESS_TOKEN_TYPE)


def create_refresh_token(user_id: UUID, device_id: UUID) -> str:
    return _encode(
        {"sub": str(user_id), "did": str(device_id)},
        timedelta(days=settings.refresh_token_ttl_days),
        REFRESH_TOKEN_TYPE,
    )


def decode_token(token: str, expected_type: str) -> dict[str, Any]:
    try:
        claims = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except InvalidTokenError as exc:
        raise TokenError("Недействительный токен") from exc

    if claims.get("typ") != expected_type:
        raise TokenError("Неверный тип токена")
    return claims


def hash_refresh_token(token: str) -> str:
    """Refresh tokens are stored hashed; the raw value only lives on device."""
    return hashlib.sha256(token.encode()).hexdigest()


def generate_share_slug(length: int = 12) -> str:
    return secrets.token_urlsafe(length)[:length]
