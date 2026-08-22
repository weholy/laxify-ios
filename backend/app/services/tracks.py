from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import TrackSnapshot
from app.schemas.common import TrackIn


async def upsert_track(session: AsyncSession, track: TrackIn) -> TrackSnapshot:
    """Store or refresh cached metadata for one track."""
    values = track.model_dump()
    statement = insert(TrackSnapshot).values(**values)
    stmt = (
        statement
        .on_conflict_do_update(
            index_elements=[TrackSnapshot.track_id],
            set_={
                "title": values["title"],
                "artist_name": values["artist_name"],
                "artist_id": values["artist_id"],
                "album_title": values["album_title"],
                "album_id": values["album_id"],
                "cover_url": values["cover_url"],
                "duration_seconds": values["duration_seconds"],
                # Only overwrite a known genre with another known one: the
                # client does not always have it, and losing it would empty
                # the listening stats that group by it.
                "genre": func.coalesce(statement.excluded.genre, TrackSnapshot.genre),
            },
        )
        .returning(TrackSnapshot)
    )
    return (await session.execute(stmt)).scalar_one()


async def upsert_tracks(session: AsyncSession, tracks: list[TrackIn]) -> dict[str, TrackSnapshot]:
    """Bulk variant — one statement instead of one per track.

    Duplicates within the batch are collapsed first, because Postgres rejects
    an ON CONFLICT update that touches the same row twice in one statement.
    """
    if not tracks:
        return {}

    unique: dict[str, TrackIn] = {track.track_id: track for track in tracks}
    payload = [track.model_dump() for track in unique.values()]

    stmt = (
        insert(TrackSnapshot)
        .values(payload)
        .on_conflict_do_update(
            index_elements=[TrackSnapshot.track_id],
            set_={
                "title": insert(TrackSnapshot).excluded.title,
                "artist_name": insert(TrackSnapshot).excluded.artist_name,
                "artist_id": insert(TrackSnapshot).excluded.artist_id,
                "album_title": insert(TrackSnapshot).excluded.album_title,
                "album_id": insert(TrackSnapshot).excluded.album_id,
                "cover_url": insert(TrackSnapshot).excluded.cover_url,
                "duration_seconds": insert(TrackSnapshot).excluded.duration_seconds,
                "genre": func.coalesce(
                    insert(TrackSnapshot).excluded.genre, TrackSnapshot.genre
                ),
            },
        )
    )
    await session.execute(stmt)

    rows = (
        await session.scalars(
            select(TrackSnapshot).where(TrackSnapshot.track_id.in_(list(unique)))
        )
    ).all()
    return {row.track_id: row for row in rows}
