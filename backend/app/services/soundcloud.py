"""SoundCloud's internal v2 API.

This is not a documented public API. There is no key to register for — the web
player embeds a client id in its JavaScript bundle, and that id rotates. So the
id is scraped once, cached, and re-scraped whenever a request comes back 401.

Running this server-side rather than in the app matters for two reasons: the
scrape and its cache are shared by every client instead of repeated on each
phone, and requests leave from this host, which SoundCloud serves — so the app
works regardless of what the phone's own connection can reach.
"""

import asyncio
import functools
import logging
import re
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

logger = logging.getLogger("laxify.soundcloud")

API_BASE = "https://api-v2.soundcloud.com"
WEB_BASE = "https://soundcloud.com"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"
)

_CLIENT_ID_PATTERN = re.compile(r'client_id[:=]"([a-zA-Z0-9]{32})"')
_SCRIPT_PATTERN = re.compile(r'src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)"')



def _cached(seconds: int):
    """Caches a listing call for a while.

    Charts, genre listings and stations change on the order of hours, but the
    home screen asks for them on every open. Without this each visit pays the
    full round trip to the source — and then the playability check on a fresh
    set of tracks, which is the expensive part.
    """
    store: dict[tuple, tuple[Any, float]] = {}

    def decorator(func):
        @functools.wraps(func)
        async def wrapper(self, *args, **kwargs):
            key = (func.__name__, args, tuple(sorted(kwargs.items())))
            now = time.monotonic()

            entry = store.get(key)
            if entry is not None and now - entry[1] < seconds:
                return entry[0]

            result = await func(self, *args, **kwargs)

            # An empty result is usually the source failing rather than an
            # honest answer; caching it would make the failure stick.
            if result:
                store[key] = (result, now)
                if len(store) > 500:
                    for stale, _ in sorted(store.items(), key=lambda item: item[1][1])[:100]:
                        store.pop(stale, None)

            return result

        return wrapper

    return decorator


class SoundCloudError(Exception):
    pass


@dataclass
class _CachedClientID:
    value: str
    fetched_at: datetime

    @property
    def is_stale(self) -> bool:
        return datetime.now(UTC) - self.fetched_at > timedelta(hours=6)


class SoundCloudClient:
    def __init__(self) -> None:
        self._client_id: _CachedClientID | None = None
        self._lock = asyncio.Lock()

    async def client_id(self, force_refresh: bool = False) -> str:
        async with self._lock:
            cached = self._client_id
            if cached and not cached.is_stale and not force_refresh:
                return cached.value

            value = await self._scrape_client_id()
            self._client_id = _CachedClientID(value=value, fetched_at=datetime.now(UTC))
            logger.info("SoundCloud client id refreshed")
            return value

    async def _scrape_client_id(self) -> str:
        async with httpx.AsyncClient(
            timeout=20, headers={"User-Agent": USER_AGENT}, follow_redirects=True
        ) as client:
            home = await client.get(WEB_BASE)
            home.raise_for_status()

            scripts = _SCRIPT_PATTERN.findall(home.text)
            if not scripts:
                raise SoundCloudError("Не удалось разобрать страницу источника")

            # The id lives in one of the late bundles, so walk them newest-first
            # rather than downloading all of them.
            for url in reversed(scripts):
                try:
                    bundle = await client.get(url)
                except httpx.HTTPError:
                    continue

                match = _CLIENT_ID_PATTERN.search(bundle.text)
                if match:
                    return match.group(1)

        raise SoundCloudError("Не удалось получить ключ источника")

    async def request(
        self,
        path: str,
        params: dict[str, Any] | None = None,
        *,
        absolute_url: str | None = None,
        _retried: bool = False,
    ) -> Any:
        client_id = await self.client_id()
        query = dict(params or {})
        query["client_id"] = client_id

        url = absolute_url or f"{API_BASE}/{path.lstrip('/')}"

        async with httpx.AsyncClient(
            timeout=25, headers={"User-Agent": USER_AGENT}, follow_redirects=True
        ) as client:
            try:
                response = await client.get(url, params=query)
            except httpx.HTTPError as exc:
                raise SoundCloudError("Источник недоступен") from exc

        if response.status_code in (401, 403) and not _retried:
            # The id rotated: scrape a fresh one and try once more.
            await self.client_id(force_refresh=True)
            return await self.request(path, params, absolute_url=absolute_url, _retried=True)

        if response.status_code == 404:
            raise SoundCloudError("Не найдено")

        if response.status_code >= 400:
            raise SoundCloudError(f"Источник вернул ошибку {response.status_code}")

        return response.json()

    # MARK: - Endpoints

    async def search_tracks(self, query: str, limit: int = 30, offset: int = 0) -> list[dict]:
        data = await self.request(
            "search/tracks", {"q": query, "limit": limit, "offset": offset}
        )
        return data.get("collection", [])

    async def search_all(self, query: str, limit: int = 20) -> dict:
        data = await self.request("search", {"q": query, "limit": limit})
        collection = data.get("collection", [])
        return {
            "tracks": [item for item in collection if item.get("kind") == "track"],
            "users": [item for item in collection if item.get("kind") == "user"],
            "playlists": [item for item in collection if item.get("kind") == "playlist"],
        }

    async def track(self, track_id: str) -> dict:
        data = await self.request("tracks", {"ids": track_id})
        if not data:
            raise SoundCloudError("Трек не найден")
        return data[0]

    async def tracks(self, track_ids: list[str]) -> list[dict]:
        if not track_ids:
            return []
        return await self.request("tracks", {"ids": ",".join(track_ids)})

    async def user(self, user_id: str) -> dict:
        return await self.request(f"users/{user_id}")

    async def user_tracks(self, user_id: str, limit: int = 50, offset: int = 0) -> list[dict]:
        data = await self.request(
            f"users/{user_id}/tracks", {"limit": limit, "offset": offset}
        )
        return data.get("collection", [])

    async def user_playlists(self, user_id: str, limit: int = 20) -> list[dict]:
        data = await self.request(f"users/{user_id}/playlists", {"limit": limit})
        return data.get("collection", [])

    async def playlist(self, playlist_id: str) -> dict:
        return await self.request(f"playlists/{playlist_id}")

    async def related_tracks(self, track_id: str, limit: int = 30) -> list[dict]:
        data = await self.request(f"tracks/{track_id}/related", {"limit": limit})
        return data.get("collection", [])

    @_cached(1800)
    async def station_tracks(self, track_id: str, limit: int = 50) -> list[dict]:
        """The personal-radio equivalent.

        A track station is what the web player uses for its endless mix, and
        it is the closest thing here to a taste-driven wave — it selects on
        sound rather than on who made it.
        """
        data = await self.request(
            f"stations/soundcloud:track-stations:{track_id}/tracks", {"limit": limit}
        )
        return data.get("collection", [])

    @_cached(900)
    async def charts(self, genre: str = "all-music", kind: str = "trending", limit: int = 30) -> list[dict]:
        """Chart tracks.

        Most genre/kind combinations this endpoint once served now 404; only
        trending across all music answers reliably. Rather than surface that
        as an error, an unavailable combination falls back to the one that
        works — an empty home screen is worse than a less specific one.
        """
        try:
            data = await self.request(
                "charts",
                {"kind": kind, "genre": f"soundcloud:genres:{genre}", "limit": limit},
            )
        except SoundCloudError:
            if (kind, genre) == ("trending", "all-music"):
                return []
            try:
                data = await self.request(
                    "charts",
                    {"kind": "trending", "genre": "soundcloud:genres:all-music", "limit": limit},
                )
            except SoundCloudError:
                return []

        return [item.get("track") for item in data.get("collection", []) if item.get("track")]

    @_cached(900)
    async def genre_tracks(self, genre: str, limit: int = 30) -> list[dict]:
        """Popular tracks in a genre.

        Search is the only genre-aware listing still available. Its default
        order mixes in a lot of very small uploads, so results are ranked by
        play count here before being handed on.
        """
        try:
            data = await self.request(
                "search/tracks",
                {"q": "*", "filter.genre": genre, "limit": min(limit * 3, 100)},
            )
        except SoundCloudError:
            return []

        items = [item for item in data.get("collection", []) if item.get("kind") == "track"]
        items.sort(key=lambda item: item.get("playback_count") or 0, reverse=True)
        return items[:limit]

    @_cached(1800)
    async def mixed_selections(self, limit: int = 10) -> list[dict]:
        """The editorial shelves the web player shows on its home page."""
        try:
            data = await self.request("mixed-selections", {"limit": limit})
        except SoundCloudError:
            return []
        return data.get("collection", [])

    async def selection_playlists(self, limit: int = 10) -> list[dict]:
        """Flattens the shelves into a plain list of playlists."""
        playlists: list[dict] = []
        for shelf in await self.mixed_selections(limit=limit):
            for item in (shelf.get("items") or {}).get("collection", []):
                if item.get("kind") in ("playlist", "system-playlist"):
                    item = dict(item)
                    item["shelf"] = shelf.get("title")
                    playlists.append(item)
        return playlists

    async def system_playlist(self, urn: str) -> dict:
        """System playlists live under their own path and are keyed by urn."""
        return await self.request(f"system-playlists/{urn}")

    async def stream_url(self, track: dict) -> str:
        """Resolves a playable URL for a track.

        Every variant is tried, best first, because a track can offer several
        and only some of them answer: label-owned uploads in particular return
        404 for variants they still advertise. Giving up after the first
        failure was what made those tracks look broken.

        Progressive MP3 is preferred — it plays in AVPlayer directly and
        supports byte-range seeking; HLS works too and is the usual fallback.
        """
        transcodings = (track.get("media") or {}).get("transcodings") or []
        if not transcodings:
            raise SoundCloudError("У трека нет доступного потока")

        def rank(item: dict) -> tuple[int, int]:
            fmt = item.get("format") or {}
            protocol = fmt.get("protocol")
            protocol_rank = {"progressive": 0, "hls": 1}.get(protocol, 9)
            quality_rank = 0 if item.get("quality") == "hq" else 1
            return (protocol_rank, quality_rank)

        candidates = [item for item in sorted(transcodings, key=rank) if rank(item)[0] < 9]
        authorization = track.get("track_authorization")

        for candidate in candidates:
            params = {}
            if authorization:
                params["track_authorization"] = authorization

            try:
                payload = await self.request("", params, absolute_url=candidate["url"])
            except SoundCloudError:
                continue

            if url := payload.get("url"):
                return url

        raise SoundCloudError("Трек недоступен для прослушивания")

    async def is_playable(self, track: dict) -> bool:
        """Whether a stream can actually be resolved for this track.

        Nothing in a track's metadata distinguishes one that plays from one
        that does not — policy, monetisation and the streamable flag read the
        same either way. The only reliable answer costs a request, which is
        why the result is worth caching.
        """
        try:
            await self.stream_url(track)
            return True
        except SoundCloudError:
            return False


soundcloud = SoundCloudClient()
