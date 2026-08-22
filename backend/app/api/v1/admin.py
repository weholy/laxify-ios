from datetime import UTC, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from app.api.deps import AdminUser, SessionDep
from app.models import (
    AuditLog,
    Device,
    Favorite,
    ListeningEvent,
    Playlist,
    User,
    YandexToken,
)
from app.schemas.common import MessageOut, Page
from app.schemas.user import UserPublic

router = APIRouter(prefix="/admin", tags=["admin"])


class OverviewOut(BaseModel):
    users_total: int
    users_active_7d: int
    playlists_total: int
    favorites_total: int
    plays_24h: int
    tokens_active: int
    tokens_disabled: int


class TokenIn(BaseModel):
    label: str = Field(max_length=64)
    token: str


class TokenOut(BaseModel):
    id: UUID
    label: str
    is_active: bool
    failure_count: int
    last_error: str | None
    last_used_at: datetime | None
    disabled_at: datetime | None
    # The credential itself is never returned — an admin panel has no reason
    # to display it, and echoing it back only widens the blast radius.
    token_preview: str


class BanIn(BaseModel):
    reason: str = Field(max_length=500)


@router.get("/overview", response_model=OverviewOut)
async def overview(admin: AdminUser, session: SessionDep) -> OverviewOut:
    now = datetime.now(UTC)
    week_ago = now - timedelta(days=7)
    day_ago = now - timedelta(days=1)

    return OverviewOut(
        users_total=await session.scalar(select(func.count()).select_from(User)) or 0,
        users_active_7d=await session.scalar(
            select(func.count()).select_from(User).where(User.last_seen_at >= week_ago)
        )
        or 0,
        playlists_total=await session.scalar(select(func.count()).select_from(Playlist)) or 0,
        favorites_total=await session.scalar(select(func.count()).select_from(Favorite)) or 0,
        plays_24h=await session.scalar(
            select(func.count())
            .select_from(ListeningEvent)
            .where(ListeningEvent.played_at >= day_ago)
        )
        or 0,
        tokens_active=await session.scalar(
            select(func.count()).select_from(YandexToken).where(YandexToken.is_active.is_(True))
        )
        or 0,
        tokens_disabled=await session.scalar(
            select(func.count()).select_from(YandexToken).where(YandexToken.is_active.is_(False))
        )
        or 0,
    )


@router.get("/users", response_model=Page[UserPublic])
async def list_users(
    admin: AdminUser,
    session: SessionDep,
    q: str | None = Query(default=None, max_length=64),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> Page[UserPublic]:
    stmt = select(User)
    count_stmt = select(func.count()).select_from(User)

    if q:
        pattern = f"%{q.lower()}%"
        condition = func.lower(User.username).like(pattern) | func.lower(User.email).like(pattern)
        stmt = stmt.where(condition)
        count_stmt = count_stmt.where(condition)

    total = await session.scalar(count_stmt) or 0
    rows = (
        await session.scalars(stmt.order_by(User.created_at.desc()).limit(limit).offset(offset))
    ).all()
    return Page(
        items=[UserPublic.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.post("/users/{user_id}/ban", response_model=MessageOut)
async def ban_user(
    user_id: UUID, payload: BanIn, admin: AdminUser, session: SessionDep
) -> MessageOut:
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")
    if target.is_admin:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Нельзя заблокировать администратора"
        )

    target.is_banned = True
    target.ban_reason = payload.reason

    # Kill live sessions immediately: a ban that only takes effect on next
    # sign-in is not a ban.
    devices = (await session.scalars(select(Device).where(Device.user_id == user_id))).all()
    for device in devices:
        device.revoked_at = datetime.now(UTC)

    session.add(
        AuditLog(
            actor_id=admin.id,
            action="admin.ban",
            target_type="user",
            target_id=str(user_id),
            payload={"reason": payload.reason},
        )
    )
    return MessageOut(detail="Пользователь заблокирован")


@router.post("/users/{user_id}/unban", response_model=MessageOut)
async def unban_user(user_id: UUID, admin: AdminUser, session: SessionDep) -> MessageOut:
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")
    target.is_banned = False
    target.ban_reason = None
    session.add(
        AuditLog(
            actor_id=admin.id, action="admin.unban", target_type="user", target_id=str(user_id)
        )
    )
    return MessageOut(detail="Блокировка снята")


@router.get("/tokens", response_model=list[TokenOut])
async def list_tokens(admin: AdminUser, session: SessionDep) -> list[TokenOut]:
    rows = (await session.scalars(select(YandexToken).order_by(YandexToken.created_at))).all()
    return [
        TokenOut(
            id=row.id,
            label=row.label,
            is_active=row.is_active,
            failure_count=row.failure_count,
            last_error=row.last_error,
            last_used_at=row.last_used_at,
            disabled_at=row.disabled_at,
            token_preview=f"{row.token[:6]}…{row.token[-4:]}" if len(row.token) > 12 else "…",
        )
        for row in rows
    ]


@router.post("/tokens", response_model=MessageOut, status_code=status.HTTP_201_CREATED)
async def add_token(payload: TokenIn, admin: AdminUser, session: SessionDep) -> MessageOut:
    session.add(YandexToken(label=payload.label, token=payload.token))
    session.add(AuditLog(actor_id=admin.id, action="admin.token_add", payload={"label": payload.label}))
    return MessageOut(detail="Ключ добавлен")


@router.post("/tokens/{token_id}/enable", response_model=MessageOut)
async def enable_token(token_id: UUID, admin: AdminUser, session: SessionDep) -> MessageOut:
    token = await session.get(YandexToken, token_id)
    if token is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ключ не найден")
    token.is_active = True
    token.disabled_at = None
    token.failure_count = 0
    token.last_error = None
    return MessageOut(detail="Ключ включён")


@router.delete("/tokens/{token_id}", response_model=MessageOut)
async def delete_token(token_id: UUID, admin: AdminUser, session: SessionDep) -> MessageOut:
    token = await session.get(YandexToken, token_id)
    if token is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ключ не найден")
    await session.delete(token)
    session.add(AuditLog(actor_id=admin.id, action="admin.token_delete", target_id=str(token_id)))
    return MessageOut(detail="Ключ удалён")


@router.get("/audit", response_model=Page[dict])
async def read_audit(
    admin: AdminUser,
    session: SessionDep,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> Page[dict]:
    total = await session.scalar(select(func.count()).select_from(AuditLog)) or 0
    rows = (
        await session.scalars(
            select(AuditLog).order_by(AuditLog.created_at.desc()).limit(limit).offset(offset)
        )
    ).all()
    return Page(
        items=[
            {
                "id": str(row.id),
                "actor_id": str(row.actor_id) if row.actor_id else None,
                "action": row.action,
                "target_type": row.target_type,
                "target_id": row.target_id,
                "payload": row.payload,
                "ip": row.ip,
                "created_at": row.created_at.isoformat(),
            }
            for row in rows
        ],
        total=total,
        limit=limit,
        offset=offset,
    )
