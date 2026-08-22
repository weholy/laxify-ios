from collections import defaultdict
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import DislikedTrack, Favorite, ListeningEvent, TrackSnapshot

# Weights for the taste profile. Listening is the honest signal (it is
# unprompted), a like is a deliberate stronger one, and a dislike has to
# outweigh both or disliked material keeps resurfacing.
WEIGHT_PLAY = 1.0
WEIGHT_LIKE = 4.0
WEIGHT_DISLIKE = -12.0
RECENCY_HALF_LIFE_DAYS = 21.0


def _recency_multiplier(played_at: datetime, now: datetime) -> float:
    age_days = max((now - played_at).total_seconds() / 86400, 0)
    return 0.5 ** (age_days / RECENCY_HALF_LIFE_DAYS)


async def build_artist_affinity(session: AsyncSession, user_id: UUID) -> dict[str, float]:
    """Score every artist the user has engaged with.

    Recent plays weigh more than old ones, so the feed follows what someone
    is into now rather than what they were into a year ago.
    """
    now = datetime.now(UTC)
    scores: dict[str, float] = defaultdict(float)

    since = now - timedelta(days=180)
    events = (
        await session.execute(
            select(ListeningEvent.artist_id, ListeningEvent.played_at, ListeningEvent.seconds_played)
            .where(
                ListeningEvent.user_id == user_id,
                ListeningEvent.played_at >= since,
                ListeningEvent.artist_id.is_not(None),
            )
            .limit(5000)
        )
    ).all()

    for artist_id, played_at, seconds in events:
        if not artist_id:
            continue
        # A partial listen counts proportionally, capped so one long podcast
        # cannot dominate the whole profile.
        engagement = min(float(seconds or 0) / 180.0, 1.5)
        scores[artist_id] += WEIGHT_PLAY * engagement * _recency_multiplier(played_at, now)

    liked = (
        await session.execute(
            select(TrackSnapshot.artist_id, func.count())
            .join(Favorite, Favorite.track_id == TrackSnapshot.track_id)
            .where(Favorite.user_id == user_id, TrackSnapshot.artist_id.is_not(None))
            .group_by(TrackSnapshot.artist_id)
        )
    ).all()

    for artist_id, count in liked:
        if artist_id:
            scores[artist_id] += WEIGHT_LIKE * min(count, 5)

    disliked = (
        await session.execute(
            select(TrackSnapshot.artist_id, func.count())
            .join(DislikedTrack, DislikedTrack.track_id == TrackSnapshot.track_id)
            .where(DislikedTrack.user_id == user_id, TrackSnapshot.artist_id.is_not(None))
            .group_by(TrackSnapshot.artist_id)
        )
    ).all()

    for artist_id, count in disliked:
        if artist_id:
            scores[artist_id] += WEIGHT_DISLIKE * min(count, 3)

    return {artist: score for artist, score in scores.items() if score > 0}


async def seed_artists(session: AsyncSession, user_id: UUID, limit: int = 8) -> list[str]:
    affinity = await build_artist_affinity(session, user_id)
    ranked = sorted(affinity.items(), key=lambda pair: pair[1], reverse=True)
    return [artist_id for artist_id, _ in ranked[:limit]]


async def excluded_track_ids(session: AsyncSession, user_id: UUID) -> set[str]:
    """Tracks the feed must not surface: disliked outright, or heard recently
    enough that repeating them would feel stale."""
    disliked = set(
        (
            await session.scalars(
                select(DislikedTrack.track_id).where(DislikedTrack.user_id == user_id)
            )
        ).all()
    )

    recent_cutoff = datetime.now(UTC) - timedelta(days=3)
    recent = set(
        (
            await session.scalars(
                select(ListeningEvent.track_id).where(
                    ListeningEvent.user_id == user_id,
                    ListeningEvent.played_at >= recent_cutoff,
                )
            )
        ).all()
    )

    return disliked | recent


async def rank_candidates(
    session: AsyncSession,
    user_id: UUID,
    candidates: list[dict],
) -> list[dict]:
    """Order a candidate pool by how well it matches the taste profile."""
    affinity = await build_artist_affinity(session, user_id)
    excluded = await excluded_track_ids(session, user_id)

    if not affinity:
        return [track for track in candidates if track.get("track_id") not in excluded]

    peak = max(affinity.values()) or 1.0
    scored: list[tuple[float, dict]] = []

    for track in candidates:
        track_id = track.get("track_id")
        if track_id in excluded:
            continue
        artist_id = track.get("artist_id")
        score = affinity.get(artist_id, 0.0) / peak if artist_id else 0.0
        scored.append((score, track))

    scored.sort(key=lambda pair: pair[0], reverse=True)
    return [track for _, track in scored]
