"""Music catalogue served to the app.

SoundCloud is the source. Everything is normalised here rather than in the
app, so the client speaks one shape regardless of where a track came from —
which is what lets a second source be added later without touching the app.
"""

import asyncio
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Query, Request, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.api.deps import CurrentUser, SessionDep
from app.services.playability import filter_playable
from app.services.soundcloud import SoundCloudError, soundcloud

router = APIRouter(prefix="/catalog", tags=["catalog"])


class CatalogTrack(BaseModel):
    id: str
    title: str
    artist_id: str | None
    artist_name: str
    artwork_url: str | None
    duration_seconds: float
    permalink: str | None = None
    genre: str | None = None
    playback_count: int | None = None


class CatalogArtist(BaseModel):
    id: str
    name: str
    avatar_url: str | None
    followers: int | None = None
    description: str | None = None
    track_count: int | None = None


class CatalogPlaylist(BaseModel):
    id: str
    title: str
    artwork_url: str | None
    track_count: int
    owner_name: str | None
    year: int | None = None
    # "album", "ep", "single" or null for an ordinary playlist. The artist
    # screen shows releases separately from playlists someone assembled.
    kind: str | None = None


class SearchResponse(BaseModel):
    tracks: list[CatalogTrack]
    artists: list[CatalogArtist]
    playlists: list[CatalogPlaylist]


def _upsize(url: str | None) -> str | None:
    """SoundCloud hands out 100px thumbnails by default; the app shows these
    full-width, where that looks like a broken image."""
    if not url:
        return None
    return url.replace("-large.jpg", "-t500x500.jpg").replace("-small.jpg", "-t500x500.jpg")


def normalise_track(raw: dict[str, Any]) -> CatalogTrack | None:
    if not raw or raw.get("kind") != "track":
        return None
    if raw.get("policy") == "BLOCK" or raw.get("streamable") is False:
        return None

    user = raw.get("user") or {}
    artwork = raw.get("artwork_url") or user.get("avatar_url")

    return CatalogTrack(
        id=str(raw.get("id")),
        title=raw.get("title") or "Без названия",
        artist_id=str(user["id"]) if user.get("id") else None,
        artist_name=user.get("username") or "Неизвестный исполнитель",
        artwork_url=_upsize(artwork),
        # full_duration is the real length; duration can be a 30s preview
        # window for tracks the viewer cannot hear in full.
        duration_seconds=(raw.get("full_duration") or raw.get("duration") or 0) / 1000,
        permalink=raw.get("permalink_url"),
        genre=raw.get("genre") or None,
        playback_count=raw.get("playback_count"),
    )


def normalise_artist(raw: dict[str, Any]) -> CatalogArtist | None:
    if not raw or not raw.get("id"):
        return None
    return CatalogArtist(
        id=str(raw["id"]),
        name=raw.get("username") or "Исполнитель",
        avatar_url=_upsize(raw.get("avatar_url")),
        followers=raw.get("followers_count"),
        description=raw.get("description"),
        track_count=raw.get("track_count"),
    )


def normalise_playlist(raw: dict[str, Any]) -> CatalogPlaylist | None:
    if not raw or not raw.get("id"):
        return None

    user = raw.get("user") or {}
    stamp = raw.get("release_date") or raw.get("display_date") or raw.get("created_at") or ""
    year = int(stamp[:4]) if stamp[:4].isdigit() else None

    # A release usually has no artwork of its own until it does; falling back
    # to the first track's cover beats an empty tile.
    artwork = raw.get("artwork_url")
    if not artwork:
        for track in raw.get("tracks") or []:
            if track.get("artwork_url"):
                artwork = track["artwork_url"]
                break

    return CatalogPlaylist(
        id=str(raw["id"]),
        title=raw.get("title") or "Плейлист",
        artwork_url=_upsize(artwork),
        track_count=raw.get("track_count") or 0,
        owner_name=user.get("username"),
        year=year,
        kind=raw.get("set_type") or None,
    )


def _tracks(items: list[dict]) -> list[CatalogTrack]:
    return [track for track in (normalise_track(item) for item in items) if track]


def _guard(error: SoundCloudError) -> HTTPException:
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(error))


@router.get("/search", response_model=SearchResponse)
async def search(
    user: CurrentUser,
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(30, ge=1, le=50),
) -> SearchResponse:
    try:
        results = await soundcloud.search_all(q, limit=limit)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    return SearchResponse(
        tracks=_tracks(results["tracks"]),
        artists=[a for a in (normalise_artist(u) for u in results["users"]) if a],
        playlists=[p for p in (normalise_playlist(p) for p in results["playlists"]) if p],
    )


@router.get("/search/tracks", response_model=list[CatalogTrack])
async def search_tracks(
    user: CurrentUser,
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(30, ge=1, le=50),
    offset: int = Query(0, ge=0),
) -> list[CatalogTrack]:
    try:
        return _tracks(await soundcloud.search_tracks(q, limit=limit, offset=offset))
    except SoundCloudError as exc:
        raise _guard(exc) from exc


@router.get("/tracks/{track_id}", response_model=CatalogTrack)
async def track(track_id: str, user: CurrentUser) -> CatalogTrack:
    try:
        raw = await soundcloud.track(track_id)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    normalised = normalise_track(raw)
    if normalised is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Трек недоступен")
    return normalised


class StreamResponse(BaseModel):
    url: str


@router.get("/tracks/{track_id}/stream", response_model=StreamResponse)
async def stream(track_id: str, user: CurrentUser) -> StreamResponse:
    """Returns a playable media url.

    The signed url is short-lived, so the app asks for it at the moment it
    starts playing rather than caching it alongside the track.
    """
    try:
        raw = await soundcloud.track(track_id)
        return StreamResponse(url=await soundcloud.stream_url(raw))
    except SoundCloudError as exc:
        raise _guard(exc) from exc


@router.get("/tracks/{track_id}/audio")
async def audio(track_id: str, user: CurrentUser, request: Request) -> StreamingResponse:
    """Streams the audio through this server.

    The signed url points at a CDN the phone normally reaches directly, which
    is faster and costs us nothing. This is the fallback for connections that
    cannot: the bytes take the same route as everything else the app asks for.

    Range headers are passed through in both directions — without them
    seeking within a track does not work, and the player will not scrub.
    """
    try:
        raw = await soundcloud.track(track_id)
        source = await soundcloud.stream_url(raw)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    headers = {}
    if range_header := request.headers.get("range"):
        headers["Range"] = range_header

    client = httpx.AsyncClient(timeout=httpx.Timeout(30, read=None), follow_redirects=True)
    upstream = await client.send(
        client.build_request("GET", source, headers=headers), stream=True
    )

    if upstream.status_code >= 400:
        await upstream.aclose()
        await client.aclose()
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY, detail="Не удалось получить аудио"
        )

    async def body():
        try:
            async for chunk in upstream.aiter_bytes(chunk_size=64 * 1024):
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    passthrough = {
        name: value
        for name, value in upstream.headers.items()
        if name.lower() in ("content-length", "content-range", "accept-ranges", "content-type")
    }
    passthrough.setdefault("Accept-Ranges", "bytes")
    passthrough.setdefault("Content-Type", "audio/mpeg")

    return StreamingResponse(body(), status_code=upstream.status_code, headers=passthrough)


@router.get("/artists/{artist_id}", response_model=CatalogArtist)
async def artist(artist_id: str, user: CurrentUser) -> CatalogArtist:
    try:
        raw = await soundcloud.user(artist_id)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    normalised = normalise_artist(raw)
    if normalised is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Исполнитель не найден")
    return normalised


@router.get("/artists/{artist_id}/tracks", response_model=list[CatalogTrack])
async def artist_tracks(
    artist_id: str,
    user: CurrentUser,
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> list[CatalogTrack]:
    try:
        return _tracks(await soundcloud.user_tracks(artist_id, limit=limit, offset=offset))
    except SoundCloudError as exc:
        raise _guard(exc) from exc


class ArtistDetailResponse(BaseModel):
    artist: CatalogArtist
    top_tracks: list[CatalogTrack]
    releases: list[CatalogPlaylist]
    similar_artists: list[CatalogArtist]


@router.get("/artists/{artist_id}/detail", response_model=ArtistDetailResponse)
async def artist_detail(artist_id: str, user: CurrentUser) -> ArtistDetailResponse:
    """Everything the artist screen needs, in one request.

    Four separate calls from the app meant four round trips before anything
    could be drawn; fanning them out here makes the screen appear at once.
    """
    async def safe(coro, default):
        try:
            return await coro
        except SoundCloudError:
            return default

    profile, tracks, playlists = await asyncio.gather(
        safe(soundcloud.user(artist_id), {}),
        safe(soundcloud.user_tracks(artist_id, limit=50), []),
        safe(soundcloud.user_playlists(artist_id, limit=20), []),
    )

    normalised = normalise_artist(profile)
    if normalised is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Исполнитель не найден")

    releases = [p for p in (normalise_playlist(item) for item in playlists) if p]
    # Newest first, and anything undated last — a release list that opens on
    # something from years ago reads as stale.
    releases.sort(key=lambda item: item.year or 0, reverse=True)

    similar = await safe(soundcloud.related_artists(artist_id, limit=12), [])

    return ArtistDetailResponse(
        artist=normalised,
        top_tracks=_tracks(tracks),
        releases=releases,
        similar_artists=[a for a in (normalise_artist(item) for item in similar) if a],
    )


@router.get("/playlists/{playlist_id}/tracks", response_model=list[CatalogTrack])
async def playlist_tracks(playlist_id: str, user: CurrentUser) -> list[CatalogTrack]:
    try:
        raw = await soundcloud.playlist(playlist_id)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    items = raw.get("tracks") or []

    # A playlist response often carries only ids past the first few tracks;
    # those have to be fetched before they can be shown.
    hydrated = [item for item in items if item.get("title")]
    missing = [str(item["id"]) for item in items if not item.get("title") and item.get("id")]

    for index in range(0, len(missing), 50):
        chunk = missing[index : index + 50]
        try:
            hydrated.extend(await soundcloud.tracks(chunk))
        except SoundCloudError:
            break

    return _tracks(hydrated)


@router.get("/charts", response_model=list[CatalogTrack])
async def charts(
    user: CurrentUser,
    genre: str = Query("all-music", max_length=40),
    kind: str = Query("trending", pattern="^(top|trending)$"),
    limit: int = Query(30, ge=1, le=50),
) -> list[CatalogTrack]:
    try:
        raw = await soundcloud.charts(genre=genre, kind=kind, limit=limit * 2)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    return _tracks(await filter_playable(raw, limit))
