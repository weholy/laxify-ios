"""YouTube Music as a catalogue and as a source of audio.

Two halves, and they fail for different reasons, so they are kept apart.

The catalogue half talks to the same private endpoint the web player uses,
through `ytmusicapi`. Nothing is signed in — search, charts, artists, albums
and playlists are all public — so there is no account to lose and no token to
rotate.

The audio half is the awkward one. A media url from this source is issued
*for the address that asked for it*: the link this server resolves names this
server's ip inside it and is refused anywhere else. So unlike SoundCloud,
where the phone resolves its own link and streams directly, here the bytes
have to come through us. That is a real cost — every minute of listening
crosses this machine — and it is why the resolved url is cached until close
to its own expiry rather than fetched per play.

Resolution runs as a short-lived subprocess rather than in this process. The
extractor is heavy, allocates freely, and this service runs under a hard
memory cap alongside other people's bots; a process that exits gives every
byte back, and one that lives in here would not.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

logger = logging.getLogger("laxify.ytmusic")

# Searching from the country the listener is actually in returns nothing for
# the "songs" filter — measured: `location="RU"` gives 0 songs for a query
# that returns 20 from anywhere else, while the unfiltered search returns 33.
# The catalogue itself is the same and Russian-language tracks come back
# either way, so the request is made from where this server sits.
_LOCATION = "DE"
_LANGUAGE = "en"

_client: Any = None
_client_lock = asyncio.Lock()

# The resolved url carries its own expiry, about six hours out. Held for four,
# so a link handed to a phone still has plenty of life left in it.
_STREAM_TTL = 4 * 3600
_streams: dict[str, tuple[str, float]] = {}
_stream_locks: dict[str, asyncio.Lock] = {}

# Catalogue answers, so scrolling back to a screen costs nothing.
_CATALOGUE_TTL = 30 * 60
_catalogue: dict[str, tuple[Any, float]] = {}


class YTMusicError(RuntimeError):
    """The source could not answer."""


# --- The client -----------------------------------------------------------


async def _api() -> Any:
    """The catalogue client, built once.

    Construction reaches out to fetch the endpoint's current configuration,
    so it is done under a lock — twenty screens opening at once should cost
    one handshake, not twenty.
    """
    global _client
    if _client is not None:
        return _client

    async with _client_lock:
        if _client is not None:
            return _client
        try:
            from ytmusicapi import YTMusic
        except ImportError as exc:  # pragma: no cover - deployment guard
            raise YTMusicError("ytmusicapi не установлен") from exc

        _client = await asyncio.to_thread(YTMusic, language=_LANGUAGE, location=_LOCATION)
        return _client


async def _call(key: str, fn, *args, **kwargs) -> Any:
    """Runs one blocking catalogue call, with its answer remembered."""
    cached = _catalogue.get(key)
    if cached is not None and time.monotonic() - cached[1] < _CATALOGUE_TTL:
        return cached[0]

    api = await _api()
    try:
        result = await asyncio.to_thread(getattr(api, fn), *args, **kwargs)
    except Exception as exc:  # noqa: BLE001 — the library raises bare exceptions
        logger.warning("ytmusic: %s не ответил — %s", fn, exc)
        raise YTMusicError(str(exc)) from exc

    if len(_catalogue) > 500:
        _catalogue.clear()
    _catalogue[key] = (result, time.monotonic())
    return result


# --- Shapes ---------------------------------------------------------------


def _thumbnail(item: dict, want: int = 544) -> str | None:
    """The smallest picture that is still at least `want` wide."""
    thumbs = item.get("thumbnails") or []
    if not thumbs:
        return None

    big_enough = [t for t in thumbs if (t.get("width") or 0) >= want]
    chosen = min(big_enough, key=lambda t: t["width"]) if big_enough else thumbs[-1]
    return chosen.get("url")


def _seconds(item: dict) -> float:
    if isinstance(item.get("duration_seconds"), int):
        return float(item["duration_seconds"])

    text = item.get("duration") or ""
    parts = [p for p in text.split(":") if p.strip().isdigit()]
    if not parts:
        return 0.0

    total = 0
    for part in parts:
        total = total * 60 + int(part)
    return float(total)


def _artists(item: dict) -> tuple[str | None, str]:
    """The first credited artist's id, and every name joined."""
    credits = [a for a in (item.get("artists") or []) if a.get("name")]
    if not credits:
        return None, "Неизвестный исполнитель"

    first = credits[0].get("id")
    return (
        f"yt:{first}" if first else None,
        ", ".join(a["name"] for a in credits),
    )


def track(item: dict) -> dict | None:
    """One song, in the shape the app already decodes.

    Ids carry their source. Nothing above this cares which catalogue a track
    came from, but everything the app files by id — favourites, plays,
    downloads — would collide between sources without it.
    """
    video = item.get("videoId")
    if not video or not item.get("title"):
        return None

    artist_id, artist_name = _artists(item)
    album = item.get("album") or {}

    return {
        "id": f"yt:{video}",
        "title": item["title"],
        "artistId": artist_id,
        "artistName": artist_name,
        "artworkUrl": _thumbnail(item),
        "durationSeconds": _seconds(item),
        "permalink": f"https://music.youtube.com/watch?v={video}",
        "genre": None,
        "playbackCount": None,
        "playable": True,
        "albumTitle": album.get("name") if isinstance(album, dict) else None,
    }


def artist(item: dict) -> dict | None:
    browse = item.get("browseId") or item.get("channelId")
    name = item.get("artist") or item.get("name") or item.get("title")
    if not browse or not name:
        return None

    return {
        "id": f"yt:{browse}",
        "name": name,
        "avatarUrl": _thumbnail(item),
        "followers": _subscribers(item),
        "description": item.get("description"),
        "trackCount": None,
        "isVerified": False,
    }


def _subscribers(item: dict) -> int | None:
    """"1.2M subscribers" as a number, when it is one."""
    text = (item.get("subscribers") or "").strip().upper()
    if not text:
        return None

    scale = {"K": 1_000, "M": 1_000_000, "B": 1_000_000_000}
    suffix = text[-1]
    try:
        if suffix in scale:
            return int(float(text[:-1].replace(",", ".")) * scale[suffix])
        return int(text.replace(",", "").replace(" ", ""))
    except ValueError:
        return None


def album(item: dict) -> dict | None:
    browse = item.get("browseId") or item.get("audioPlaylistId") or item.get("playlistId")
    title = item.get("title")
    if not browse or not title:
        return None

    _, artist_name = _artists(item)
    return {
        "id": f"yt:{browse}",
        "title": title,
        "ownerName": artist_name,
        "artworkUrl": _thumbnail(item),
        "trackCount": item.get("trackCount"),
        "year": str(item["year"]) if item.get("year") else None,
    }


# --- Catalogue ------------------------------------------------------------


async def search(query: str, limit: int = 30) -> dict:
    songs, artists, albums = await asyncio.gather(
        _call(f"s:t:{query}:{limit}", "search", query, filter="songs", limit=limit),
        _call(f"s:a:{query}", "search", query, filter="artists", limit=8),
        _call(f"s:l:{query}", "search", query, filter="albums", limit=12),
        return_exceptions=True,
    )

    def kept(value: Any) -> list:
        return value if isinstance(value, list) else []

    return {
        "tracks": [t for t in map(track, kept(songs)) if t],
        "artists": [a for a in map(artist, kept(artists)) if a],
        "albums": [a for a in map(album, kept(albums)) if a],
        "playlists": [],
    }


async def search_tracks(query: str, limit: int = 30, offset: int = 0) -> list[dict]:
    found = await _call(
        f"s:t:{query}:{limit + offset}", "search", query, filter="songs", limit=limit + offset
    )
    return [t for t in map(track, found[offset : offset + limit]) if t]


async def suggestions(query: str) -> list[str]:
    found = await _call(f"sug:{query}", "get_search_suggestions", query)
    return [s for s in found if isinstance(s, str)][:10]


async def artist_detail(artist_id: str) -> dict:
    data = await _call(f"ar:{artist_id}", "get_artist", artist_id)

    profile = artist({**data, "browseId": artist_id, "name": data.get("name")})
    if profile is None:
        raise YTMusicError("исполнитель не найден")

    songs = (data.get("songs") or {}).get("results") or []
    releases = (data.get("albums") or {}).get("results") or []
    singles = (data.get("singles") or {}).get("results") or []
    related = (data.get("related") or {}).get("results") or []

    return {
        "artist": profile,
        "topTracks": [t for t in map(track, songs) if t][:20],
        "releases": [a for a in map(album, releases + singles) if a][:30],
        "similarArtists": [a for a in map(artist, related) if a][:12],
    }


async def artist_tracks(artist_id: str, limit: int = 50, offset: int = 0) -> list[dict]:
    """Everything the artist has, not only the handful the profile shows.

    The profile carries five songs and a link to the rest; this follows the
    link. When there is none — a small artist whose whole catalogue fits on
    the profile — those five are the answer.
    """
    data = await _call(f"ar:{artist_id}", "get_artist", artist_id)
    section = data.get("songs") or {}

    pool: list[dict] = []
    if browse := section.get("browseId"):
        listing = await _call(f"pl:{browse}", "get_playlist", browse, 400)
        pool = listing.get("tracks") or []
    else:
        pool = section.get("results") or []

    return [t for t in map(track, pool[offset : offset + limit]) if t]


async def album_detail(album_id: str) -> dict:
    data = await _call(f"al:{album_id}", "get_album", album_id)

    shell = album({**data, "browseId": album_id})
    if shell is None:
        raise YTMusicError("альбом не найден")

    tracks = []
    for item in data.get("tracks") or []:
        # An album's track list omits the artwork and, often, the artist —
        # both belong to the album, so they are filled in from it.
        merged = {**item}
        merged.setdefault("thumbnails", data.get("thumbnails"))
        if not merged.get("artists"):
            merged["artists"] = data.get("artists")
        if mapped := track(merged):
            tracks.append(mapped)

    return {"album": shell, "tracks": tracks}


async def playlist_tracks(playlist_id: str) -> dict:
    data = await _call(f"pl:{playlist_id}", "get_playlist", playlist_id, 200)
    return {
        "title": data.get("title") or "Подборка",
        "tracks": [t for t in map(track, data.get("tracks") or []) if t],
    }


async def charts(limit: int = 30) -> list[dict]:
    """What is being listened to. Falls back to the home feed.

    The charts endpoint answers with a different set of sections depending on
    where it is asked from, and for some regions there are no songs in it at
    all — so an empty answer here is ordinary, not an error.
    """
    try:
        data = await _call("charts", "get_charts", "ZZ")
    except YTMusicError:
        data = {}

    rows = (data.get("songs") or {}).get("items") or data.get("videos", {}).get("items") or []
    mapped = [t for t in map(track, rows) if t]
    if mapped:
        return mapped[:limit]

    return await home_tracks(limit)


async def home_tracks(limit: int = 30) -> list[dict]:
    data = await _call("home", "get_home", 12)
    out: list[dict] = []
    seen: set[str] = set()

    for section in data if isinstance(data, list) else []:
        for item in section.get("contents") or []:
            if not isinstance(item, dict):
                continue
            mapped = track(item)
            if mapped and mapped["id"] not in seen:
                seen.add(mapped["id"])
                out.append(mapped)
            if len(out) >= limit:
                return out

    return out


async def home() -> dict:
    """The rows the home screen shows, with their tracks."""
    data = await _call("home", "get_home", 12)

    rows: list[dict] = []
    for section in data if isinstance(data, list) else []:
        tracks = [t for t in map(track, section.get("contents") or []) if t]
        if len(tracks) < 4:
            continue
        rows.append({"title": section.get("title") or "Подборка", "tracks": tracks[:24]})
        if len(rows) >= 6:
            break

    return {"rows": rows}


# --- Audio ----------------------------------------------------------------


async def stream_url(video_id: str) -> str:
    """A playable url for one track.

    Bound to this server's address, so whatever comes back must be relayed
    from here rather than handed to the phone.
    """
    hit = _streams.get(video_id)
    if hit is not None and time.monotonic() - hit[1] < _STREAM_TTL:
        return hit[0]

    lock = _stream_locks.setdefault(video_id, asyncio.Lock())
    async with lock:
        # Another caller may have resolved it while this one waited.
        hit = _streams.get(video_id)
        if hit is not None and time.monotonic() - hit[1] < _STREAM_TTL:
            return hit[0]

        url = await _resolve(video_id)

        if len(_streams) > 2000:
            _streams.clear()
        _streams[video_id] = (url, time.monotonic())
        _stream_locks.pop(video_id, None)
        return url


async def _resolve(video_id: str) -> str:
    """Asks the extractor, in a process of its own.

    Out of process on purpose: the extractor is not small, this service runs
    under a hard memory cap next to other things that must not be pushed out
    of memory, and a process that has exited is guaranteed to have given
    everything back.
    """
    from app.core.config import settings

    binary = settings.ytdlp_path or "yt-dlp"
    started = time.monotonic()

    try:
        process = await asyncio.create_subprocess_exec(
            binary,
            "--quiet",
            "--no-warnings",
            "--no-playlist",
            "--socket-timeout",
            "15",
            "--extractor-args",
            # The web client is the one that answers a plain datacentre
            # address without demanding a sign-in.
            "youtube:player_client=web_music,web",
            "-f",
            "bestaudio[ext=m4a]/bestaudio/best",
            "--print",
            "%(url)s",
            f"https://music.youtube.com/watch?v={video_id}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise YTMusicError("извлекатель не установлен") from exc

    try:
        out, err = await asyncio.wait_for(process.communicate(), timeout=45)
    except TimeoutError as exc:
        process.kill()
        raise YTMusicError("извлекатель не ответил вовремя") from exc

    url = out.decode().strip().splitlines()
    if process.returncode != 0 or not url or not url[0].startswith("http"):
        detail = err.decode().strip()[:200]
        logger.warning("ytmusic: не удалось открыть %s — %s", video_id, detail)
        raise YTMusicError(detail or "поток не открылся")

    logger.info(
        "ytmusic: ссылка получена за %d мс", int((time.monotonic() - started) * 1000)
    )
    return url[0]


def forget_stream(video_id: str) -> None:
    """Drops a cached url that turned out not to work any more."""
    _streams.pop(video_id, None)


async def probe() -> dict:
    """For the diagnostics screen: is either half of this working?"""
    report: dict[str, Any] = {"catalogue": False, "audio": False}

    try:
        found = await search_tracks("test", limit=1)
        report["catalogue"] = bool(found)
    except Exception as exc:  # noqa: BLE001
        report["catalogueError"] = str(exc)[:200]

    try:
        # A video that has been up for a decade and is not going anywhere.
        await stream_url("kJQP7kiw5Fk")
        report["audio"] = True
    except Exception as exc:  # noqa: BLE001
        report["audioError"] = str(exc)[:200]

    return report
