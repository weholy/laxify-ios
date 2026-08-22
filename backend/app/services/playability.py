"""Whether a track can actually be played.

Nothing a track carries in its metadata says this — policy, monetisation and
the streamable flag read identically for a track that plays and one that
returns 404 for every variant it advertises. The only reliable answer costs a
request, so answers are cached and reused.

Without this, listings were full of tracks that looked fine until someone
pressed play. Dropping them before they are ever shown is the difference
between a feed that works and one that mostly does.
"""

import asyncio
import logging
import time

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

    kept = [track for track in tracks if _recall(str(track.get("id"))) is not False]

    unverified = [
        track for track in kept[: limit * 2] if _recall(str(track.get("id"))) is None
    ]
    if unverified:
        _schedule_verification(unverified)

    return kept[:limit]


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
