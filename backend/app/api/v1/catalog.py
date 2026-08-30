"""Music catalogue served to the app.

SoundCloud is the source. Everything is normalised here rather than in the
app, so the client speaks one shape regardless of where a track came from —
which is what lets a second source be added later without touching the app.
"""

import asyncio
import re
import time
from pathlib import Path
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Query, Request, Response, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from app.api.deps import CurrentUser, SessionDep
from app.schemas.common import MessageOut
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.models import ReferenceArtist
from app.services import audio_cache, authenticity, catalog_meta
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
    # Whether the source vouches for this account being who it says it is.
    is_verified: bool = False


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


def _credited(raw: dict[str, Any]) -> str | None:
    """The artist a release credits, when it says anything useful."""
    metadata = raw.get("publisher_metadata") or {}
    name = (metadata.get("artist") or "").strip()

    if not name or len(name) > 60 or name.lower() == "various artists":
        return None
    return name


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
        # What the release credits, before who uploaded it. An account is
        # called "☆LiL PEEP☆"; the release says "Lil Peep".
        artist_name=_credited(raw) or user.get("username") or "Неизвестный исполнитель",
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
        is_verified=bool(raw.get("verified")),
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
    session: SessionDep,
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(30, ge=1, le=50),
) -> SearchResponse:
    try:
        results = await soundcloud.search_all(q, limit=limit)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    # Anyone can open an account under a famous name, and a search for one
    # used to return a dozen of them beside the real thing.
    #
    # Only the artist list is filtered. Tracks are left alone: plenty of good
    # music is uploaded by people who are not the artist and never claimed to
    # be, and hiding a song because of who posted it would empty the
    # catalogue. What is hidden is the impersonation, not the music.
    genuine = await authenticity.filter_artists(results["users"], limit=10, session=session)

    # Being in that catalogue is what official means here, so the mark
    # follows the same rule that decided they are shown at all.
    artists = [a for a in (normalise_artist(u) for u in genuine) if a]
    for artist in artists:
        artist.is_verified = True

    tracks = _tracks(await authenticity.filter_tracks(session, results["tracks"]))
    # Clean track titles / artist names / covers from Spotify. Not hiding here:
    # search should still surface what SoundCloud has, even off-Spotify.
    tracks = await catalog_meta.enrich_catalog_tracks(tracks, hide_unmatched=False)

    return SearchResponse(
        tracks=tracks,
        artists=artists,
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
        return StreamResponse(url=await soundcloud.resolved_stream(track_id))
    except SoundCloudError as exc:
        raise _guard(exc) from exc


@router.post("/tracks/{track_id}/warm", response_model=MessageOut)
async def warm(track_id: str, user: CurrentUser) -> MessageOut:
    """Fetches a track ahead of being asked to play it.

    Called for the next in a queue while the current one is still playing.
    Resolving is the cheap half; having the audio already on disk is what
    makes the next track start the instant it is wanted.

    Returns as soon as the work is scheduled — nobody is waiting on this, and
    holding the request open would only delay the track that is playing.
    """
    try:
        source = await soundcloud.resolved_stream(track_id)
    except SoundCloudError:
        # A track that cannot be warmed is not an error worth surfacing; it
        # will be skipped when its turn comes.
        return MessageOut(detail="skip")

    asyncio.create_task(audio_cache.ensure(track_id, source))
    return MessageOut(detail="ok")


@router.get("/tracks/{track_id}/audio")
async def audio(track_id: str, user: CurrentUser, request: Request) -> Response:
    """Streams the audio for a track.

    The signed url the source hands out is bound to the region it was issued
    in, so a phone elsewhere is refused even though the link looks valid. The
    server holds the signature that matches and serves the bytes on.

    Those bytes come from disk. A player asks for a track in pieces — several
    ranged requests before the first sound, more while it plays — and going
    back to the source for each one meant a new connection every time, which
    was almost all of the delay before playback began.
    """
    try:
        source = await soundcloud.resolved_stream(track_id)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    path = await audio_cache.ensure(track_id, source)

    if path is None:
        # Nothing cached and the fetch failed: fall back to passing the
        # source through, which is slower but better than silence.
        return await _passthrough(source, request)

    return _ranged_file(path, request)


def _ranged_file(path: Path, request: Request) -> Response:
    """Serves a file, honouring the Range header.

    Without ranges a player cannot seek and will often refuse to start at
    all, so this is not optional.
    """
    size = path.stat().st_size
    start = 0
    end = size - 1
    partial = False

    if header := request.headers.get("range"):
        match = re.match(r"bytes=(\d*)-(\d*)", header.strip())
        if match:
            first, last = match.groups()
            if first:
                start = min(int(first), size - 1)
                end = int(last) if last else size - 1
            elif last:
                # A suffix range: the last N bytes.
                start = max(size - int(last), 0)
            end = min(end, size - 1)
            partial = True

    length = max(end - start + 1, 0)

    def chunks():
        with path.open("rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                block = handle.read(min(256 * 1024, remaining))
                if not block:
                    break
                remaining -= len(block)
                yield block

    headers = {
        "Content-Length": str(length),
        "Accept-Ranges": "bytes",
        "Content-Type": "audio/mpeg",
    }
    if partial:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"

    return StreamingResponse(
        chunks(), status_code=206 if partial else 200, headers=headers
    )


async def _passthrough(source: str, request: Request) -> StreamingResponse:
    """Relays the source directly. Used only when caching failed."""
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
    limit: int = Query(50, ge=1, le=300),
    offset: int = Query(0, ge=0),
) -> list[CatalogTrack]:
    """The artist's whole catalogue, paged for the caller.

    The source hands out fifty at a time behind a link chain, so this walks
    it once and slices — asking for page three with an offset returns
    nothing useful from that endpoint.
    """
    try:
        profile = await soundcloud.user(artist_id)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    name = profile.get("username") or ""
    every = await _artist_catalogue(artist_id, name)

    return _tracks(every[offset : offset + limit])


_artist_cache: dict[str, tuple[list[dict], float]] = {}
_ARTIST_TTL = 15 * 60


async def _artist_catalogue(artist_id: str, name: str, cap: int = 300) -> list[dict]:
    """An artist's music, not just what one account uploaded.

    On this source an artist is an account, and an account holds only what
    that account posted. The same songs are often uploaded, remixed and
    reposted by others, which is why a profile could show forty tracks for
    someone with a far larger catalogue.

    So three sources are merged: the account's own uploads, what it reposted,
    and what a search for the name turns up. Own uploads lead, because those
    are unambiguously theirs.
    """
    key = f"{artist_id}:{cap}"
    cached = _artist_cache.get(key)
    if cached is not None and time.monotonic() - cached[1] < _ARTIST_TTL:
        return cached[0]

    async def safe(coro, default):
        try:
            return await coro
        except SoundCloudError:
            return default

    own, reposts, searched = await asyncio.gather(
        safe(soundcloud.all_user_tracks(artist_id, cap=cap), []),
        safe(soundcloud.user_reposts(artist_id, limit=50), []),
        safe(soundcloud.search_tracks(_plain(name), limit=50), []) if name else safe(_nothing(), []),
    )

    collected: list[dict] = []
    seen: set[str] = set()

    for group in (own, reposts, searched):
        for raw in group:
            track_id = str(raw.get("id"))
            if track_id in seen:
                continue

            # A search for a name returns anything mentioning it; keep only
            # what actually credits this artist, or the page fills with
            # unrelated uploads that happen to share a word.
            if group is searched and not _credits(raw, name):
                continue

            seen.add(track_id)
            collected.append(raw)

    result = collected[:cap]
    _artist_cache[key] = (result, time.monotonic())
    if len(_artist_cache) > 300:
        for stale, _ in sorted(_artist_cache.items(), key=lambda item: item[1][1])[:100]:
            _artist_cache.pop(stale, None)

    return result


async def _nothing() -> list[dict]:
    return []


def _plain(name: str) -> str:
    """Strips the decoration accounts put around their names.

    Handles such as "☆LiL PEEP☆" search as literally that, which matches
    almost nothing. The letters are the part worth searching on.
    """
    kept = [ch for ch in name if ch.isalnum() or ch.isspace() or ch in "-_&'."]
    return " ".join("".join(kept).split())


def _credits(raw: dict[str, Any], name: str) -> bool:
    needle = _plain(name).lower()
    if not needle:
        return False

    haystack = " ".join(
        [
            raw.get("title") or "",
            (raw.get("user") or {}).get("username") or "",
            raw.get("publisher_metadata", {}).get("artist") or "" if raw.get("publisher_metadata") else "",
        ]
    ).lower()

    return needle in haystack


class ArtistDetailResponse(BaseModel):
    artist: CatalogArtist
    top_tracks: list[CatalogTrack]
    total_track_count: int = 0
    releases: list[CatalogPlaylist]
    similar_artists: list[CatalogArtist]


@router.get("/artists/{artist_id}/detail", response_model=ArtistDetailResponse)
async def artist_detail(
    artist_id: str, user: CurrentUser, session: SessionDep
) -> ArtistDetailResponse:
    """Everything the artist screen needs, in one request.

    Four separate calls from the app meant four round trips before anything
    could be drawn; fanning them out here makes the screen appear at once.
    """
    async def safe(coro, default):
        try:
            return await coro
        except SoundCloudError:
            return default

    profile, playlists = await asyncio.gather(
        safe(soundcloud.user(artist_id), {}),
        safe(soundcloud.user_playlists(artist_id, limit=20), []),
    )

    normalised = normalise_artist(profile)
    if normalised is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Исполнитель не найден")

    normalised.is_verified = await authenticity.is_genuine(profile, session=session)

    # Enough for a shortlist and an honest count; the full catalogue is
    # a separate request, made only when someone asks to see all of it.
    tracks = await _artist_catalogue(artist_id, normalised.name, cap=120)

    top = _tracks(tracks)
    top.sort(key=lambda track: track.playback_count or 0, reverse=True)

    releases = [p for p in (normalise_playlist(item) for item in playlists) if p]
    # Newest first, and anything undated last — a release list that opens on
    # something from years ago reads as stale.
    releases.sort(key=lambda item: item.year or 0, reverse=True)

    similar = await safe(soundcloud.related_artists(artist_id, limit=12), [])

    return ArtistDetailResponse(
        artist=normalised,
        # A shortlist, ranked by plays. The full catalogue is a tap away;
        # thirty rows under "популярные" is a list, not a highlight.
        top_tracks=top[:8],
        total_track_count=len(top),
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


class SourceKey(BaseModel):
    client_id: str


class ReferenceArtistIn(BaseModel):
    id: str = Field(max_length=32)
    name: str = Field(max_length=200)
    tracks: int = 0
    albums: int = 0


class ReferenceUpload(BaseModel):
    artists: list[ReferenceArtistIn] = Field(max_length=50_000)
    # Whether to keep what is already stored. A partial collection should add
    # to the list rather than shrink it; a full one replaces it.
    replace: bool = False


class ReferenceResult(BaseModel):
    stored: int
    total: int


@router.post("/reference", response_model=ReferenceResult)
async def upload_reference(
    payload: ReferenceUpload, user: CurrentUser, session: SessionDep
) -> ReferenceResult:
    """Takes the artist list the app collected.

    That list is what decides which accounts are shown, and it can only be
    gathered from a device: the catalogue it comes from does not answer this
    server at all. Sending it here rather than passing a file around means a
    fresh collection takes effect the moment it finishes.
    """
    if payload.replace:
        await session.execute(delete(ReferenceArtist))

    rows = []
    seen: set[str] = set()

    for entry in payload.artists:
        key = authenticity.normalise(entry.name)
        if not key or key in seen:
            continue
        seen.add(key)
        rows.append(
            {
                "source_id": entry.id,
                "name": entry.name,
                "normalised": key,
                "tracks": entry.tracks,
                "albums": entry.albums,
            }
        )

    if rows:
        statement = pg_insert(ReferenceArtist).values(rows)
        await session.execute(
            statement.on_conflict_do_update(
                index_elements=[ReferenceArtist.source_id],
                set_={
                    "name": statement.excluded.name,
                    "normalised": statement.excluded.normalised,
                    "tracks": statement.excluded.tracks,
                    "albums": statement.excluded.albums,
                },
            )
        )

    await session.commit()

    total = await session.scalar(select(func.count()).select_from(ReferenceArtist)) or 0
    return ReferenceResult(stored=len(rows), total=total)


@router.get("/source-key", response_model=SourceKey)
async def source_key() -> SourceKey:
    """The key the app needs to reach the source itself.

    The app talks to the source directly now — it is reachable from networks
    this server is not, and a stream it resolves carries a signature issued
    for the listener rather than for Frankfurt. Handing over the key we
    already hold saves the app several requests working it out alone.

    Unauthenticated, because an app that cannot reach us to sign in is
    exactly the case this exists for.
    """
    return SourceKey(client_id=await soundcloud.client_id())


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
