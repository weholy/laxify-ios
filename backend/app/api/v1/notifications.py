from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Query
from sqlalchemy import func, select, update

from app.api.deps import CurrentUser, SessionDep
from app.models import Notification
from app.schemas.common import MessageOut
from app.schemas.social import GifItemOut, NotificationOut, UnreadCountOut
from app.services.gif import search_gifs

router = APIRouter(tags=["notifications"])


def _serialise(row: Notification) -> NotificationOut:
    actor = row.actor
    return NotificationOut(
        id=row.id,
        kind=row.kind,
        title=row.title,
        body=row.body,
        actor_avatar_url=actor.avatar_url if actor else None,
        actor_username=actor.username if actor else None,
        payload=row.payload or {},
        is_read=row.read_at is not None,
        created_at=row.created_at,
    )


@router.get("/notifications", response_model=list[NotificationOut])
async def list_notifications(
    session: SessionDep,
    user: CurrentUser,
    limit: int = Query(40, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> list[NotificationOut]:
    rows = (
        await session.scalars(
            select(Notification)
            .where(Notification.user_id == user.id)
            .order_by(Notification.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()
    return [_serialise(r) for r in rows]


@router.get("/notifications/unread-count", response_model=UnreadCountOut)
async def unread_count(session: SessionDep, user: CurrentUser) -> UnreadCountOut:
    total = await session.scalar(
        select(func.count())
        .select_from(Notification)
        .where(Notification.user_id == user.id, Notification.read_at.is_(None))
    )
    return UnreadCountOut(count=total or 0)


@router.post("/notifications/read", response_model=MessageOut)
async def mark_read(session: SessionDep, user: CurrentUser) -> MessageOut:
    await session.execute(
        update(Notification)
        .where(Notification.user_id == user.id, Notification.read_at.is_(None))
        .values(read_at=datetime.now(UTC))
    )
    await session.commit()
    return MessageOut(detail="Отмечено прочитанным")


@router.delete("/notifications/{notification_id}", response_model=MessageOut)
async def delete_notification(
    notification_id: UUID, session: SessionDep, user: CurrentUser
) -> MessageOut:
    row = await session.get(Notification, notification_id)
    if row is not None and row.user_id == user.id:
        await session.delete(row)
        await session.commit()
    return MessageOut(detail="Удалено")


# GIF search lives here too — same "social extras" surface, one router to wire.
@router.get("/gif/search", response_model=list[GifItemOut])
async def gif_search(
    _: CurrentUser,
    q: str = Query("", max_length=100),
    limit: int = Query(24, ge=1, le=50),
) -> list[GifItemOut]:
    return await search_gifs(q, limit)
