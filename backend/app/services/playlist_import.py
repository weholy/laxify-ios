"""Reading a playlist out of somebody else's service.

Every source is asked the same question — "what tracks are on this page?" —
and answers with the only two fields that matter for matching: a title and an
artist. What happens next is identical whatever the source was: each pair is
looked up in our catalogue, the ones we can actually play are kept, and the
rest are quietly left out. A playlist that half-imports is far more useful
than an error, provided the app says how many arrived.

Two sources answer properly, because they have real APIs behind them:
Spotify (via the metadata client already used for search) and SoundCloud
(which is our catalogue anyway, so its playlists import exactly).

The rest — Yandex, VK, Apple, YouTube — are read off their public pages.
That works when the page ships its track list as structured data and does not
when it hides it behind a login or builds it in the browser. Yandex is the
awkward one: it refuses non-Russian addresses outright, and this server is in
Frankfurt, so it will usually fail. Callers get told which case they hit
rather than being handed an empty playlist.
"""

from __future__ import annotations

import json
import re

import httpx
from starlette.concurrency import run_in_threadpool

from app.services import spotify_meta
from app.services.soundcloud import SoundCloudError, soundcloud


class ImportError_(Exception):
    """Something the person pasting the link needs to be told."""

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail


SPOTIFY = re.compile(r"open\.spotify\.com/(?:intl-\w+/)?playlist/([A-Za-z0-9]+)")
SOUNDCLOUD = re.compile(r"soundcloud\.com/[^/\s]+/sets/[^/\s?]+")
YANDEX = re.compile(r"music\.yandex\.[a-z]+/")
VK = re.compile(r"vk\.com/|vk\.ru/")

_UA = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/126 Safari/537.36"
    ),
    "Accept-Language": "ru,en;q=0.8",
}


def platform(url: str) -> str:
    if SPOTIFY.search(url):
        return "spotify"
    if SOUNDCLOUD.search(url):
        return "soundcloud"
    if YANDEX.search(url):
        return "yandex"
    if VK.search(url):
        return "vk"
    if "music.apple.com" in url:
        return "apple"
    if "youtube.com" in url or "youtu.be" in url:
        return "youtube"
    return "unknown"


# ─────────────────────────────────────────────────────────────────────────────
# Per-source readers. Each returns [{"title": …, "artist": …, "spotify_id": …}]
# ─────────────────────────────────────────────────────────────────────────────


async def _from_spotify(url: str) -> tuple[str, list[dict]]:
    """Read straight off the client rather than through `spotify_meta.playlist`.

    A playlist's items are `PlaylistTrack` wrappers, not `Track`s — the track
    hangs off `.track` — and the shared helper assumes the latter, so it threw
    on `artists` and the caller only ever saw "не отдал этот плейлист".
    """
    match = SPOTIFY.search(url)
    if not match:
        raise ImportError_("Это не ссылка на плейлист Spotify")

    client = spotify_meta._get_client()
    if client is None:
        raise ImportError_("Разбор Spotify сейчас недоступен")

    def _read():
        playlist = client.get_playlist(url)
        items = getattr(playlist, "tracks", None) or []

        found = []
        for item in items:
            # A PlaylistTrack wraps the track; a bare Track is its own.
            track = getattr(item, "track", None) or item
            name = getattr(track, "name", None)
            if not name:
                continue

            artists = getattr(track, "artists", None) or []
            artist = ""
            if artists:
                artist = getattr(artists[0], "name", "") or ""

            found.append(
                {"title": str(name), "artist": str(artist), "spotify_id": getattr(track, "id", None)}
            )

        return str(getattr(playlist, "name", "") or ""), found

    try:
        return await run_in_threadpool(_read)
    except Exception as error:  # noqa: BLE001 — any failure here is one message
        raise ImportError_("Spotify не отдал этот плейлист. Он точно открытый?") from error


async def _from_soundcloud(url: str) -> tuple[str, list[dict]]:
    try:
        data = await soundcloud.resolve(url)
    except SoundCloudError as error:
        raise ImportError_("SoundCloud не отдал этот плейлист") from error

    if data.get("kind") not in ("playlist", "system-playlist"):
        raise ImportError_("По этой ссылке не плейлист")

    tracks = []
    for raw in data.get("tracks") or []:
        title = raw.get("title")
        if not title:
            continue
        user = raw.get("user") or {}
        tracks.append(
            {
                "title": title,
                "artist": (raw.get("publisher_metadata") or {}).get("artist")
                or user.get("username")
                or "",
                # Already ours: no matching needed at all.
                "sc_track_id": str(raw["id"]) if raw.get("id") else None,
            }
        )
    return data.get("title") or "", tracks


_JSON_LD = re.compile(
    r'<script[^>]+type="application/ld\+json"[^>]*>(.*?)</script>', re.S | re.I
)


async def _from_public_page(url: str, source: str) -> tuple[str, list[dict]]:
    """Best effort for the services that have no API we can call.

    Reads the structured data a page publishes for search engines. When a page
    ships none — because it needs a login, or builds its list in the browser —
    this finds nothing, and saying so is the honest outcome.
    """
    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True, headers=_UA) as client:
            response = await client.get(url)
    except httpx.HTTPError as error:
        raise ImportError_(f"Не удалось открыть ссылку ({source})") from error

    if response.status_code == 403 and source == "yandex":
        raise ImportError_(
            "Яндекс.Музыка не пускает наш сервер — он за пределами России. "
            "Импорт оттуда пока невозможен"
        )
    if response.status_code >= 400:
        raise ImportError_(f"Страница ответила ошибкой {response.status_code}")

    title = ""
    tracks: list[dict] = []

    for blob in _JSON_LD.findall(response.text):
        try:
            data = json.loads(blob)
        except ValueError:
            continue

        for node in data if isinstance(data, list) else [data]:
            if not isinstance(node, dict):
                continue
            title = title or str(node.get("name") or "")

            items = node.get("track") or node.get("tracks") or []
            if isinstance(items, dict):
                items = items.get("itemListElement") or []

            for item in items:
                entry = item.get("item") if isinstance(item, dict) and "item" in item else item
                if not isinstance(entry, dict):
                    continue

                name = entry.get("name")
                if not name:
                    continue

                performer = entry.get("byArtist")
                if isinstance(performer, list):
                    performer = performer[0] if performer else None
                artist = ""
                if isinstance(performer, dict):
                    artist = str(performer.get("name") or "")
                elif isinstance(performer, str):
                    artist = performer

                tracks.append({"title": str(name), "artist": artist})

    if not tracks:
        raise ImportError_(
            "На этой странице не видно списка треков. "
            "Такое бывает, когда плейлист закрыт или площадка прячет его за входом"
        )

    return title, tracks


async def read(url: str) -> tuple[str, list[dict], str]:
    """`(playlist title, tracks, platform)` for a pasted link."""
    url = url.strip()
    if not url.lower().startswith(("http://", "https://")):
        raise ImportError_("Это не похоже на ссылку")

    source = platform(url)

    if source == "spotify":
        title, tracks = await _from_spotify(url)
    elif source == "soundcloud":
        title, tracks = await _from_soundcloud(url)
    elif source == "unknown":
        raise ImportError_("Эта площадка пока не поддерживается")
    else:
        title, tracks = await _from_public_page(url, source)

    if not tracks:
        raise ImportError_("В этом плейлисте не нашлось ни одного трека")

    return title, tracks, source
