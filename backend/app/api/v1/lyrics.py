"""Song lyrics, looked up once and kept.

The result of a lookup is cached whether or not anything was found — a track
nobody has words for is otherwise searched for again on every play, by every
listener, forever. Misses expire sooner than hits, since a song can gain
lyrics later but rarely loses them.
"""

from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, Query
from pydantic import BaseModel
from sqlalchemy import select

from app.api.deps import CurrentUser, SessionDep
from app.models import LyricsCache
from app.services import lyrics as lyrics_service

router = APIRouter(prefix="/lyrics", tags=["lyrics"])

HIT_TTL = timedelta(days=60)
MISS_TTL = timedelta(days=3)


class LyricLineOut(BaseModel):
    timestamp: float
    text: str


class LyricsOut(BaseModel):
    found: bool
    source: str | None = None
    # Set when the words are timed, which is what lets them follow the vocal.
    synced: list[LyricLineOut] = []
    plain: str | None = None

    @property
    def is_synced(self) -> bool:
        return len(self.synced) > 1


@router.get("/{track_id}", response_model=LyricsOut)
async def lyrics(
    track_id: str,
    user: CurrentUser,
    session: SessionDep,
    title: str = Query(min_length=1, max_length=300),
    artist: str = Query(default="", max_length=300),
    duration: float = Query(default=0, ge=0, le=7200),
) -> LyricsOut:
    now = datetime.now(UTC)

    cached = await session.get(LyricsCache, track_id)
    if cached is not None:
        age = now - cached.updated_at
        fresh = age < (HIT_TTL if cached.found else MISS_TTL)
        if fresh:
            return _from_cache(cached)

    found = await lyrics_service.finder.find(
        title=title, artist=artist, duration=duration or None
    )

    payload = LyricsOut(
        found=found is not None,
        source=found.source if found else None,
        synced=[
            LyricLineOut(timestamp=line.timestamp, text=line.text)
            for line in (found.synced if found else [])
        ],
        plain=found.plain if found else None,
    )

    await _store(session, track_id, title, artist, payload, now)
    return payload


def _from_cache(row: LyricsCache) -> LyricsOut:
    return LyricsOut(
        found=row.found,
        source=row.source,
        synced=[
            LyricLineOut(timestamp=line["timestamp"], text=line["text"])
            for line in (row.synced or [])
        ],
        plain=row.plain,
    )


async def _store(
    session, track_id: str, title: str, artist: str, payload: LyricsOut, now: datetime
) -> None:
    row = await session.get(LyricsCache, track_id)

    if row is None:
        row = LyricsCache(track_id=track_id)
        session.add(row)

    row.title = title[:300]
    row.artist_name = artist[:300]
    row.found = payload.found
    row.source = payload.source
    row.plain = payload.plain
    row.synced = [{"timestamp": line.timestamp, "text": line.text} for line in payload.synced]
    row.updated_at = now

    await session.commit()


class LyricsStats(BaseModel):
    total: int
    with_lyrics: int
    synced: int


@router.get("", response_model=LyricsStats)
async def coverage(user: CurrentUser, session: SessionDep) -> LyricsStats:
    """How much of what people play has words, and how much of that is timed.

    Worth knowing before adding another source: it says whether coverage is
    the problem or timings are.
    """
    rows = (await session.scalars(select(LyricsCache))).all()

    return LyricsStats(
        total=len(rows),
        with_lyrics=sum(1 for row in rows if row.found),
        synced=sum(1 for row in rows if row.synced and len(row.synced) > 1),
    )
