import asyncio
import re

from datetime import UTC, datetime, timedelta
from uuid import UUID
from pydantic import BaseModel, Field

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.deps import CurrentUser, OptionalUser, SessionDep
from app.core.security import generate_share_slug
from app.models import (
    Playlist,
    PlaylistCollaborator,
    PlaylistInvite,
    PlaylistItem,
    TrackSnapshot,
    User,
)
from app.schemas.common import MessageOut, Page, TrackIn
from app.services import authenticity, catalog_meta, playlist_import
from app.services.soundcloud import SoundCloudError, soundcloud
from app.schemas.library import (
    InviteCreate,
    InviteOut,
    PlaylistCreate,
    PlaylistDetailOut,
    PlaylistOut,
    PlaylistReorder,
    PlaylistTracksAdd,
    PlaylistUpdate,
)
from app.services.tracks import upsert_tracks

router = APIRouter(tags=["playlists"])

POSITION_STEP = 1000


async def _load(session: AsyncSession, playlist_id: UUID) -> Playlist:
    playlist = await session.scalar(
        select(Playlist)
        .where(Playlist.id == playlist_id)
        .options(
            selectinload(Playlist.items).selectinload(PlaylistItem.track),
            selectinload(Playlist.collaborators),
            selectinload(Playlist.owner),
        )
    )
    if playlist is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Плейлист не найден")
    return playlist


async def _can_edit(session: AsyncSession, playlist: Playlist, user: User | None) -> bool:
    if user is None:
        return False
    if playlist.owner_id == user.id:
        return True
    if not playlist.is_collaborative:
        return False
    link = await session.get(
        PlaylistCollaborator, {"playlist_id": playlist.id, "user_id": user.id}
    )
    return link is not None and link.can_edit


def _ensure_visible(playlist: Playlist, user: User | None) -> None:
    if playlist.is_public:
        return
    if user is not None and playlist.owner_id == user.id:
        return
    raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Плейлист закрыт")


async def _recount(session: AsyncSession, playlist: Playlist) -> None:
    totals = (
        await session.execute(
            select(func.count(), func.coalesce(func.sum(TrackSnapshot.duration_seconds), 0))
            .select_from(PlaylistItem)
            .join(TrackSnapshot, TrackSnapshot.track_id == PlaylistItem.track_id)
            .where(PlaylistItem.playlist_id == playlist.id)
        )
    ).one()
    playlist.track_count = totals[0] or 0
    playlist.total_duration_seconds = float(totals[1] or 0)


def _detail(playlist: Playlist, can_edit: bool, items=None) -> PlaylistDetailOut:
    source = playlist.items if items is None else items
    return PlaylistDetailOut(
        **PlaylistOut.model_validate(playlist).model_dump(),
        items=[
            {
                "id": item.id,
                "track": item.track,
                "position": item.position,
                "added_by_id": item.added_by_id,
                "created_at": item.created_at,
            }
            for item in source
        ],
        collaborators=[],
        can_edit=can_edit,
    )


async def _visible_items(session, playlist: Playlist) -> list:
    """Playlist tracks minus the ones credited to an unknown uploader."""
    return await authenticity.filter_by_reference(
        session,
        list(playlist.items),
        lambda it: it.track.artist_name if it.track else "",
        guard=False,
    )


@router.get("/playlists", response_model=Page[PlaylistOut])
async def list_my_playlists(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(100, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> Page[PlaylistOut]:
    collaborating = select(PlaylistCollaborator.playlist_id).where(
        PlaylistCollaborator.user_id == user.id
    )
    condition = (Playlist.owner_id == user.id) | (Playlist.id.in_(collaborating))

    total = await session.scalar(select(func.count()).select_from(Playlist).where(condition)) or 0
    rows = (
        await session.scalars(
            select(Playlist)
            .where(condition)
            .options(selectinload(Playlist.owner))
            .order_by(Playlist.updated_at.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()
    return Page(
        items=[PlaylistOut.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.post("/playlists", response_model=PlaylistDetailOut, status_code=status.HTTP_201_CREATED)
async def create_playlist(
    payload: PlaylistCreate, user: CurrentUser, session: SessionDep
) -> PlaylistDetailOut:
    playlist = Playlist(
        owner_id=user.id,
        title=payload.title,
        description=payload.description,
        cover_url=payload.cover_url,
        is_public=payload.is_public,
        is_collaborative=payload.is_collaborative,
        share_slug=generate_share_slug(),
    )
    session.add(playlist)
    await session.flush()

    if payload.tracks:
        await upsert_tracks(session, payload.tracks)
        for index, track in enumerate(payload.tracks):
            session.add(
                PlaylistItem(
                    playlist_id=playlist.id,
                    track_id=track.track_id,
                    position=index * POSITION_STEP,
                    added_by_id=user.id,
                )
            )
        await session.flush()

    await _recount(session, playlist)
    fresh = await _load(session, playlist.id)
    return _detail(fresh, can_edit=True)


@router.get("/playlists/{playlist_id}", response_model=PlaylistDetailOut)
async def read_playlist(
    playlist_id: UUID, session: SessionDep, viewer: OptionalUser
) -> PlaylistDetailOut:
    playlist = await _load(session, playlist_id)
    _ensure_visible(playlist, viewer)
    detail = _detail(
        playlist,
        can_edit=await _can_edit(session, playlist, viewer),
        items=await _visible_items(session, playlist),
    )
    return await catalog_meta.enrich_playlist_detail(detail)


@router.get("/shared/{share_slug}", response_model=PlaylistDetailOut)
async def read_shared_playlist(
    share_slug: str, session: SessionDep, viewer: OptionalUser
) -> PlaylistDetailOut:
    playlist = await session.scalar(select(Playlist).where(Playlist.share_slug == share_slug))
    if playlist is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Плейлист не найден")
    loaded = await _load(session, playlist.id)
    _ensure_visible(loaded, viewer)
    detail = _detail(
        loaded,
        can_edit=await _can_edit(session, loaded, viewer),
        items=await _visible_items(session, loaded),
    )
    return await catalog_meta.enrich_playlist_detail(detail)


@router.patch("/playlists/{playlist_id}", response_model=PlaylistOut)
async def update_playlist(
    playlist_id: UUID, payload: PlaylistUpdate, user: CurrentUser, session: SessionDep
) -> Playlist:
    playlist = await _load(session, playlist_id)
    if playlist.owner_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Менять настройки может только владелец"
        )

    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(playlist, field, value)
    return playlist


@router.delete("/playlists/{playlist_id}", response_model=MessageOut)
async def delete_playlist(playlist_id: UUID, user: CurrentUser, session: SessionDep) -> MessageOut:
    playlist = await session.get(Playlist, playlist_id)
    if playlist is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Плейлист не найден")
    if playlist.owner_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Удалить может только владелец"
        )
    await session.delete(playlist)
    return MessageOut(detail="Плейлист удалён")


@router.post("/playlists/{playlist_id}/tracks", response_model=MessageOut)
async def add_tracks(
    playlist_id: UUID, payload: PlaylistTracksAdd, user: CurrentUser, session: SessionDep
) -> MessageOut:
    playlist = await _load(session, playlist_id)
    if not await _can_edit(session, playlist, user):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Нет прав на изменение")

    await upsert_tracks(session, payload.tracks)

    existing = {item.track_id for item in playlist.items}
    last_position = max((item.position for item in playlist.items), default=-POSITION_STEP)

    added = 0
    for track in payload.tracks:
        if track.track_id in existing:
            continue
        existing.add(track.track_id)
        last_position += POSITION_STEP
        session.add(
            PlaylistItem(
                playlist_id=playlist.id,
                track_id=track.track_id,
                position=last_position,
                added_by_id=user.id,
            )
        )
        added += 1

    await session.flush()
    await _recount(session, playlist)
    return MessageOut(detail=f"Добавлено треков: {added}")


@router.delete("/playlists/{playlist_id}/tracks/{track_id}", response_model=MessageOut)
async def remove_track(
    playlist_id: UUID, track_id: str, user: CurrentUser, session: SessionDep
) -> MessageOut:
    playlist = await _load(session, playlist_id)
    if not await _can_edit(session, playlist, user):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Нет прав на изменение")

    await session.execute(
        delete(PlaylistItem).where(
            PlaylistItem.playlist_id == playlist_id, PlaylistItem.track_id == track_id
        )
    )
    await session.flush()
    await _recount(session, playlist)
    return MessageOut(detail="Трек убран из плейлиста")


@router.post("/playlists/{playlist_id}/reorder", response_model=MessageOut)
async def reorder_track(
    playlist_id: UUID, payload: PlaylistReorder, user: CurrentUser, session: SessionDep
) -> MessageOut:
    playlist = await _load(session, playlist_id)
    if not await _can_edit(session, playlist, user):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Нет прав на изменение")

    ordered = list(playlist.items)
    moving = next((item for item in ordered if item.track_id == payload.track_id), None)
    if moving is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Трек не найден")

    ordered.remove(moving)
    index = min(payload.new_index, len(ordered))

    # Sparse positions mean the moved row usually lands between two existing
    # values, so only that one row needs rewriting.
    before = ordered[index - 1].position if index > 0 else None
    after = ordered[index].position if index < len(ordered) else None

    if before is None and after is None:
        moving.position = 0
    elif before is None:
        moving.position = after - POSITION_STEP
    elif after is None:
        moving.position = before + POSITION_STEP
    elif after - before > 1:
        moving.position = before + (after - before) // 2
    else:
        # The gap here is used up, so renumber once and place it exactly.
        ordered.insert(index, moving)
        for slot, item in enumerate(ordered):
            item.position = slot * POSITION_STEP

    return MessageOut(detail="Порядок обновлён")


@router.post("/playlists/{playlist_id}/invites", response_model=InviteOut)
async def create_invite(
    playlist_id: UUID, payload: InviteCreate, user: CurrentUser, session: SessionDep
) -> PlaylistInvite:
    playlist = await session.get(Playlist, playlist_id)
    if playlist is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Плейлист не найден")
    if playlist.owner_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Приглашать может только владелец"
        )

    invite = PlaylistInvite(
        playlist_id=playlist_id,
        code=generate_share_slug(),
        created_by_id=user.id,
        max_uses=payload.max_uses,
        expires_at=(
            datetime.now(UTC) + timedelta(hours=payload.expires_in_hours)
            if payload.expires_in_hours
            else None
        ),
    )
    session.add(invite)
    await session.flush()
    return invite


@router.post("/invites/{code}/accept", response_model=PlaylistOut)
async def accept_invite(code: str, user: CurrentUser, session: SessionDep) -> Playlist:
    invite = await session.scalar(select(PlaylistInvite).where(PlaylistInvite.code == code))
    if invite is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Приглашение не найдено")
    if invite.expires_at is not None and invite.expires_at < datetime.now(UTC):
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="Срок приглашения истёк")
    if invite.max_uses is not None and invite.use_count >= invite.max_uses:
        raise HTTPException(
            status_code=status.HTTP_410_GONE, detail="Приглашение больше не действует"
        )

    playlist = await session.get(Playlist, invite.playlist_id)
    if playlist is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Плейлист не найден")

    if playlist.owner_id != user.id:
        existing = await session.get(
            PlaylistCollaborator, {"playlist_id": playlist.id, "user_id": user.id}
        )
        if existing is None:
            session.add(
                PlaylistCollaborator(playlist_id=playlist.id, user_id=user.id, can_edit=True)
            )
            invite.use_count += 1

    return playlist


@router.get("/users/{user_id}/playlists", response_model=Page[PlaylistOut])
async def list_user_playlists(
    user_id: UUID,
    session: SessionDep,
    viewer: OptionalUser,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> Page[PlaylistOut]:
    is_self = viewer is not None and viewer.id == user_id
    condition = Playlist.owner_id == user_id
    if not is_self:
        condition = condition & Playlist.is_public.is_(True)

    total = await session.scalar(select(func.count()).select_from(Playlist).where(condition)) or 0
    rows = (
        await session.scalars(
            select(Playlist)
            .where(condition)
            .options(selectinload(Playlist.owner))
            .order_by(Playlist.updated_at.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()
    return Page(
        items=[PlaylistOut.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


class PlaylistImportIn(BaseModel):
    url: str = Field(max_length=2000)
    # What to call it here. Empty means "whatever the source called it".
    title: str | None = Field(default=None, max_length=120)


class PlaylistImportOut(BaseModel):
    playlist_id: UUID
    title: str
    source: str
    total: int
    matched: int


@router.post("/playlists/import", response_model=PlaylistImportOut)
async def import_playlist(
    payload: PlaylistImportIn, user: CurrentUser, session: SessionDep
) -> PlaylistImportOut:
    """Builds one of our playlists out of somebody else's link.

    Tracks we cannot play are left out rather than added as dead rows — the
    response says how many of each, so the app can be honest about it without
    the playlist itself being half-broken.
    """
    try:
        source_title, entries, source = await playlist_import.read(payload.url)
    except playlist_import.ImportError_ as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=error.detail
        ) from error

    total = len(entries)

    # SoundCloud links already carry our own ids; everything else has to be
    # looked for by name.
    resolved: list[str] = []
    to_search: list[dict] = []

    for entry in entries[:200]:
        if entry.get("sc_track_id"):
            resolved.append(str(entry["sc_track_id"]))
        else:
            to_search.append(entry)

    unreachable = False

    if to_search:
        # Four at a time. Fifty parallel lookups is a burst the source
        # answers by throttling, which turns a slow import into an empty one.
        gate = asyncio.Semaphore(4)

        async def look(item: dict) -> str | None:
            async with gate:
                return await _match_track(item)

        found = await asyncio.gather(
            *(look(item) for item in to_search), return_exceptions=True
        )
        for track_id in found:
            if isinstance(track_id, str) and track_id:
                resolved.append(track_id)
            elif isinstance(track_id, Exception):
                unreachable = True

    # Nothing matched and the catalogue was not answering: that is a failure
    # to report, not a playlist to hand over empty.
    if not resolved and (unreachable or to_search):
        if not await _catalogue_reachable():
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Каталог сейчас не отвечает. Попробуйте импорт чуть позже",
            )

    # Order preserved, duplicates dropped.
    ordered = list(dict.fromkeys(resolved))

    playlist = Playlist(
        owner_id=user.id,
        title=(payload.title or source_title or "Импорт").strip()[:120],
        description=None,
        is_public=False,
        share_slug=generate_share_slug(),
    )
    session.add(playlist)
    await session.flush()

    if ordered:
        raw_tracks = await asyncio.gather(
            *(_snapshot_for(track_id) for track_id in ordered), return_exceptions=True
        )
        payload_tracks = [t for t in raw_tracks if isinstance(t, TrackIn)]
        if payload_tracks:
            await upsert_tracks(session, payload_tracks)
            for index, track in enumerate(payload_tracks):
                session.add(
                    PlaylistItem(
                        playlist_id=playlist.id,
                        track_id=track.track_id,
                        position=index * POSITION_STEP,
                        added_by_id=user.id,
                    )
                )
            await session.flush()

    await _recount(session, playlist)

    return PlaylistImportOut(
        playlist_id=playlist.id,
        title=playlist.title,
        source=source,
        total=total,
        matched=len(ordered),
    )


async def _catalogue_reachable() -> bool:
    """One cheap probe, so "nothing matched" and "nothing answered" are told
    apart before either is reported."""
    try:
        await soundcloud.search_tracks("music", limit=1)
        return True
    except SoundCloudError:
        return False


async def _match_track(entry: dict) -> str | None:
    """Our id for a "title by artist" pair, or nothing.

    Searched as one string because that is what the source indexes on, and
    only the first hit is taken: a second-best match on a playlist import is
    a wrong song, which is worse than a missing one.
    """
    title = (entry.get("title") or "").strip()
    artist = (entry.get("artist") or "").strip()
    if not title:
        return None

    query = f"{artist} {title}".strip()
    try:
        hits = await soundcloud.search_tracks(query, limit=5)
    except SoundCloudError:
        raise

    wanted = _simplify(title)
    for raw in hits:
        if not raw.get("id"):
            continue
        if _simplify(str(raw.get("title") or "")).find(wanted) >= 0 or wanted.find(
            _simplify(str(raw.get("title") or ""))
        ) >= 0:
            return str(raw["id"])

    return None


def _simplify(text: str) -> str:
    return re.sub(r"[^a-z0-9а-яё]+", "", text.lower())


async def _snapshot_for(track_id: str) -> TrackIn | None:
    try:
        raw = await soundcloud.track(track_id)
    except SoundCloudError:
        return None
    if not raw:
        return None

    user = raw.get("user") or {}
    return TrackIn(
        track_id=str(raw.get("id")),
        title=str(raw.get("title") or ""),
        artist_name=str(
            (raw.get("publisher_metadata") or {}).get("artist") or user.get("username") or ""
        ),
        artist_id=str(user.get("id")) if user.get("id") else None,
        album_title=(raw.get("publisher_metadata") or {}).get("album_title"),
        cover_url=raw.get("artwork_url"),
        duration_seconds=float(raw.get("full_duration") or raw.get("duration") or 0) / 1000,
        genre=raw.get("genre"),
    )
