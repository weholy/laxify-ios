"""The last resort for a track the source will not play.

Measured on 2026-09-16 against the tracks listeners actually lost: the
catalogue's copy of a song is increasingly served only as encrypted HLS —
`policy: MONETIZE`, every plain variant answering 404, the encrypted ones
needing a licence only the source's own app holds. That refusal is the same
from the phone and from this server, so neither of the two routes the app had
could ever play those tracks. 137 of 159 requests to the audio endpoint over
the fortnight before this existed ended in a 502 for exactly that reason, and
every one of them was a song skipped in front of someone.

So the recording is found somewhere else. YouTube Music carries the official
upload of almost every label release — the same master, usually to the
second — and it answers this server's address. The match is made on title,
artist and length together, never on title alone, because a remix, a sped-up
edit or a live take sits right next to the original in every search.

What is found is downloaded once, rewrapped into an ordinary MP4 (the
source serves a streaming-segmented file, which a player on the phone treats
far less predictably), kept on disk, and served with byte ranges exactly like
any other cached track.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import re
import time
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

from app.services import audio_cache, ytmusic

logger = logging.getLogger("laxify.rescue")

CACHE_DIR = audio_cache.CACHE_DIR
_MAP_FILE = CACHE_DIR / "rescue-map.json"

# How far apart two uploads of one master can be. Label uploads on both sides
# are usually within a second or two; ten covers different trailing silence
# without letting an extended mix or a radio edit through.
_LENGTH_SLACK = 10.0

# Remembered answers, including "nothing found" — asked again after a while,
# because uploads appear.
_MISS_TTL = 6 * 3600
_matches: dict[str, tuple[str | None, float]] = {}
_matches_loaded = False

# The extractor is a separate process and not a small one. Two at a time keeps
# a burst of requests from pushing this machine's other tenants out of memory.
_extractors = asyncio.Semaphore(2)
_locks: dict[str, asyncio.Lock] = {}

# Words that make a candidate a different take of the song, unless the wanted
# title carries the same word.
_VERSION_MARKERS = (
    "remix", "sped up", "speed up", "slowed", "reverb", "nightcore", "cover",
    "karaoke", "instrumental", "acoustic", "live", "8d", "bass boosted",
    "ремикс", "кавер", "ускорен", "замедлен", "минус", "караоке",
)


# --- Identity -------------------------------------------------------------


def _plain(text: str) -> str:
    """Lowercase letters and digits, with the decorations uploaders add."""
    text = unicodedata.normalize("NFKC", text or "").lower()
    text = text.replace("ё", "е")
    # Bracketed asides — "(Official Audio)", "[prod. X]", "(Lost Tapes 2017)" —
    # except credits, which are part of which recording this is.
    text = re.sub(r"[\(\[][^\)\]]*(official|audio|video|lyric|prod|premiere|hd|hq|mp3)[^\)\]]*[\)\]]", " ", text)
    text = re.sub(r"[^\w\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _without_artist(title: str, artist: str) -> str:
    """"Artist - Title" and "Title" are the same song filed two ways."""
    plain_title = _plain(title)
    for name in _artist_names(artist):
        if plain_title.startswith(name + " "):
            return plain_title[len(name) :].strip()
    return plain_title


def _artist_names(artist: str) -> list[str]:
    parts = re.split(r",|&|\bfeat\.?\b|\bft\.?\b|\bx\b|;|/", artist or "", flags=re.IGNORECASE)
    return [p for p in (_plain(part) for part in parts) if p]


def _is_other_version(candidate_title: str, wanted_title: str) -> bool:
    candidate = candidate_title.lower()
    wanted = wanted_title.lower()
    return any(m in candidate and m not in wanted for m in _VERSION_MARKERS)


def _score(candidate: dict, title: str, artist: str, duration: float) -> float:
    """How sure we are this is the same recording. Zero means no."""
    name = candidate.get("title") or ""
    if not name or _is_other_version(name, title):
        return 0.0

    length = ytmusic._seconds(candidate)
    if duration > 0 and length > 0 and abs(length - duration) > _LENGTH_SLACK:
        return 0.0

    wanted_title = _without_artist(title, artist)
    got_title = _without_artist(name, ", ".join(a.get("name", "") for a in candidate.get("artists") or []))
    title_score = SequenceMatcher(None, wanted_title, got_title).ratio()
    if wanted_title and got_title and (wanted_title in got_title or got_title in wanted_title):
        title_score = max(title_score, 0.85)

    wanted_artists = set(_artist_names(artist))
    got_artists = {n for a in candidate.get("artists") or [] for n in _artist_names(a.get("name", ""))}
    if wanted_artists and got_artists:
        overlap = any(
            w == g or w in g or g in w for w in wanted_artists for g in got_artists
        )
        artist_score = 1.0 if overlap else 0.0
    else:
        # Nothing to compare — lean on title and length alone.
        artist_score = 0.5

    length_score = 1.0 if duration <= 0 or length <= 0 else max(0.0, 1 - abs(length - duration) / _LENGTH_SLACK)

    # Title and artist both have to agree; length breaks ties and confirms.
    if title_score < 0.6 or artist_score == 0.0:
        return 0.0
    return title_score * 0.5 + artist_score * 0.3 + length_score * 0.2


async def find(title: str, artist: str, duration: float) -> str | None:
    """The YouTube Music id of the same recording, if there is one."""
    queries = []
    wanted = _without_artist(title, artist)
    if artist:
        queries.append(f"{artist} {wanted}")
    queries.append(title)

    best: tuple[float, str] | None = None
    api = await ytmusic._api()

    for query in queries:
        try:
            found = await asyncio.to_thread(api.search, query, filter="songs", limit=10)
        except Exception as exc:  # noqa: BLE001 — the library raises bare exceptions
            logger.warning("rescue: поиск не прошёл (%s): %s", query, exc)
            continue

        for candidate in found or []:
            video = candidate.get("videoId")
            if not video:
                continue
            score = _score(candidate, title, artist, duration)
            if score > 0 and (best is None or score > best[0]):
                best = (score, video)

        if best is not None and best[0] >= 0.8:
            break

    if best is None:
        logger.info("rescue: не нашлось «%s — %s» (%.0f с)", artist, title, duration)
        return None

    logger.info("rescue: «%s — %s» → %s (уверенность %.2f)", artist, title, best[1], best[0])
    return best[1]


# --- Remembering matches --------------------------------------------------


def _load_matches() -> None:
    global _matches_loaded
    if _matches_loaded:
        return
    _matches_loaded = True
    try:
        raw = json.loads(_MAP_FILE.read_text())
        now = time.monotonic()
        for key, video in raw.items():
            if isinstance(video, str):
                _matches[key] = (video, now)
    except (OSError, ValueError):
        pass


def _save_matches() -> None:
    found = {key: video for key, (video, _) in _matches.items() if video}
    with contextlib.suppress(OSError):
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = _MAP_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(found))
        tmp.replace(_MAP_FILE)


async def _match_for(track_id: str, title: str, artist: str, duration: float) -> str | None:
    _load_matches()

    # A match found is good for the track whoever asks again. A match *not*
    # found is only good for the description it was searched with: the same
    # track asked about later with a better title — the app's cleaned one
    # rather than an uploader's — deserves its own search, and filing the miss
    # under the bare id meant it never got one for six hours.
    hit = _matches.get(track_id)
    if hit is not None and hit[0]:
        return hit[0]

    miss_key = f"miss:{track_id}:{_plain(artist)}:{_plain(title)}"
    miss = _matches.get(miss_key)
    if miss is not None and time.monotonic() - miss[1] < _MISS_TTL:
        return None

    video = await find(title, artist, duration)
    if video:
        _matches[track_id] = (video, time.monotonic())
        _save_matches()
    else:
        _matches[miss_key] = (None, time.monotonic())
    return video


# --- Audio ----------------------------------------------------------------


def _path(track_id: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", track_id)
    return CACHE_DIR / f"{safe}.rescued.m4a"


def cached(track_id: str) -> Path | None:
    path = _path(track_id)
    if path.exists() and path.stat().st_size > 0:
        with contextlib.suppress(OSError):
            path.touch()
        return path
    return None


async def audio(track_id: str, title: str, artist: str, duration: float) -> Path | None:
    """A file on disk with this song in it, found wherever it can be found."""
    if (path := cached(track_id)) is not None:
        return path

    if not title:
        return None

    lock = _locks.setdefault(track_id, asyncio.Lock())
    async with lock:
        if (path := cached(track_id)) is not None:
            return path

        try:
            video = await _match_for(track_id, title, artist, duration)
            if not video:
                return None
            return await _download(track_id, video)
        finally:
            _locks.pop(track_id, None)


async def _download(track_id: str, video: str) -> Path | None:
    """Fetches the audio and rewraps it into a plain MP4.

    The extractor does both in one go: it downloads in the chunked way the
    source tolerates without throttling, and with ffmpeg present it corrects
    the segmented container into an ordinary one. Byte-for-byte the same
    audio — nothing is re-encoded.
    """
    from app.core.config import settings

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    target = _path(track_id)
    partial = target.with_suffix(".partial.m4a")
    binary = settings.ytdlp_path or "yt-dlp"

    started = time.monotonic()
    async with _extractors:
        try:
            process = await asyncio.create_subprocess_exec(
                binary,
                "--quiet",
                "--no-warnings",
                "--no-playlist",
                "--no-part",
                "--socket-timeout", "20",
                "--retries", "3",
                "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]",
                "--fixup", "force",
                "-o", str(partial),
                f"https://music.youtube.com/watch?v={video}",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError:
            logger.error("rescue: извлекатель не установлен (%s)", binary)
            return None

        try:
            _, err = await asyncio.wait_for(process.communicate(), timeout=90)
        except TimeoutError:
            process.kill()
            logger.warning("rescue: %s не скачался за 90 с", video)
            with contextlib.suppress(OSError):
                partial.unlink()
            return None

    if process.returncode != 0 or not partial.exists() or partial.stat().st_size < 64 * 1024:
        logger.warning(
            "rescue: %s не скачался: %s", video, err.decode(errors="ignore").strip()[:300]
        )
        with contextlib.suppress(OSError):
            partial.unlink()
        # A cached match that no longer downloads is forgotten, so the next
        # attempt searches again instead of repeating the same failure.
        _matches.pop(track_id, None)
        return None

    # The extractor's own container fix is not guaranteed to have moved the
    # index to the front. A player reading over the network needs it there,
    # or it has to fetch the end of the file before it can start.
    faststart = target.with_suffix(".faststart.m4a")
    remux = await asyncio.create_subprocess_exec(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(partial), "-map", "0:a:0", "-c", "copy",
        "-movflags", "+faststart", "-f", "mp4", str(faststart),
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, remux_err = await remux.communicate()

    with contextlib.suppress(OSError):
        if remux.returncode == 0 and faststart.exists() and faststart.stat().st_size > 64 * 1024:
            faststart.replace(target)
            partial.unlink()
        else:
            logger.warning(
                "rescue: ffmpeg не пересобрал %s: %s", video, remux_err.decode(errors="ignore")[:200]
            )
            faststart.unlink(missing_ok=True)
            partial.replace(target)

    logger.info(
        "rescue: %s готов — %.1f МБ за %.1f с",
        track_id,
        target.stat().st_size / 1_048_576,
        time.monotonic() - started,
    )

    await asyncio.to_thread(audio_cache._sweep)
    return target
