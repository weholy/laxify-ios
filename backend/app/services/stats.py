from datetime import UTC, date, datetime, timedelta
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ListeningEvent, ListeningStat, TrackSnapshot

# A play only counts once the listener has stayed with it — otherwise
# skipping through a queue would inflate totals and poison recommendations.
MIN_MEANINGFUL_SECONDS = 20.0


async def get_or_create_stats(session: AsyncSession, user_id: UUID) -> ListeningStat:
    stats = await session.get(ListeningStat, user_id)
    if stats is None:
        stats = ListeningStat(user_id=user_id)
        session.add(stats)
        await session.flush()
    return stats


def _advance_streak(stats: ListeningStat, day: date) -> None:
    last = stats.last_listened_day
    if last == day:
        return

    if last is not None and day - last == timedelta(days=1):
        stats.current_streak_days += 1
    elif last is None or day > last:
        stats.current_streak_days = 1
    else:
        # Backfilled event from an earlier day; totals still count but the
        # streak is driven by the most recent day only.
        return

    stats.longest_streak_days = max(stats.longest_streak_days, stats.current_streak_days)
    stats.last_listened_day = day


async def apply_events(
    session: AsyncSession, user_id: UUID, events: list[ListeningEvent]
) -> ListeningStat:
    stats = await get_or_create_stats(session, user_id)

    for event in events:
        stats.total_seconds += max(event.seconds_played, 0)
        if event.seconds_played >= MIN_MEANINGFUL_SECONDS or event.completed:
            stats.total_tracks += 1
            _advance_streak(stats, event.played_at.astimezone(UTC).date())

    return stats


async def refresh_top_lists(session: AsyncSession, user_id: UUID, days: int = 90) -> ListeningStat:
    """Recompute the leaderboards shown on the profile."""
    since = datetime.now(UTC) - timedelta(days=days)
    stats = await get_or_create_stats(session, user_id)

    artist_rows = (
        await session.execute(
            select(
                ListeningEvent.artist_id,
                func.max(TrackSnapshot.artist_name),
                func.sum(ListeningEvent.seconds_played),
                func.count(),
            )
            .join(TrackSnapshot, TrackSnapshot.track_id == ListeningEvent.track_id, isouter=True)
            .where(
                ListeningEvent.user_id == user_id,
                ListeningEvent.played_at >= since,
                ListeningEvent.artist_id.is_not(None),
            )
            .group_by(ListeningEvent.artist_id)
            .order_by(func.sum(ListeningEvent.seconds_played).desc())
            .limit(10)
        )
    ).all()

    stats.top_artists = [
        {
            "artist_id": row[0],
            "artist_name": row[1] or "",
            "seconds": float(row[2] or 0),
            "play_count": row[3],
        }
        for row in artist_rows
    ]

    track_rows = (
        await session.execute(
            select(
                ListeningEvent.track_id,
                func.sum(ListeningEvent.seconds_played),
                func.count(),
            )
            .where(ListeningEvent.user_id == user_id, ListeningEvent.played_at >= since)
            .group_by(ListeningEvent.track_id)
            .order_by(func.sum(ListeningEvent.seconds_played).desc())
            .limit(10)
        )
    ).all()

    track_ids = [row[0] for row in track_rows]
    snapshots = {
        snap.track_id: snap
        for snap in (
            await session.scalars(
                select(TrackSnapshot).where(TrackSnapshot.track_id.in_(track_ids))
            )
        ).all()
    }

    stats.top_tracks = [
        {
            "track": {
                "track_id": row[0],
                "title": snapshots[row[0]].title,
                "artist_name": snapshots[row[0]].artist_name,
                "artist_id": snapshots[row[0]].artist_id,
                "album_title": snapshots[row[0]].album_title,
                "album_id": snapshots[row[0]].album_id,
                "cover_url": snapshots[row[0]].cover_url,
                "duration_seconds": snapshots[row[0]].duration_seconds,
            },
            "seconds": float(row[1] or 0),
            "play_count": row[2],
        }
        for row in track_rows
        if row[0] in snapshots
    ]

    return stats
