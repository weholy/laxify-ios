"""Whether a track can actually be played.

Metadata answers this in one direction only. ``policy: BLOCK``, an empty
transcoding list, ``streamable: false`` — each is proof the track will not
play, free and immediate. Their absence proves nothing: a track that
advertises a `progressive` stream can still return 404 for it, and that costs
a request to find out. So both are used, and the request's answer is cached.

The harder half is that neither is decided where it matters. SoundCloud
answers by region, and this server sits in Frankfurt while the listening
happens elsewhere — a track it resolves without trouble arrives at the phone
as BLOCK with nothing to play. So phones report what they actually found, and
those reports outrank anything decided here.

Without all this, listings were full of tracks that looked fine until someone
pressed play. Dropping them before they are ever shown is the difference
between a feed that works and one that mostly does.
"""

import asyncio
import logging
import time

from sqlalchemy import func

from app.services.soundcloud import soundcloud

logger = logging.getLogger("laxify.playability")

# Long enough to be worth having, short enough that a track which becomes
# available again is not written off for good.
TTL_SECONDS = 6 * 60 * 60
MAX_ENTRIES = 20_000
# Deliberately low: this runs in the background where nothing is waiting,
# and going faster is what got us throttled.
CONCURRENCY = 6

_verdicts: dict[str, tuple[bool, float]] = {}
_background: asyncio.Task | None = None


def _remember(track_id: str, playable: bool) -> None:
    if len(_verdicts) >= MAX_ENTRIES:
        # Drop the oldest quarter rather than one entry at a time, so this
        # runs rarely instead of on nearly every insert.
        oldest = sorted(_verdicts.items(), key=lambda item: item[1][1])
        for key, _ in oldest[: MAX_ENTRIES // 4]:
            _verdicts.pop(key, None)

    _verdicts[track_id] = (playable, time.monotonic())


def _recall(track_id: str) -> bool | None:
    entry = _verdicts.get(track_id)
    if entry is None:
        return None

    playable, stored_at = entry
    if time.monotonic() - stored_at > TTL_SECONDS:
        _verdicts.pop(track_id, None)
        return None

    return playable


async def filter_playable(tracks: list[dict], limit: int) -> list[dict]:
    """Returns up to `limit` tracks, dropping ones already known to be dead.

    This never blocks on an unknown track. Verifying on demand meant a home
    screen waited on dozens of stream lookups — slow enough to hit the app's
    own timeout, and enough traffic that the source started throttling us,
    which made it slower still.

    So the request pays nothing: known-dead tracks are dropped, everything
    else is served, and the app skips anything that turns out not to play. A
    background pass fills the cache in, so the feed gets cleaner on its own.
    """
    if not tracks:
        return []

    # What phones have reported outranks anything decided here — see
    # `report_unplayable`. Loaded once per call and merged into memory so the
    # rest of this stays a dictionary lookup.
    await _load_reported_dead()

    kept = [
        track
        for track in tracks
        if _recall(str(track.get("id"))) is not False and not _looks_blocked(track)
    ]

    unverified = [
        track for track in kept[: limit * 2] if _recall(str(track.get("id"))) is None
    ]
    if unverified:
        _schedule_verification(unverified)

    return kept[:limit]


def _looks_blocked(track: dict) -> bool:
    """Rejects what the metadata already gives away, for free.

    The note at the top of this file used to say metadata tells you nothing.
    That is not quite right: a track carrying ``policy: BLOCK``, or one whose
    transcoding list is empty, never plays for anyone who sees it that way —
    no request needed. It is only the *absence* of those signs that proves
    nothing, because the same track can carry them for one country and not
    another. Cheap and certain here; the uncertain half is what phones report.
    """
    if track.get("policy") == "BLOCK" or track.get("streamable") is False:
        return True

    media = track.get("media")
    if isinstance(media, dict) and media.get("transcodings") == []:
        return True

    return False


def _schedule_verification(tracks: list[dict]) -> None:
    """Checks tracks after the response has gone out.

    Nobody is waiting on this, so it can be slow and gentle — and by the next
    time these tracks come round, the verdicts are already known.
    """
    global _background

    if _background is not None and not _background.done():
        return

    async def run() -> None:
        semaphore = asyncio.Semaphore(CONCURRENCY)

        async def check(track: dict) -> None:
            async with semaphore:
                try:
                    playable = await soundcloud.is_playable(track)
                except Exception:
                    return
                _remember(str(track.get("id")), playable)

        await asyncio.gather(*(check(track) for track in tracks), return_exceptions=True)
        logger.info("Фоновая проверка: %s треков", len(tracks))

    _background = asyncio.create_task(run())


# --- What the phones found out -------------------------------------------

# Reports are read in bulk rather than per track, and only once in a while:
# the set only grows, and a few minutes of staleness costs nothing.
_reported_dead: set[str] = set()
_reported_loaded_at: float = 0.0
RELOAD_SECONDS = 300


async def _load_reported_dead() -> None:
    global _reported_loaded_at

    if _reported_dead and time.monotonic() - _reported_loaded_at < RELOAD_SECONDS:
        return

    from sqlalchemy import select

    from app.db.session import SessionLocal
    from app.models.playability import TrackPlayability

    try:
        async with SessionLocal() as session:
            rows = await session.scalars(
                select(TrackPlayability.track_id).where(
                    TrackPlayability.playable.is_(False),
                    TrackPlayability.source == "client",
                )
            )
            _reported_dead.clear()
            _reported_dead.update(rows.all())
    except Exception:  # noqa: BLE001 — a feed without this is merely worse
        logger.exception("Не удалось прочитать отчёты о неиграбельных треках")
        return

    _reported_loaded_at = time.monotonic()

    for track_id in _reported_dead:
        _remember(track_id, False)


async def report_unplayable(
    session, track_ids: list[str], *, reason: str | None = None, region: str = "??"
) -> int:
    """Records that a phone could not play these tracks.

    Trusted over the server's own check without argument. The server can only
    ever answer "it plays from here", and here is not where anyone listens.
    """
    if not track_ids:
        return 0

    from sqlalchemy.dialects.postgresql import insert

    from app.models.playability import TrackPlayability

    rows = [
        {
            "track_id": track_id,
            "region": region,
            "playable": False,
            "source": "client",
            "reason": (reason or "")[:64] or None,
        }
        for track_id in dict.fromkeys(track_ids)
        if track_id
    ]

    statement = insert(TrackPlayability).values(rows)
    await session.execute(
        statement.on_conflict_do_update(
            index_elements=["track_id", "region"],
            set_={
                "playable": False,
                "source": "client",
                "reason": statement.excluded.reason,
                "reports": TrackPlayability.reports + 1,
                "checked_at": func.now(),
            },
        )
    )
    await session.commit()

    # Effective immediately for this process, rather than at the next reload.
    for row in rows:
        _reported_dead.add(row["track_id"])
        _remember(row["track_id"], False)

    return len(rows)
