from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import ACCESS_TOKEN_TYPE, TokenError, decode_token
from app.db.session import get_session
from app.models import User

bearer_scheme = HTTPBearer(auto_error=False)

SessionDep = Annotated[AsyncSession, Depends(get_session)]


async def get_current_user(
    session: SessionDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> User:
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Требуется авторизация",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        claims = decode_token(credentials.credentials, ACCESS_TOKEN_TYPE)
    except TokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    user = await session.get(User, UUID(claims["sub"]))
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Пользователь не найден")
    if user.is_banned:
        raise banned_error(user)

    return user


# Read by the app. A 403 alone cannot tell "this account is blocked" from
# "this account may not open the admin panel", and only the first should put
# the listener in front of a sign-in screen with an explanation.
ACCOUNT_STATUS_HEADER = "X-Account-Status"


def banned_error(user: User) -> HTTPException:
    """The one answer every door gives a blocked account.

    Sign-in, session refresh and every authenticated request used to refuse
    a banned account each in its own words — one said "account unavailable",
    another the reason, another nothing an app could recognise. The app could
    not tell a ban from any other failure and simply dropped the person at the
    sign-in screen with no idea why.
    """
    return HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail=user.ban_reason or "Аккаунт заблокирован",
        headers={ACCOUNT_STATUS_HEADER: "banned"},
    )


async def get_optional_user(
    session: SessionDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> User | None:
    """For endpoints that reveal more to a signed-in viewer but still work
    anonymously — public profiles and shared playlists."""
    if credentials is None:
        return None
    try:
        return await get_current_user(session, credentials)
    except HTTPException:
        return None


async def get_current_device_id(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> UUID | None:
    if credentials is None:
        return None
    try:
        claims = decode_token(credentials.credentials, ACCESS_TOKEN_TYPE)
    except TokenError:
        return None
    raw = claims.get("did")
    return UUID(raw) if raw else None


async def require_admin(user: Annotated[User, Depends(get_current_user)]) -> User:
    if not user.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Недостаточно прав")
    return user


def client_ip(request: Request, x_forwarded_for: Annotated[str | None, Header()] = None) -> str:
    if x_forwarded_for:
        return x_forwarded_for.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


CurrentUser = Annotated[User, Depends(get_current_user)]
OptionalUser = Annotated[User | None, Depends(get_optional_user)]
AdminUser = Annotated[User, Depends(require_admin)]
CurrentDeviceId = Annotated[UUID | None, Depends(get_current_device_id)]
ClientIP = Annotated[str, Depends(client_ip)]
