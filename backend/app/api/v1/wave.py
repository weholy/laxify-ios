"""Personal wave.

Built from track stations rather than from artists. A station selects on how
a track *sounds* — genre, tempo, the crowd that listens to it — which is what
makes a wave feel like a wave instead of a shuffle of everyone you already
follow.

Seeds come from what the listener actually played and liked recently, so the
mix follows current taste, and anything disliked or heard in the last few days
is filtered out before it reaches them.
"""

import random
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import desc, select

from app.api.deps import CurrentUser, SessionDep
from app.api.v1.catalog import CatalogTrack, normalise_track
from app.models import DislikedTrack, Favorite, ListeningEvent
from app.services.soundcloud import SoundCloudError, soundcloud

router = APIRouter(prefix="/wave", tags=["wave"])

SEED_LIMIT = 6
RECENT_EXCLUSION_DAYS = 3
DISCOVERY_GENRES = ["hiphoprap", "pop", "electronic", "rnb", "rock", "dance"]


class WaveResponse(BaseModel):
    tracks: list[CatalogTrack]
    seed_track_ids: list[str]
    is_personalised: bool


async def _seed_track_ids(session, user_id) -> list[str]:
    """Recent likes first, then recent plays.

    Likes are the deliberate signal, plays the honest one; taking likes first
    keeps the wave anchored to music the listener chose to keep.
    """
    liked = (
        await session.scalars(
            select(Favorite.track_id)
            .where(Favorite.user_id == user_id)
            .order_by(desc(Favorite.added_at))
            .limit(SEED_LIMIT)
        )
    ).all()

    played = (
        await session.scalars(
            select(ListeningEvent.track_id)
            .where(
                ListeningEvent.user_id == user_id,
                ListeningEvent.seconds_played >= 30,
            )
            .order_by(desc(ListeningEvent.played_at))
            .limit(SEED_LIMIT * 3)
        )
    ).all()

    seeds: list[str] = []
    for track_id in list(liked) + list(played):
        if track_id not in seeds:
            seeds.append(track_id)
        if len(seeds) >= SEED_LIMIT:
            break

    return seeds


async def _excluded_track_ids(session, user_id) -> set[str]:
    disliked = set(
        (
            await session.scalars(
                select(DislikedTrack.track_id).where(DislikedTrack.user_id == user_id)
            )
        ).all()
    )

    cutoff = datetime.now(UTC) - timedelta(days=RECENT_EXCLUSION_DAYS)
    recent = set(
        (
            await session.scalars(
                select(ListeningEvent.track_id).where(
                    ListeningEvent.user_id == user_id,
                    ListeningEvent.played_at >= cutoff,
                )
            )
        ).all()
    )

    return disliked | recent


async def _discovery_tracks(limit: int) -> list[dict]:
    """Popular music, used when there is no listening history to build on.

    Several sources are tried in turn because SoundCloud's chart endpoints
    have become unreliable — a wave that plays nothing is the one outcome
    worth going to some length to avoid.
    """
    collected: list[dict] = []
    seen: set[str] = set()

    def take(items: list[dict]) -> None:
        for raw in items:
            track_id = str(raw.get("id"))
            if track_id and track_id not in seen:
                seen.add(track_id)
                collected.append(raw)

    take(await soundcloud.charts(limit=limit))

    if len(collected) < limit:
        for genre in random.sample(DISCOVERY_GENRES, k=min(3, len(DISCOVERY_GENRES))):
            take(await soundcloud.genre_tracks(genre, limit=limit))
            if len(collected) >= limit:
                break

    return collected[:limit]


@router.get("", response_model=WaveResponse)
async def personal_wave(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(40, ge=5, le=80),
    exclude_recent: bool = Query(True),
) -> WaveResponse:
    seeds = await _seed_track_ids(session, user.id)
    excluded = await _excluded_track_ids(session, user.id) if exclude_recent else set()

    collected: list[dict] = []
    seen: set[str] = set()

    for seed in seeds:
        try:
            batch = await soundcloud.station_tracks(seed, limit=40)
        except SoundCloudError:
            continue

        for raw in batch:
            track_id = str(raw.get("id"))
            if track_id in seen or track_id in excluded:
                continue
            seen.add(track_id)
            collected.append(raw)

        if len(collected) >= limit * 2:
            break

    # No history yet, or the stations came back thin: top up from what is
    # popular right now, so a new account still gets a full wave.
    if len(collected) < limit:
        for raw in await _discovery_tracks(limit * 2):
            track_id = str(raw.get("id"))
            if track_id not in seen and track_id not in excluded:
                seen.add(track_id)
                collected.append(raw)

    if not collected:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Не удалось собрать волну, попробуйте позже",
        )

    random.shuffle(collected)
    tracks = [t for t in (normalise_track(raw) for raw in collected) if t][:limit]

    return WaveResponse(
        tracks=tracks,
        seed_track_ids=seeds,
        is_personalised=bool(seeds),
    )


@router.get("/similar/{track_id}", response_model=list[CatalogTrack])
async def similar(track_id: str, user: CurrentUser, limit: int = Query(30, ge=1, le=50)):
    """Tracks that sound like this one — used to keep playback going when a
    queue runs out."""
    try:
        raw = await soundcloud.station_tracks(track_id, limit=limit)
    except SoundCloudError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(exc)) from exc

    return [t for t in (normalise_track(item) for item in raw) if t]


class HomeResponse(BaseModel):
    wave: list[CatalogTrack]
    for_you: list[CatalogTrack]
    charts: list[CatalogTrack]


@router.get("/home", response_model=HomeResponse)
async def home(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(30, ge=5, le=50),
) -> HomeResponse:
    """Everything the home screen needs in one round trip.

    Three separate calls from a cold launch is what made the screen feel slow;
    the server can fan these out in parallel instead.
    """
    wave = await personal_wave(user=user, session=session, limit=limit, exclude_recent=True)

    genre = random.choice(DISCOVERY_GENRES)
    for_you = [
        track
        for track in (normalise_track(raw) for raw in await soundcloud.genre_tracks(genre, limit=limit))
        if track
    ]

    top = [
        track
        for track in (normalise_track(raw) for raw in await soundcloud.charts(limit=limit))
        if track
    ]

    return HomeResponse(wave=wave.tracks, for_you=for_you, charts=top)
