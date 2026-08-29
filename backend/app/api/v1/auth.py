from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from app.api.deps import ClientIP, CurrentUser, SessionDep
from app.core.config import settings
from app.core.security import (
    REFRESH_TOKEN_TYPE,
    TokenError,
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_refresh_token,
)
from app.models import AuditLog, Device, User
from app.schemas.auth import (
    GoogleSignInRequest,
    RefreshRequest,
    SessionOut,
    TelegramSignInRequest,
    TokenPair,
)
from app.schemas.common import MessageOut
from app.services.google_auth import GoogleAuthError, verify_id_token
from app.services.telegram_auth import TelegramAuthError, verify_login
from app.services.users import generate_unique_username

router = APIRouter(prefix="/auth", tags=["auth"])


def _issue_tokens(user: User, device: Device) -> TokenPair:
    return TokenPair(
        access_token=create_access_token(user.id, device.id),
        refresh_token=create_refresh_token(user.id, device.id),
        expires_in=settings.access_token_ttl_minutes * 60,
    )


@router.post("/google", response_model=SessionOut)
async def sign_in_with_google(
    payload: GoogleSignInRequest, session: SessionDep, ip: ClientIP
) -> SessionOut:
    try:
        identity = await verify_id_token(payload.id_token)
    except GoogleAuthError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    user = await session.scalar(select(User).where(User.google_sub == identity.sub))
    is_new_user = user is None

    if user is None:
        username = await generate_unique_username(
            session, identity.name or identity.email.split("@")[0]
        )
        user = User(
            google_sub=identity.sub,
            email=identity.email,
            display_name=identity.name or username,
            username=username,
            google_avatar_url=identity.picture,
            is_admin=identity.sub in settings.admin_google_subs,
            primary_auth_method="google",
        )
        session.add(user)
        await session.flush()
    else:
        user.email = identity.email or user.email
        if identity.picture:
            user.google_avatar_url = identity.picture

    user.last_seen_at = datetime.now(UTC)

    device = Device(
        user_id=user.id,
        name=payload.device.name,
        model=payload.device.model,
        app_version=payload.device.app_version,
        refresh_token_hash="",
        last_used_at=datetime.now(UTC),
    )
    session.add(device)
    await session.flush()

    tokens = _issue_tokens(user, device)
    device.refresh_token_hash = hash_refresh_token(tokens.refresh_token)

    session.add(
        AuditLog(
            actor_id=user.id,
            action="auth.sign_in" if not is_new_user else "auth.sign_up",
            target_type="user",
            target_id=str(user.id),
            ip=ip,
            payload={"device": payload.device.model_dump()},
        )
    )

    return SessionOut(
        tokens=tokens,
        is_new_user=is_new_user,
        needs_onboarding=not user.has_completed_onboarding,
        needs_local_migration=not user.has_migrated_local_data,
    )


@router.post("/telegram", response_model=SessionOut)
async def sign_in_with_telegram(
    payload: TelegramSignInRequest, session: SessionDep, ip: ClientIP
) -> SessionOut:
    try:
        identity = verify_login(payload.payload)
    except TelegramAuthError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    user = await session.scalar(select(User).where(User.telegram_id == identity.id))
    is_new_user = user is None

    if user is None:
        source = identity.username or identity.full_name or f"tg{identity.id}"
        username = await generate_unique_username(session, source)
        user = User(
            email="",  # Telegram hands back no address.
            display_name=identity.full_name or identity.username or username,
            username=username,
            telegram_id=identity.id,
            telegram_username=identity.username,
            telegram_photo_url=identity.photo_url,
            avatar_url=identity.photo_url,
            primary_auth_method="telegram",
        )
        session.add(user)
        await session.flush()
    else:
        if identity.username:
            user.telegram_username = identity.username
        if identity.photo_url:
            user.telegram_photo_url = identity.photo_url

    user.last_seen_at = datetime.now(UTC)

    device = Device(
        user_id=user.id,
        name=payload.device.name,
        model=payload.device.model,
        app_version=payload.device.app_version,
        refresh_token_hash="",
        last_used_at=datetime.now(UTC),
    )
    session.add(device)
    await session.flush()

    tokens = _issue_tokens(user, device)
    device.refresh_token_hash = hash_refresh_token(tokens.refresh_token)

    session.add(
        AuditLog(
            actor_id=user.id,
            action="auth.sign_up" if is_new_user else "auth.sign_in",
            target_type="user",
            target_id=str(user.id),
            ip=ip,
            payload={"method": "telegram", "device": payload.device.model_dump()},
        )
    )

    return SessionOut(
        tokens=tokens,
        is_new_user=is_new_user,
        needs_onboarding=not user.has_completed_onboarding,
        needs_local_migration=not user.has_migrated_local_data,
    )


@router.post("/refresh", response_model=TokenPair)
async def refresh_session(payload: RefreshRequest, session: SessionDep) -> TokenPair:
    try:
        claims = decode_token(payload.refresh_token, REFRESH_TOKEN_TYPE)
    except TokenError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    device = await session.get(Device, claims["did"])
    if device is None or device.revoked_at is not None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Сессия завершена")

    # Rotation: a refresh token is single-use, so a stolen one stops working
    # as soon as the real device refreshes again.
    if device.refresh_token_hash != hash_refresh_token(payload.refresh_token):
        device.revoked_at = datetime.now(UTC)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Токен уже использован, войдите заново",
        )

    user = await session.get(User, device.user_id)
    if user is None or user.is_banned:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Аккаунт недоступен")

    tokens = _issue_tokens(user, device)
    device.refresh_token_hash = hash_refresh_token(tokens.refresh_token)
    device.last_used_at = datetime.now(UTC)
    user.last_seen_at = datetime.now(UTC)
    return tokens


@router.post("/logout", response_model=MessageOut)
async def logout(payload: RefreshRequest, session: SessionDep) -> MessageOut:
    try:
        claims = decode_token(payload.refresh_token, REFRESH_TOKEN_TYPE)
    except TokenError:
        return MessageOut(detail="Сессия уже завершена")

    device = await session.get(Device, claims["did"])
    if device is not None:
        device.revoked_at = datetime.now(UTC)
    return MessageOut(detail="Вы вышли из аккаунта")


@router.post("/logout-all", response_model=MessageOut)
async def logout_everywhere(user: CurrentUser, session: SessionDep) -> MessageOut:
    devices = (await session.scalars(select(Device).where(Device.user_id == user.id))).all()
    now = datetime.now(UTC)
    for device in devices:
        device.revoked_at = now
    return MessageOut(detail="Вы вышли на всех устройствах")


# --- Linking a second way in to one account -------------------------------
#
# You sign in one way, then attach the other from settings, so both open the
# same account. The method you first joined with (`primary_auth_method`)
# can't be unlinked — that would be a way to lock yourself out.


class LinkedMethodsOut(MessageOut):
    detail: str = "ok"
    primary: str
    google_linked: bool
    telegram_linked: bool
    email_linked: bool


def _methods(user: User) -> LinkedMethodsOut:
    return LinkedMethodsOut(
        primary=user.primary_auth_method,
        google_linked=user.google_sub is not None,
        telegram_linked=user.telegram_id is not None,
        email_linked=user.password_hash is not None,
    )


@router.get("/linked", response_model=LinkedMethodsOut)
async def linked_methods(user: CurrentUser) -> LinkedMethodsOut:
    return _methods(user)


@router.post("/link/google", response_model=LinkedMethodsOut)
async def link_google(
    payload: GoogleSignInRequest, user: CurrentUser, session: SessionDep, ip: ClientIP
) -> LinkedMethodsOut:
    try:
        identity = await verify_id_token(payload.id_token)
    except GoogleAuthError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    taken = await session.scalar(select(User).where(User.google_sub == identity.sub))
    if taken is not None and taken.id != user.id:
        raise HTTPException(status_code=409, detail="Этот Google уже привязан к другому аккаунту")

    user.google_sub = identity.sub
    if identity.picture and not user.google_avatar_url:
        user.google_avatar_url = identity.picture
    if not user.email:
        user.email = identity.email
    session.add(AuditLog(actor_id=user.id, action="auth.link.google", ip=ip))
    await session.commit()
    return _methods(user)


@router.post("/link/telegram", response_model=LinkedMethodsOut)
async def link_telegram(
    payload: TelegramSignInRequest, user: CurrentUser, session: SessionDep, ip: ClientIP
) -> LinkedMethodsOut:
    try:
        identity = verify_login(payload.payload)
    except TelegramAuthError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc

    taken = await session.scalar(select(User).where(User.telegram_id == identity.id))
    if taken is not None and taken.id != user.id:
        raise HTTPException(status_code=409, detail="Этот Telegram уже привязан к другому аккаунту")

    user.telegram_id = identity.id
    user.telegram_username = identity.username
    if identity.photo_url:
        user.telegram_photo_url = identity.photo_url
    session.add(AuditLog(actor_id=user.id, action="auth.link.telegram", ip=ip))
    await session.commit()
    return _methods(user)


@router.post("/unlink/{provider}", response_model=LinkedMethodsOut)
async def unlink(
    provider: str, user: CurrentUser, session: SessionDep, ip: ClientIP
) -> LinkedMethodsOut:
    if provider not in ("google", "telegram"):
        raise HTTPException(status_code=404, detail="Неизвестный способ входа")
    if provider == user.primary_auth_method:
        raise HTTPException(
            status_code=400,
            detail="Нельзя отвязать способ, которым вы вошли в аккаунт",
        )

    if provider == "google":
        user.google_sub = None
    else:
        user.telegram_id = None
        user.telegram_username = None
        user.telegram_photo_url = None

    session.add(AuditLog(actor_id=user.id, action=f"auth.unlink.{provider}", ip=ip))
    await session.commit()
    return _methods(user)
