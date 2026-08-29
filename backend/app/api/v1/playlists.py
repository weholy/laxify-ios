from datetime import UTC, datetime, timedelta
from uuid import UUID

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
from app.schemas.common import MessageOut, Page
from app.services import authenticity
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
    return _detail(
        playlist,
        can_edit=await _can_edit(session, playlist, viewer),
        items=await _visible_items(session, playlist),
    )


@router.get("/shared/{share_slug}", response_model=PlaylistDetailOut)
async def read_shared_playlist(
    share_slug: str, session: SessionDep, viewer: OptionalUser
) -> PlaylistDetailOut:
    playlist = await session.scalar(select(Playlist).where(Playlist.share_slug == share_slug))
    if playlist is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Плейлист не найден")
    loaded = await _load(session, playlist.id)
    _ensure_visible(loaded, viewer)
    return _detail(
        loaded,
        can_edit=await _can_edit(session, loaded, viewer),
        items=await _visible_items(session, loaded),
    )


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
