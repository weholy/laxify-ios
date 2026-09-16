"""Audio held on disk, so a track is fetched from the source once.

A player does not download a track in one go. It asks for a few kilobytes,
reads the headers, then asks for more — half a dozen ranged requests before
any sound comes out, and more as it plays. Proxying each of those straight
through meant a fresh connection to the media host every time, and the
handshakes alone accounted for most of the wait before playback started.

So the first request fetches the whole file once and keeps it. Every request
after that — including all the ranges the player asks for while listening —
is a local read.
"""

import asyncio
import contextlib
import logging
import time
from pathlib import Path

import httpx

logger = logging.getLogger("laxify.audio")

CACHE_DIR = Path("/var/cache/laxify/audio")
# A few hundred tracks at typical sizes. Small enough to leave the disk alone
# on a box that also runs other things.
MAX_BYTES = 600 * 1024 * 1024
# Nothing useful is this big; a run-away response should not fill the disk.
MAX_TRACK_BYTES = 40 * 1024 * 1024

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"
)

# One pooled client for every fetch: connections to the media host are reused
# rather than negotiated again per track.
_client: httpx.AsyncClient | None = None
_locks: dict[str, asyncio.Lock] = {}


def _http() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            timeout=httpx.Timeout(30, read=60),
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
            limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
        )
    return _client


def _path(track_id: str) -> Path:
    return CACHE_DIR / f"{track_id}.mp3"


def cached_path(track_id: str) -> Path | None:
    """The file for a track, if it is already here."""
    path = _path(track_id)
    if path.exists() and path.stat().st_size > 0:
        # Touch it so the sweep below treats it as recently wanted.
        with contextlib.suppress(OSError):
            path.touch()
        return path
    return None


async def ensure(track_id: str, source_url: str) -> Path | None:
    """Fetches the track if it is not here yet, and returns the file.

    Concurrent requests for the same track wait on one download rather than
    starting several — which is exactly what a player's opening burst of
    range requests would otherwise do.
    """
    if (path := cached_path(track_id)) is not None:
        return path

    lock = _locks.setdefault(track_id, asyncio.Lock())

    async with lock:
        if (path := cached_path(track_id)) is not None:
            return path

        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        target = _path(track_id)
        partial = target.with_suffix(".part")

        started = time.monotonic()
        written = 0

        try:
            async with _http().stream("GET", source_url) as response:
                if response.status_code >= 400:
                    logger.warning("Источник отдал %s для %s", response.status_code, track_id)
                    return None

                with partial.open("wb") as handle:
                    async for chunk in response.aiter_bytes(chunk_size=256 * 1024):
                        handle.write(chunk)
                        written += len(chunk)

                        if written > MAX_TRACK_BYTES:
                            logger.warning("Трек %s слишком большой, обрываю", track_id)
                            raise ValueError("too large")

            # Renamed only once complete, so a half-written file is never
            # mistaken for a cached one.
            partial.replace(target)

            elapsed = time.monotonic() - started
            logger.info(
                "Трек %s загружен: %.1f МБ за %.2f с", track_id, written / 1_048_576, elapsed
            )

            await asyncio.to_thread(_sweep)
            return target

        except Exception as exc:
            logger.warning("Не удалось загрузить %s: %s", track_id, exc)
            with contextlib.suppress(OSError):
                partial.unlink()
            return None

        finally:
            _locks.pop(track_id, None)


def _sweep() -> None:
    """Drops the least recently wanted files once the cache is too big."""
    try:
        files = sorted(
            (
                path
                for pattern in ("*.mp3", "*.rescued.m4a")
                for path in CACHE_DIR.glob(pattern)
                if path.is_file()
            ),
            key=lambda path: path.stat().st_atime,
        )
    except OSError:
        return

    total = sum(path.stat().st_size for path in files)
    if total <= MAX_BYTES:
        return

    for path in files:
        if total <= MAX_BYTES * 0.8:
            break
        try:
            size = path.stat().st_size
            path.unlink()
            total -= size
        except OSError:
            continue

    logger.info("Кеш аудио подчищен до %.0f МБ", total / 1_048_576)
