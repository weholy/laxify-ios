from dataclasses import dataclass

import logging

import httpx
from cachetools import TTLCache
from jose import jwt as jose_jwt
from jose.exceptions import JWTError

from app.core.config import settings

logger = logging.getLogger("laxify.google")

GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = {"accounts.google.com", "https://accounts.google.com"}

# Google rotates signing keys slowly; caching avoids fetching them on
# every single sign-in while still picking up rotations within the hour.
_jwks_cache: TTLCache = TTLCache(maxsize=1, ttl=3600)


@dataclass(slots=True)
class GoogleIdentity:
    sub: str
    email: str
    name: str
    picture: str | None
    email_verified: bool


class GoogleAuthError(Exception):
    pass


async def _get_jwks() -> dict:
    if "jwks" in _jwks_cache:
        return _jwks_cache["jwks"]

    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.get(GOOGLE_CERTS_URL)
        response.raise_for_status()
        jwks = response.json()

    _jwks_cache["jwks"] = jwks
    return jwks


async def verify_id_token(id_token: str) -> GoogleIdentity:
    """Verify a Google ID token against Google's public keys.

    The signature check is what makes this trustworthy: without it, anyone
    could post a hand-written JSON body and claim to be any account.
    """
    if not settings.google_client_ids:
        raise GoogleAuthError("Не настроен Google client ID")

    jwks = await _get_jwks()

    try:
        unverified_header = jose_jwt.get_unverified_header(id_token)
    except JWTError as exc:
        logger.warning("Google token header unreadable: %s (len=%d)", exc, len(id_token))
        raise GoogleAuthError("Некорректный токен Google") from exc

    key = next((k for k in jwks.get("keys", []) if k.get("kid") == unverified_header.get("kid")), None)
    if key is None:
        # Key id unknown — most likely a rotation we haven't picked up yet.
        _jwks_cache.clear()
        jwks = await _get_jwks()
        key = next(
            (k for k in jwks.get("keys", []) if k.get("kid") == unverified_header.get("kid")), None
        )
    if key is None:
        logger.warning(
            "Google signing key not found for kid=%r; available=%r",
            unverified_header.get("kid"),
            [k.get("kid") for k in jwks.get("keys", [])],
        )
        raise GoogleAuthError("Не найден ключ подписи Google")

    # Read the unverified audience purely for diagnostics: a mismatch here is
    # the usual cause, and without logging it the failure is a silent 401.
    try:
        unverified_claims = jose_jwt.get_unverified_claims(id_token)
        token_audience = unverified_claims.get("aud")
        token_issuer = unverified_claims.get("iss")
    except JWTError:
        token_audience = None
        token_issuer = None

    last_error: Exception | None = None
    for audience in settings.google_client_ids:
        try:
            claims = jose_jwt.decode(
                id_token,
                key,
                algorithms=["RS256"],
                audience=audience,
                options={"verify_at_hash": False},
            )
            break
        except JWTError as exc:
            last_error = exc
    else:
        logger.warning(
            "Google token rejected: token aud=%r iss=%r, configured=%r, error=%s",
            token_audience,
            token_issuer,
            settings.google_client_ids,
            last_error,
        )
        if token_audience and token_audience not in settings.google_client_ids:
            raise GoogleAuthError(
                "Приложение не совпадает с настройками входа на сервере"
            ) from last_error
        raise GoogleAuthError("Токен Google не прошёл проверку") from last_error

    if claims.get("iss") not in GOOGLE_ISSUERS:
        logger.warning("Google token issuer rejected: %r", claims.get("iss"))
        raise GoogleAuthError("Неверный издатель токена")

    sub = claims.get("sub")
    if not sub:
        logger.warning("Google token has no subject; claims=%r", sorted(claims))
        raise GoogleAuthError("В токене нет идентификатора пользователя")

    logger.info("Google sign-in verified for %s", claims.get("email", "<no email>"))

    return GoogleIdentity(
        sub=sub,
        email=claims.get("email", ""),
        name=claims.get("name") or claims.get("given_name") or "",
        picture=claims.get("picture"),
        email_verified=bool(claims.get("email_verified", False)),
    )
