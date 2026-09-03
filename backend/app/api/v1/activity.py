from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import delete, func, select, tuple_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import selectinload

from app.api.deps import CurrentDeviceId, CurrentUser, SessionDep
from app.models import Download, Favorite, ListeningEvent, SearchHistoryEntry, TrackSnapshot
from app.schemas.activity import (
    DownloadIn,
    DownloadOut,
    LocalMigrationIn,
    MigrationResultOut,
    PlaybackBatchIn,
    SearchHistoryIn,
    SearchHistoryOut,
    StatsOut,
)
from app.schemas.common import MessageOut, Page, TrackIn

# Accounts whose listening time is recorded at a multiple of what actually
# played, and by how much.
#
# Deliberate and temporary, set at the owner's request; to end it, empty this
# mapping. Written here rather than on the device so it does not depend on
# which build someone is running, and kept as data rather than scattered
# conditions so that turning it off is one edit.
#
# Note what it does *not* do: it changes what is written, so it applies from
# now on and never rewrites what is already stored, and every figure built
# from these rows — the year in review, the top lists, anything another
# listener can see on this profile — carries the multiple with it.
LISTENING_TIME_FACTORS: dict[str, float] = {
    "stuffiny": 2.0,
    "stuffinydev@gmail.com": 2.0,
}


def _listening_factor(user) -> float:
    for key in (user.username or "", user.email or ""):
        if factor := LISTENING_TIME_FACTORS.get(key.strip().lower()):
            return factor
    return 1.0
from app.services.stats import apply_events, get_or_create_stats, refresh_top_lists
from app.services.tracks import upsert_track, upsert_tracks

router = APIRouter(prefix="/me", tags=["activity"])


@router.post("/playback", response_model=StatsOut)
async def record_playback(
    payload: PlaybackBatchIn, user: CurrentUser, session: SessionDep
) -> StatsOut:
    await upsert_tracks(session, [event.track for event in payload.events])

    # Anything already recorded is dropped here rather than at the database,
    # so a retry succeeds quietly instead of failing the whole batch — and so
    # the totals below count only what was genuinely new.
    incoming = {
        (event.track.track_id, event.played_at): event
        for event in payload.events
    }

    already = set(
        (
            await session.execute(
                select(ListeningEvent.track_id, ListeningEvent.played_at).where(
                    ListeningEvent.user_id == user.id,
                    tuple_(ListeningEvent.track_id, ListeningEvent.played_at).in_(
                        list(incoming.keys())
                    ),
                )
            )
        ).all()
    ) if incoming else set()

    factor = _listening_factor(user)

    rows = [
        ListeningEvent(
            user_id=user.id,
            track_id=event.track.track_id,
            artist_id=event.track.artist_id,
            played_at=event.played_at,
            seconds_played=event.seconds_played * factor,
            completed=event.completed,
            source=event.source,
        )
        for key, event in incoming.items()
        if key not in already
    ]
    session.add_all(rows)

    stats = await apply_events(session, user.id, rows)
    await session.flush()
    return StatsOut.model_validate(stats)


@router.get("/stats", response_model=StatsOut)
async def read_stats(
    user: CurrentUser, session: SessionDep, refresh: bool = Query(False)
) -> StatsOut:
    stats = (
        await refresh_top_lists(session, user.id)
        if refresh
        else await get_or_create_stats(session, user.id)
    )
    return StatsOut.model_validate(stats)


@router.get("/history", response_model=Page[SearchHistoryOut])
async def read_search_history(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> Page[SearchHistoryOut]:
    total = (
        await session.scalar(
            select(func.count())
            .select_from(SearchHistoryEntry)
            .where(SearchHistoryEntry.user_id == user.id)
        )
        or 0
    )
    rows = (
        await session.scalars(
            select(SearchHistoryEntry)
            .where(SearchHistoryEntry.user_id == user.id)
            .order_by(SearchHistoryEntry.searched_at.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()
    return Page(
        items=[SearchHistoryOut.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.put("/history", response_model=MessageOut)
async def push_search_history(
    payload: SearchHistoryIn, user: CurrentUser, session: SessionDep
) -> MessageOut:
    searched_at = payload.searched_at or datetime.now(UTC)
    stmt = (
        insert(SearchHistoryEntry)
        .values(
            user_id=user.id,
            entity_id=payload.entity_id,
            kind=payload.kind,
            title=payload.title,
            subtitle=payload.subtitle,
            cover_url=payload.cover_url,
            searched_at=searched_at,
        )
        .on_conflict_do_update(
            index_elements=["user_id", "entity_id"],
            set_={"searched_at": searched_at, "title": payload.title},
        )
    )
    await session.execute(stmt)
    return MessageOut(detail="Записано")


@router.delete("/history", response_model=MessageOut)
async def clear_search_history(user: CurrentUser, session: SessionDep) -> MessageOut:
    await session.execute(
        delete(SearchHistoryEntry).where(SearchHistoryEntry.user_id == user.id)
    )
    return MessageOut(detail="История очищена")


@router.delete("/history/{entity_id}", response_model=MessageOut)
async def delete_history_entry(
    entity_id: str, user: CurrentUser, session: SessionDep
) -> MessageOut:
    await session.execute(
        delete(SearchHistoryEntry).where(
            SearchHistoryEntry.user_id == user.id, SearchHistoryEntry.entity_id == entity_id
        )
    )
    return MessageOut(detail="Удалено из истории")


@router.get("/downloads", response_model=list[DownloadOut])
async def list_downloads(user: CurrentUser, session: SessionDep) -> list[DownloadOut]:
    rows = (
        await session.scalars(
            select(Download)
            .where(Download.user_id == user.id)
            .options(selectinload(Download.track))
            .order_by(Download.created_at.desc())
        )
    ).all()
    return [DownloadOut.model_validate(row) for row in rows]


@router.put("/downloads", response_model=MessageOut)
async def register_download(
    payload: DownloadIn,
    user: CurrentUser,
    session: SessionDep,
    device_id: CurrentDeviceId,
) -> MessageOut:
    await upsert_track(session, payload.track)

    existing = await session.scalar(
        select(Download).where(
            Download.user_id == user.id, Download.track_id == payload.track.track_id
        )
    )
    if existing is None:
        session.add(
            Download(
                user_id=user.id,
                track_id=payload.track.track_id,
                device_id=device_id,
                size_bytes=payload.size_bytes,
            )
        )
    return MessageOut(detail="Трек отмечен как загруженный")


@router.delete("/downloads/{track_id}", response_model=MessageOut)
async def remove_download(track_id: str, user: CurrentUser, session: SessionDep) -> MessageOut:
    await session.execute(
        delete(Download).where(Download.user_id == user.id, Download.track_id == track_id)
    )
    return MessageOut(detail="Загрузка удалена")


@router.post("/migrate-local", response_model=MigrationResultOut)
async def migrate_local_data(
    payload: LocalMigrationIn, user: CurrentUser, session: SessionDep
) -> MigrationResultOut:
    """Import whatever the app stored on-device before this account existed.

    Runs once per account: re-running would double-count listening time,
    and the client has no way to know the server already has the data.
    """
    if user.has_migrated_local_data:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Данные уже перенесены"
        )

    favorites_payload: list[TrackIn] = []
    added_at_by_track: dict[str, datetime] = {}

    for raw in payload.favorites:
        try:
            track = TrackIn.model_validate(raw)
        except Exception:
            continue
        favorites_payload.append(track)
        added_raw = raw.get("added_at")
        if isinstance(added_raw, str):
            try:
                added_at_by_track[track.track_id] = datetime.fromisoformat(added_raw)
            except ValueError:
                pass

    if favorites_payload:
        await upsert_tracks(session, favorites_payload)

    known = set(
        (await session.scalars(select(Favorite.track_id).where(Favorite.user_id == user.id))).all()
    )

    favorites_imported = 0
    for track in favorites_payload:
        if track.track_id in known:
            continue
        known.add(track.track_id)
        session.add(
            Favorite(
                user_id=user.id,
                track_id=track.track_id,
                added_at=added_at_by_track.get(track.track_id, datetime.now(UTC)),
            )
        )
        favorites_imported += 1

    from app.models import DislikedTrack

    known_dislikes = set(
        (
            await session.scalars(
                select(DislikedTrack.track_id).where(DislikedTrack.user_id == user.id)
            )
        ).all()
    )
    dislikes_imported = 0
    for track_id in payload.disliked_track_ids:
        if track_id in known_dislikes:
            continue
        known_dislikes.add(track_id)
        session.add(DislikedTrack(user_id=user.id, track_id=track_id))
        dislikes_imported += 1

    history_imported = 0
    for entry in payload.search_history:
        stmt = (
            insert(SearchHistoryEntry)
            .values(
                user_id=user.id,
                entity_id=entry.entity_id,
                kind=entry.kind,
                title=entry.title,
                subtitle=entry.subtitle,
                cover_url=entry.cover_url,
                searched_at=entry.searched_at or datetime.now(UTC),
            )
            .on_conflict_do_nothing(index_elements=["user_id", "entity_id"])
        )
        await session.execute(stmt)
        history_imported += 1

    stats = await get_or_create_stats(session, user.id)
    stats.total_seconds += payload.total_seconds_listened

    user.has_migrated_local_data = True

    return MigrationResultOut(
        favorites_imported=favorites_imported,
        dislikes_imported=dislikes_imported,
        search_history_imported=history_imported,
        seconds_merged=payload.total_seconds_listened,
    )
