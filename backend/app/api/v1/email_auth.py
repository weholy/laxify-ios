"""Email as a way in, and as a way to secure a Google account.

Two flows share the same code machinery:

  * binding — a signed-in account attaches an address and sets a password;
  * signing in — an address that already has a password gets a session.

A four-digit code is short enough to retype but too short to be safe on its
own, so every code is single-use, expires in ten minutes, allows five wrong
guesses, and cannot be requested again for a minute.
"""

import re
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import desc, func, select

from app.api.deps import ClientIP, CurrentUser, SessionDep
from app.core.config import settings
from app.core.security import (
    create_access_token,
    create_refresh_token,
    generate_email_code,
    hash_email_code,
    hash_password,
    hash_refresh_token,
    verify_password,
)
from app.models import AuditLog, Device, EmailVerification, User
from app.schemas.auth import SessionOut, TokenPair
from app.schemas.common import MessageOut
from app.services import mailer
from app.services.users import generate_unique_username

router = APIRouter(prefix="/auth/email", tags=["auth"])

CODE_TTL = timedelta(minutes=10)
RESEND_INTERVAL = timedelta(seconds=60)
MAX_ATTEMPTS = 5
PASSWORD_MIN = 8

PURPOSE_PATTERN = "^(bind|change|login|reset)$"


class RequestCodeIn(BaseModel):
    email: EmailStr
    purpose: str = Field("bind", pattern=PURPOSE_PATTERN)


class VerifyCodeIn(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=4, pattern=r"^\d{4}$")
    purpose: str = Field("bind", pattern=PURPOSE_PATTERN)


class SetPasswordIn(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=4, pattern=r"^\d{4}$")
    password: str = Field(min_length=PASSWORD_MIN, max_length=128)
    purpose: str = Field("bind", pattern=PURPOSE_PATTERN)
    display_name: str | None = Field(default=None, max_length=80)
    device_name: str = "iPhone"


class EmailLoginIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)
    device_name: str = "iPhone"
    device_model: str | None = None
    app_version: str | None = None


class CodeSentOut(BaseModel):
    sent: bool
    resend_after_seconds: int
    # Only ever set when no relay is configured, so a code stays reachable
    # while mail delivery is still being set up. Never filled in production.
    debug_code: str | None = None


class VerifiedOut(BaseModel):
    verified: bool
    needs_password: bool


def _normalise(email: str) -> str:
    return email.strip().lower()


def _weak(password: str) -> str | None:
    if len(password) < PASSWORD_MIN:
        return f"Пароль должен быть не короче {PASSWORD_MIN} символов"
    if not re.search(r"[A-Za-zА-Яа-я]", password):
        return "Добавьте в пароль хотя бы одну букву"
    if not re.search(r"\d", password):
        return "Добавьте в пароль хотя бы одну цифру"
    return None


async def _latest_code(session, email: str, purpose: str) -> EmailVerification | None:
    return (
        await session.scalars(
            select(EmailVerification)
            .where(
                EmailVerification.email == email,
                EmailVerification.purpose == purpose,
                EmailVerification.consumed_at.is_(None),
            )
            .order_by(desc(EmailVerification.created_at))
            .limit(1)
        )
    ).first()


async def _user_by_email(session, email: str) -> User | None:
    return (
        await session.scalars(select(User).where(func.lower(User.email) == email).limit(1))
    ).first()


@router.post("/request-code", response_model=CodeSentOut)
async def request_code(payload: RequestCodeIn, session: SessionDep) -> CodeSentOut:
    email = _normalise(payload.email)
    now = datetime.now(UTC)

    existing = await _latest_code(session, email, payload.purpose)
    if existing and now - existing.created_at < RESEND_INTERVAL:
        wait = RESEND_INTERVAL - (now - existing.created_at)
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Новый код можно запросить через {int(wait.total_seconds())} с",
        )

    owner = await _user_by_email(session, email)

    if payload.purpose in ("login", "reset") and owner is None:
        # Deliberately not saying whether the address exists — that would turn
        # this endpoint into a way to enumerate accounts.
        return CodeSentOut(
            sent=True, resend_after_seconds=int(RESEND_INTERVAL.total_seconds())
        )

    if payload.purpose == "bind" and owner is not None and owner.email_verified:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Эта почта уже привязана к другому аккаунту",
        )

    # Supersede anything outstanding, so an older code cannot still be used.
    if existing:
        existing.consumed_at = now

    code = generate_email_code()
    session.add(
        EmailVerification(
            email=email,
            purpose=payload.purpose,
            code_hash=hash_email_code(code, email),
            expires_at=now + CODE_TTL,
            user_id=owner.id if owner else None,
        )
    )
    await session.commit()

    subject, html, text = mailer.code_email(code, payload.purpose)
    await mailer.send(email, subject, html, text)

    return CodeSentOut(
        sent=True,
        resend_after_seconds=int(RESEND_INTERVAL.total_seconds()),
        debug_code=None if settings.smtp_host else code,
    )


async def _check_code(session, email: str, code: str, purpose: str) -> EmailVerification:
    """Validates a code without spending it. Raises with a showable message."""
    record = await _latest_code(session, email, purpose)
    now = datetime.now(UTC)

    if record is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Запросите код заново"
        )

    if record.expires_at < now:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Срок действия кода истёк"
        )

    if record.attempts >= MAX_ATTEMPTS:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Слишком много попыток. Запросите новый код",
        )

    if record.code_hash != hash_email_code(code, email):
        record.attempts += 1
        await session.commit()
        left = MAX_ATTEMPTS - record.attempts
        detail = (
            f"Неверный код. Осталось попыток: {left}"
            if left > 0
            else "Неверный код. Запросите новый"
        )
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=detail)

    return record


@router.post("/verify-code", response_model=VerifiedOut)
async def verify_code(payload: VerifyCodeIn, session: SessionDep) -> VerifiedOut:
    """Checks the code without consuming it.

    The app asks for a password only after the code is accepted, so this has
    to answer before that password exists.
    """
    email = _normalise(payload.email)
    await _check_code(session, email, payload.code, payload.purpose)

    owner = await _user_by_email(session, email)

    return VerifiedOut(
        verified=True,
        needs_password=owner is None or owner.password_hash is None,
    )


def _new_device(user_id, name: str, model: str | None = None, version: str | None = None) -> Device:
    return Device(
        user_id=user_id,
        name=name,
        model=model,
        app_version=version,
        refresh_token_hash="",
    )


@router.post("/set-password", response_model=SessionOut)
async def set_password(payload: SetPasswordIn, session: SessionDep, ip: ClientIP) -> SessionOut:
    """Completes binding or registration and hands back a session."""
    email = _normalise(payload.email)
    record = await _check_code(session, email, payload.code, payload.purpose)

    problem = _weak(payload.password)
    if problem:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=problem
        )

    user = await _user_by_email(session, email)
    is_new = user is None

    if user is None:
        display = (payload.display_name or email.split("@")[0]).strip()[:80] or "Слушатель"
        user = User(
            email=email,
            display_name=display,
            username=await generate_unique_username(session, display),
            email_verified=True,
            password_hash=hash_password(payload.password),
        )
        session.add(user)
        await session.flush()
    else:
        user.email_verified = True
        user.password_hash = hash_password(payload.password)

    record.consumed_at = datetime.now(UTC)

    device = _new_device(user.id, payload.device_name)
    session.add(device)
    await session.flush()

    refresh = create_refresh_token(user.id, device.id)
    device.refresh_token_hash = hash_refresh_token(refresh)
    device.last_used_at = datetime.now(UTC)

    session.add(AuditLog(actor_id=user.id, action="email.bound", ip=ip, payload={"email": email}))
    await session.commit()
    await session.refresh(user)

    subject, html, text = mailer.notice_email(
        "Почта привязана",
        "Теперь вы можете входить в Laxify по почте и паролю. "
        "Если это были не вы — смените пароль в настройках.",
    )
    await mailer.send(email, subject, html, text)

    return SessionOut(
        tokens=TokenPair(
            access_token=create_access_token(user.id, device.id),
            refresh_token=refresh,
            expires_in=settings.access_token_ttl_minutes * 60,
        ),
        is_new_user=is_new,
        needs_onboarding=not user.has_completed_onboarding,
        needs_local_migration=not user.has_migrated_local_data,
    )


class RegisterIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=PASSWORD_MIN, max_length=128)
    display_name: str | None = Field(default=None, max_length=80)
    device_name: str = "iPhone"


@router.post("/register", response_model=SessionOut)
async def register(payload: RegisterIn, session: SessionDep, ip: ClientIP) -> SessionOut:
    """Creates an account from an address and a password, with no code.

    Confirming the address is worth doing, but making it a gate means nobody
    can sign up at all until mail delivery works — and what is behind this
    account is a music library, not a payment method. So the address is taken
    on trust here and confirmed later, from settings, where a code that fails
    to arrive costs nothing.
    """
    email = _normalise(payload.email)

    existing = await _user_by_email(session, email)
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Аккаунт с этой почтой уже есть — войдите",
        )

    problem = _weak(payload.password)
    if problem:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=problem)

    display = (payload.display_name or email.split("@")[0]).strip()[:80] or "Слушатель"
    user = User(
        email=email,
        display_name=display,
        username=await generate_unique_username(session, display),
        email_verified=False,
        password_hash=hash_password(payload.password),
    )
    session.add(user)
    await session.flush()

    device = _new_device(user.id, payload.device_name)
    session.add(device)
    await session.flush()

    refresh = create_refresh_token(user.id, device.id)
    device.refresh_token_hash = hash_refresh_token(refresh)
    device.last_used_at = datetime.now(UTC)

    session.add(AuditLog(actor_id=user.id, action="register.email", ip=ip))
    await session.commit()
    await session.refresh(user)

    return SessionOut(
        tokens=TokenPair(
            access_token=create_access_token(user.id, device.id),
            refresh_token=refresh,
            expires_in=settings.access_token_ttl_minutes * 60,
        ),
        is_new_user=True,
        needs_onboarding=not user.has_completed_onboarding,
        needs_local_migration=not user.has_migrated_local_data,
    )


@router.post("/login", response_model=SessionOut)
async def login(payload: EmailLoginIn, session: SessionDep, ip: ClientIP) -> SessionOut:
    email = _normalise(payload.email)
    user = await _user_by_email(session, email)

    # Identical response for a missing account and a wrong password, so this
    # cannot be used to discover which addresses are registered.
    invalid = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="Неверная почта или пароль"
    )

    if user is None or not user.password_hash:
        raise invalid

    if not verify_password(payload.password, user.password_hash):
        session.add(AuditLog(actor_id=user.id, action="login.failed", ip=ip, payload={"method": "email"}))
        await session.commit()
        raise invalid

    if user.is_banned:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=user.ban_reason or "Аккаунт заблокирован",
        )

    device = _new_device(user.id, payload.device_name, payload.device_model, payload.app_version)
    session.add(device)
    await session.flush()

    refresh = create_refresh_token(user.id, device.id)
    device.refresh_token_hash = hash_refresh_token(refresh)
    device.last_used_at = datetime.now(UTC)
    user.last_seen_at = datetime.now(UTC)

    session.add(AuditLog(actor_id=user.id, action="login.email", ip=ip))
    await session.commit()
    await session.refresh(user)

    return SessionOut(
        tokens=TokenPair(
            access_token=create_access_token(user.id, device.id),
            refresh_token=refresh,
            expires_in=settings.access_token_ttl_minutes * 60,
        ),
        is_new_user=False,
        needs_onboarding=not user.has_completed_onboarding,
        needs_local_migration=not user.has_migrated_local_data,
    )


class ChangeEmailIn(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=4, pattern=r"^\d{4}$")


@router.post("/change", response_model=MessageOut)
async def change_email(
    payload: ChangeEmailIn, user: CurrentUser, session: SessionDep, ip: ClientIP
) -> MessageOut:
    email = _normalise(payload.email)

    taken = await _user_by_email(session, email)
    if taken is not None and taken.id != user.id:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Эта почта занята")

    record = await _check_code(session, email, payload.code, "change")
    record.consumed_at = datetime.now(UTC)

    previous = user.email
    user.email = email
    user.email_verified = True
    session.add(AuditLog(actor_id=user.id, action="email.changed", ip=ip, payload={"email": email}))
    await session.commit()

    if previous and previous.lower() != email:
        subject, html, text = mailer.notice_email(
            "Почта изменена",
            f"Адрес аккаунта изменён на {email}. "
            "Если это были не вы — немедленно смените пароль.",
        )
        await mailer.send(previous, subject, html, text)

    return MessageOut(message="Почта привязана")


class ChangePasswordIn(BaseModel):
    current_password: str | None = None
    new_password: str = Field(min_length=PASSWORD_MIN, max_length=128)


@router.post("/password", response_model=MessageOut)
async def change_password(
    payload: ChangePasswordIn, user: CurrentUser, session: SessionDep, ip: ClientIP
) -> MessageOut:
    if user.password_hash:
        if not payload.current_password or not verify_password(
            payload.current_password, user.password_hash
        ):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail="Текущий пароль неверен"
            )

    problem = _weak(payload.new_password)
    if problem:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=problem
        )

    user.password_hash = hash_password(payload.new_password)
    session.add(AuditLog(actor_id=user.id, action="password.changed", ip=ip))
    await session.commit()

    return MessageOut(message="Пароль обновлён")
