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
# Enough to check a screenful quickly without hammering the source.
CONCURRENCY = 10

_verdicts: dict[str, tuple[bool, float]] = {}


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
    """Returns up to `limit` tracks that will actually play.

    Known-good tracks are taken first and for free. Only the shortfall is
    checked against the source, and only until the limit is met — so a warm
    cache costs nothing and a cold one costs one request per track it needs.
    """
    if not tracks:
        return []

    kept: list[dict] = []
    unknown: list[dict] = []

    for track in tracks:
        verdict = _recall(str(track.get("id")))
        if verdict is True:
            kept.append(track)
        elif verdict is None:
            unknown.append(track)

    if len(kept) >= limit or not unknown:
        return kept[:limit]

    semaphore = asyncio.Semaphore(CONCURRENCY)

    async def check(track: dict) -> tuple[dict, bool]:
        async with semaphore:
            playable = await soundcloud.is_playable(track)
            _remember(str(track.get("id")), playable)
            return track, playable

    # Check a margin beyond the shortfall, since some will come back dead.
    needed = limit - len(kept)
    batch = unknown[: max(needed * 2, needed + 10)]

    results = await asyncio.gather(*(check(track) for track in batch), return_exceptions=True)

    for result in results:
        if isinstance(result, BaseException):
            continue
        track, playable = result
        if playable:
            kept.append(track)

    dead = len(batch) - (len(kept) - (len(tracks) - len(unknown)))
    if dead > 0:
        logger.info("Отброшено недоступных треков: %s из %s", dead, len(batch))

    return kept[:limit]
