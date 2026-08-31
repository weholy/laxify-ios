from datetime import UTC, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from app.api.deps import AdminUser, SessionDep
from app.models import (
    AuditLog,
    Device,
    DislikedTrack,
    Download,
    Favorite,
    Follow,
    ListeningEvent,
    Notification,
    Playlist,
    PlaylistItem,
    SearchHistoryEntry,
    TrackComment,
    TrackSnapshot,
    User,
    YandexToken,
)
from app.schemas.common import MessageOut, Page

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


class AdminUserOut(BaseModel):
    """What the panel needs in order to recognise someone and act on them.

    Deliberately more than `UserPublic`: an operator identifies an account by
    its address, and a list you ban from is useless without the ban flag.
    """

    model_config = {"from_attributes": True}

    id: UUID
    username: str
    display_name: str
    email: str
    avatar_url: str | None = None
    google_avatar_url: str | None = None
    is_banned: bool = False
    ban_reason: str | None = None
    is_admin: bool = False
    created_at: datetime
    last_seen_at: datetime | None = None


class NotifyIn(BaseModel):
    title: str = Field(max_length=160)
    body: str = Field(default="", max_length=2000)


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


@router.get("/users", response_model=Page[AdminUserOut])
async def list_users(
    admin: AdminUser,
    session: SessionDep,
    q: str | None = Query(default=None, max_length=64),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> Page[AdminUserOut]:
    stmt = select(User)
    count_stmt = select(func.count()).select_from(User)

    if q:
        pattern = f"%{q.lower()}%"
        condition = (
            func.lower(User.username).like(pattern)
            | func.lower(User.email).like(pattern)
            | func.lower(User.display_name).like(pattern)
        )
        stmt = stmt.where(condition)
        count_stmt = count_stmt.where(condition)

    total = await session.scalar(count_stmt) or 0
    rows = (
        await session.scalars(stmt.order_by(User.created_at.desc()).limit(limit).offset(offset))
    ).all()
    return Page(
        items=[AdminUserOut.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.post("/users/{user_id}/notify", response_model=MessageOut)
async def notify_user(
    user_id: UUID, payload: NotifyIn, admin: AdminUser, session: SessionDep
) -> MessageOut:
    """Drops a notice into one person's bell feed.

    Written as `kind="system"` so it renders the same as anything else the
    app sends itself — the recipient has no reason to be told which human
    pressed the button.
    """
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")

    session.add(
        Notification(
            user_id=user_id,
            kind="system",
            title=payload.title,
            body=payload.body,
        )
    )
    session.add(
        AuditLog(
            actor_id=admin.id,
            action="admin.notify",
            target_type="user",
            target_id=str(user_id),
            payload={"title": payload.title},
        )
    )
    return MessageOut(detail="Уведомление отправлено")


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


# ---------------------------------------------------------------------------
# Everything below is what the in-app panel reads. Kept together rather than
# scattered through the file above, so the panel's surface is one thing to
# look at.
# ---------------------------------------------------------------------------


class UserStatsOut(BaseModel):
    """One person, counted.

    Every figure here is a separate question an operator actually asks — "do
    they use it?", "did they ever come back?", "is this a real account?" — so
    they are gathered in one round trip rather than one screen each.
    """

    favorites: int = 0
    disliked: int = 0
    playlists: int = 0
    playlist_tracks: int = 0
    plays_total: int = 0
    plays_7d: int = 0
    plays_24h: int = 0
    minutes_total: int = 0
    distinct_tracks: int = 0
    distinct_artists: int = 0
    completed_plays: int = 0
    devices: int = 0
    followers: int = 0
    following: int = 0
    comments: int = 0
    searches: int = 0
    downloads: int = 0
    notifications: int = 0
    unread_notifications: int = 0
    days_with_music: int = 0
    first_play_at: datetime | None = None
    last_play_at: datetime | None = None
    top_artist: str | None = None
    top_track: str | None = None


@router.get("/users/{user_id}/stats", response_model=UserStatsOut)
async def user_stats(user_id: UUID, admin: AdminUser, session: SessionDep) -> UserStatsOut:
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")

    now = datetime.now(UTC)
    week_ago = now - timedelta(days=7)
    day_ago = now - timedelta(days=1)

    async def count(stmt) -> int:
        return await session.scalar(stmt) or 0

    plays = select(func.count()).select_from(ListeningEvent).where(ListeningEvent.user_id == user_id)

    top_artist_row = (
        await session.execute(
            select(ListeningEvent.artist_id, func.count().label("n"))
            .where(ListeningEvent.user_id == user_id, ListeningEvent.artist_id.is_not(None))
            .group_by(ListeningEvent.artist_id)
            .order_by(func.count().desc())
            .limit(1)
        )
    ).first()

    top_track_row = (
        await session.execute(
            select(ListeningEvent.track_id, func.count().label("n"))
            .where(ListeningEvent.user_id == user_id)
            .group_by(ListeningEvent.track_id)
            .order_by(func.count().desc())
            .limit(1)
        )
    ).first()

    top_track_name = None
    if top_track_row is not None:
        snapshot = (
            await session.execute(
                select(TrackSnapshot.title, TrackSnapshot.artist_name).where(
                    TrackSnapshot.track_id == top_track_row[0]
                )
            )
        ).first()
        if snapshot is not None:
            top_track_name = f"{snapshot[0]} — {snapshot[1]}"

    top_artist_name = None
    if top_artist_row is not None:
        artist_snapshot = (
            await session.execute(
                select(TrackSnapshot.artist_name)
                .where(TrackSnapshot.artist_id == top_artist_row[0])
                .limit(1)
            )
        ).first()
        top_artist_name = artist_snapshot[0] if artist_snapshot else None

    return UserStatsOut(
        favorites=await count(
            select(func.count()).select_from(Favorite).where(Favorite.user_id == user_id)
        ),
        disliked=await count(
            select(func.count()).select_from(DislikedTrack).where(DislikedTrack.user_id == user_id)
        ),
        playlists=await count(
            select(func.count()).select_from(Playlist).where(Playlist.owner_id == user_id)
        ),
        playlist_tracks=await count(
            select(func.count())
            .select_from(PlaylistItem)
            .join(Playlist, Playlist.id == PlaylistItem.playlist_id)
            .where(Playlist.owner_id == user_id)
        ),
        plays_total=await count(plays),
        plays_7d=await count(plays.where(ListeningEvent.played_at >= week_ago)),
        plays_24h=await count(plays.where(ListeningEvent.played_at >= day_ago)),
        minutes_total=int(
            (
                await session.scalar(
                    select(func.coalesce(func.sum(ListeningEvent.seconds_played), 0)).where(
                        ListeningEvent.user_id == user_id
                    )
                )
                or 0
            )
            // 60
        ),
        distinct_tracks=await count(
            select(func.count(func.distinct(ListeningEvent.track_id))).where(
                ListeningEvent.user_id == user_id
            )
        ),
        distinct_artists=await count(
            select(func.count(func.distinct(ListeningEvent.artist_id))).where(
                ListeningEvent.user_id == user_id, ListeningEvent.artist_id.is_not(None)
            )
        ),
        completed_plays=await count(plays.where(ListeningEvent.completed.is_(True))),
        devices=await count(
            select(func.count()).select_from(Device).where(Device.user_id == user_id)
        ),
        followers=await count(
            select(func.count()).select_from(Follow).where(Follow.following_id == user_id)
        ),
        following=await count(
            select(func.count()).select_from(Follow).where(Follow.follower_id == user_id)
        ),
        comments=await count(
            select(func.count()).select_from(TrackComment).where(TrackComment.author_id == user_id)
        ),
        searches=await count(
            select(func.count())
            .select_from(SearchHistoryEntry)
            .where(SearchHistoryEntry.user_id == user_id)
        ),
        downloads=await count(
            select(func.count()).select_from(Download).where(Download.user_id == user_id)
        ),
        notifications=await count(
            select(func.count()).select_from(Notification).where(Notification.user_id == user_id)
        ),
        unread_notifications=await count(
            select(func.count())
            .select_from(Notification)
            .where(Notification.user_id == user_id, Notification.read_at.is_(None))
        ),
        days_with_music=await count(
            select(func.count(func.distinct(func.date(ListeningEvent.played_at)))).where(
                ListeningEvent.user_id == user_id
            )
        ),
        first_play_at=await session.scalar(
            select(func.min(ListeningEvent.played_at)).where(ListeningEvent.user_id == user_id)
        ),
        last_play_at=await session.scalar(
            select(func.max(ListeningEvent.played_at)).where(ListeningEvent.user_id == user_id)
        ),
        top_artist=top_artist_name,
        top_track=top_track_name,
    )


class DayCount(BaseModel):
    day: str
    count: int


class NamedCount(BaseModel):
    name: str
    count: int


class StatsOut(BaseModel):
    """The whole service, counted — the panel's overview tab."""

    users_total: int = 0
    users_today: int = 0
    users_7d: int = 0
    users_30d: int = 0
    users_active_24h: int = 0
    users_active_7d: int = 0
    users_banned: int = 0
    users_admin: int = 0
    users_with_avatar: int = 0
    users_never_played: int = 0
    plays_total: int = 0
    plays_24h: int = 0
    plays_7d: int = 0
    minutes_total: int = 0
    distinct_tracks: int = 0
    distinct_artists: int = 0
    favorites_total: int = 0
    playlists_total: int = 0
    comments_total: int = 0
    notifications_total: int = 0
    devices_total: int = 0
    downloads_total: int = 0
    tokens_active: int = 0
    tokens_disabled: int = 0
    signups_by_day: list[DayCount] = Field(default_factory=list)
    plays_by_day: list[DayCount] = Field(default_factory=list)
    top_tracks: list[NamedCount] = Field(default_factory=list)
    top_artists: list[NamedCount] = Field(default_factory=list)


@router.get("/stats", response_model=StatsOut)
async def service_stats(admin: AdminUser, session: SessionDep) -> StatsOut:
    now = datetime.now(UTC)
    day_ago = now - timedelta(days=1)
    week_ago = now - timedelta(days=7)
    month_ago = now - timedelta(days=30)
    fortnight_ago = now - timedelta(days=14)

    async def count(stmt) -> int:
        return await session.scalar(stmt) or 0

    users = select(func.count()).select_from(User)
    plays = select(func.count()).select_from(ListeningEvent)

    signups = (
        await session.execute(
            select(func.date(User.created_at).label("d"), func.count())
            .where(User.created_at >= fortnight_ago)
            .group_by("d")
            .order_by("d")
        )
    ).all()

    plays_series = (
        await session.execute(
            select(func.date(ListeningEvent.played_at).label("d"), func.count())
            .where(ListeningEvent.played_at >= fortnight_ago)
            .group_by("d")
            .order_by("d")
        )
    ).all()

    top_tracks = (
        await session.execute(
            select(TrackSnapshot.title, TrackSnapshot.artist_name, func.count().label("n"))
            .join(ListeningEvent, ListeningEvent.track_id == TrackSnapshot.track_id)
            .group_by(TrackSnapshot.title, TrackSnapshot.artist_name)
            .order_by(func.count().desc())
            .limit(10)
        )
    ).all()

    top_artists = (
        await session.execute(
            select(TrackSnapshot.artist_name, func.count().label("n"))
            .join(ListeningEvent, ListeningEvent.track_id == TrackSnapshot.track_id)
            .group_by(TrackSnapshot.artist_name)
            .order_by(func.count().desc())
            .limit(10)
        )
    ).all()

    return StatsOut(
        users_total=await count(users),
        users_today=await count(users.where(User.created_at >= day_ago)),
        users_7d=await count(users.where(User.created_at >= week_ago)),
        users_30d=await count(users.where(User.created_at >= month_ago)),
        users_active_24h=await count(users.where(User.last_seen_at >= day_ago)),
        users_active_7d=await count(users.where(User.last_seen_at >= week_ago)),
        users_banned=await count(users.where(User.is_banned.is_(True))),
        users_admin=await count(users.where(User.is_admin.is_(True))),
        users_with_avatar=await count(users.where(User.avatar_url.is_not(None))),
        users_never_played=await count(
            users.where(
                ~select(ListeningEvent.id).where(ListeningEvent.user_id == User.id).exists()
            )
        ),
        plays_total=await count(plays),
        plays_24h=await count(plays.where(ListeningEvent.played_at >= day_ago)),
        plays_7d=await count(plays.where(ListeningEvent.played_at >= week_ago)),
        minutes_total=int(
            (
                await session.scalar(
                    select(func.coalesce(func.sum(ListeningEvent.seconds_played), 0))
                )
                or 0
            )
            // 60
        ),
        distinct_tracks=await count(select(func.count(func.distinct(ListeningEvent.track_id)))),
        distinct_artists=await count(
            select(func.count(func.distinct(ListeningEvent.artist_id))).where(
                ListeningEvent.artist_id.is_not(None)
            )
        ),
        favorites_total=await count(select(func.count()).select_from(Favorite)),
        playlists_total=await count(select(func.count()).select_from(Playlist)),
        comments_total=await count(select(func.count()).select_from(TrackComment)),
        notifications_total=await count(select(func.count()).select_from(Notification)),
        devices_total=await count(select(func.count()).select_from(Device)),
        downloads_total=await count(select(func.count()).select_from(Download)),
        tokens_active=await count(
            select(func.count()).select_from(YandexToken).where(YandexToken.is_active.is_(True))
        ),
        tokens_disabled=await count(
            select(func.count()).select_from(YandexToken).where(YandexToken.is_active.is_(False))
        ),
        signups_by_day=[DayCount(day=str(row[0]), count=row[1]) for row in signups],
        plays_by_day=[DayCount(day=str(row[0]), count=row[1]) for row in plays_series],
        top_tracks=[NamedCount(name=f"{row[0]} — {row[1]}", count=row[2]) for row in top_tracks],
        top_artists=[NamedCount(name=row[0], count=row[1]) for row in top_artists],
    )


class BroadcastIn(BaseModel):
    title: str = Field(max_length=160)
    body: str = Field(default="", max_length=2000)
    # Skip accounts that never played anything: a changelog is for listeners,
    # not for rows in a table.
    only_active: bool = False


@router.post("/broadcast", response_model=MessageOut)
async def broadcast(payload: BroadcastIn, admin: AdminUser, session: SessionDep) -> MessageOut:
    stmt = select(User.id).where(User.is_banned.is_(False))
    if payload.only_active:
        stmt = stmt.where(
            select(ListeningEvent.id).where(ListeningEvent.user_id == User.id).exists()
        )

    recipients = (await session.scalars(stmt)).all()
    for user_id in recipients:
        session.add(
            Notification(user_id=user_id, kind="system", title=payload.title, body=payload.body)
        )

    session.add(
        AuditLog(
            actor_id=admin.id,
            action="admin.broadcast",
            payload={"title": payload.title, "recipients": len(recipients)},
        )
    )
    return MessageOut(detail=f"Отправлено: {len(recipients)}")


class AdminFlagIn(BaseModel):
    is_admin: bool


@router.post("/users/{user_id}/admin", response_model=MessageOut)
async def set_admin(
    user_id: UUID, payload: AdminFlagIn, admin: AdminUser, session: SessionDep
) -> MessageOut:
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")
    if target.id == admin.id and not payload.is_admin:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Нельзя снять права с самого себя",
        )

    target.is_admin = payload.is_admin
    session.add(
        AuditLog(
            actor_id=admin.id,
            action="admin.set_admin",
            target_type="user",
            target_id=str(user_id),
            payload={"is_admin": payload.is_admin},
        )
    )
    return MessageOut(detail="Права обновлены")


@router.delete("/users/{user_id}", response_model=MessageOut)
async def delete_user(user_id: UUID, admin: AdminUser, session: SessionDep) -> MessageOut:
    """Removes an account and everything hanging off it.

    Every table that references a user cascades on delete, so this is one
    statement rather than a cleanup routine that can stop half-finished.
    """
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")
    if target.is_admin:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Нельзя удалить администратора"
        )

    session.add(
        AuditLog(
            actor_id=admin.id,
            action="admin.delete_user",
            target_type="user",
            target_id=str(user_id),
            payload={"username": target.username, "email": target.email},
        )
    )
    await session.delete(target)
    return MessageOut(detail="Аккаунт удалён")
