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
from app.services import audio_cache, authenticity, catalog_meta, rescue, spotify_meta
from app.services.playability import filter_playable
from app.services.soundcloud import SoundCloudError, soundcloud


def _is_spotify_id(value: str) -> bool:
    """Spotify ids are 22-char base62; SoundCloud ids are all digits."""
    return bool(value) and not value.isdigit() and len(value) >= 18


async def _catalog_from_spotify_tracks(
    session, sp_tracks: list[dict], *, drop_unresolved: bool = True
) -> list["CatalogTrack"]:
    """Spotify track dicts -> CatalogTrack, with a SoundCloud stream resolved
    behind each. Tracks with no SoundCloud match are dropped (search) rather
    than shown greyed."""
    from app.services import sc_resolve  # lazy: sc_resolve imports this module

    if not sp_tracks:
        return []
    links = await sc_resolve.resolve(session, sp_tracks)
    out: list[CatalogTrack] = []
    seen_sc: set[str] = set()
    for t in sp_tracks:
        sc_id = links.get(t.get("spotify_id"))
        if not sc_id:
            if drop_unresolved:
                continue
            sc_id = f"sp:{t.get('spotify_id') or ''}"
        elif sc_id in seen_sc:
            continue  # two Spotify tracks resolved to the same upload
        seen_sc.add(sc_id)
        out.append(
            CatalogTrack(
                id=sc_id,
                title=t.get("title") or "",
                artist_id=t.get("artist_id"),
                artist_name=t.get("artist_name") or "",
                artwork_url=t.get("cover_url"),
                duration_seconds=(t.get("duration_ms") or 0) / 1000,
                playable=not sc_id.startswith("sp:"),
            )
        )
    return out

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
    # False when the track comes from Spotify but no SoundCloud stream could be
    # matched — shown greyed, can't be played or saved.
    playable: bool = True


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
    albums: list[CatalogPlaylist] = []
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


def normalise_track(raw: dict[str, Any], *, fallback_artwork: str | None = None) -> CatalogTrack | None:
    if not raw or raw.get("kind") != "track":
        return None
    if raw.get("policy") == "BLOCK" or raw.get("streamable") is False:
        return None

    user = raw.get("user") or {}
    # A track inside an album or playlist often carries no artwork of its
    # own at all — the picture belongs to the release, not each track on it —
    # so without this every row in an album with no per-track art showed
    # nothing, not a slow load but a genuine absence the app had no fallback
    # for. `fallback_artwork` is the set's own cover, passed in by whichever
    # caller already has it.
    artwork = raw.get("artwork_url") or user.get("avatar_url") or fallback_artwork

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


def _tracks(items: list[dict], *, fallback_artwork: str | None = None) -> list[CatalogTrack]:
    return [
        track
        for track in (normalise_track(item, fallback_artwork=fallback_artwork) for item in items)
        if track
    ]


def _guard(error: SoundCloudError) -> HTTPException:
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(error))


async def _search_soundcloud(session, q: str, limit: int) -> SearchResponse:
    """The old path — kept as the fallback when Spotify can't be reached."""
    try:
        results = await soundcloud.search_all(q, limit=limit)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    genuine = await authenticity.filter_artists(results["users"], limit=10, session=session)
    artists = [a for a in (normalise_artist(u) for u in genuine) if a]
    for artist in artists:
        artist.is_verified = True

    tracks = _tracks(await authenticity.filter_tracks(session, results["tracks"]))
    tracks = await catalog_meta.spotify_only(tracks)

    return SearchResponse(
        tracks=tracks,
        artists=artists,
        albums=[],
        playlists=[p for p in (normalise_playlist(p) for p in results["playlists"]) if p],
    )


@router.get("/search", response_model=SearchResponse)
async def search(
    user: CurrentUser,
    session: SessionDep,
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(30, ge=1, le=50),
) -> SearchResponse:
    """Spotify-first: tracks / artists / albums / playlists are Spotify's, with
    a SoundCloud stream resolved behind each track for playback. Falls back to
    a plain SoundCloud search when Spotify is unreachable."""
    sp = await spotify_meta.search(q, limit=limit)
    if not any((sp["tracks"], sp["artists"], sp["albums"], sp["playlists"])):
        return await _search_soundcloud(session, q, limit)

    tracks = await _catalog_from_spotify_tracks(session, sp["tracks"])

    artists = [
        CatalogArtist(
            id=a["id"],
            name=a["name"],
            avatar_url=a.get("image_url"),
            followers=a.get("followers"),
            track_count=None,
            is_verified=True,
        )
        for a in sp["artists"]
        if a.get("id") and a.get("name")
    ]

    albums = [
        CatalogPlaylist(
            id=a["id"],
            title=a["title"],
            artwork_url=a.get("cover_url"),
            track_count=a.get("total_tracks") or 0,
            owner_name=a.get("artist_name"),
            year=int(a["year"]) if (a.get("year") or "").isdigit() else None,
            kind=a.get("kind") or "album",
        )
        for a in sp["albums"]
        if a.get("id") and a.get("title")
    ]

    playlists = [
        CatalogPlaylist(
            id=p["id"],
            title=p["title"],
            artwork_url=p.get("cover_url"),
            track_count=p.get("track_count") or 0,
            owner_name=p.get("owner_name"),
            kind=None,
        )
        for p in sp["playlists"]
        if p.get("id") and p.get("title")
    ]

    return SearchResponse(tracks=tracks, artists=artists, albums=albums, playlists=playlists)


@router.get("/search/tracks", response_model=list[CatalogTrack])
async def search_tracks(
    user: CurrentUser,
    session: SessionDep,
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(30, ge=1, le=50),
    offset: int = Query(0, ge=0),
) -> list[CatalogTrack]:
    try:
        found = _tracks(await soundcloud.search_tracks(q, limit=limit, offset=offset))
        return await catalog_meta.spotify_only(found)
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
        # Not playable from the source — but that is exactly the track worth
        # warming, because finding it elsewhere is the slow part. Done in the
        # background with whatever the source can tell us about it.
        asyncio.create_task(_rescue_quietly(track_id))
        return MessageOut(detail="rescue")

    asyncio.create_task(audio_cache.ensure(track_id, source))
    return MessageOut(detail="ok")


async def _rescue_quietly(track_id: str) -> None:
    try:
        title, artist, duration = await _identity(track_id, None, None, None)
        await rescue.audio(track_id, title, artist, duration)
    except Exception:  # noqa: BLE001 — a warm-up that fails costs nothing
        pass


async def _identity(
    track_id: str, title: str | None, artist: str | None, duration: float | None
) -> tuple[str, str, float]:
    """Which song this is, for finding it somewhere else.

    The app sends what it is showing — the cleaned title and the credited
    artist, which match other catalogues far better than an uploader's own
    spelling does. When it has not, the source's own description is used.
    """
    if title:
        return title, artist or "", float(duration or 0)

    try:
        raw = await soundcloud.track(track_id)
    except SoundCloudError:
        return "", "", 0.0

    return (
        raw.get("title") or "",
        _credited(raw) or (raw.get("user") or {}).get("username") or "",
        float(raw.get("full_duration") or raw.get("duration") or 0) / 1000,
    )


@router.get("/tracks/{track_id}/audio")
async def audio(
    track_id: str,
    user: CurrentUser,
    request: Request,
    title: str | None = Query(None, max_length=300),
    artist: str | None = Query(None, max_length=300),
    duration: float | None = Query(None, ge=0, le=6 * 3600),
) -> Response:
    """Streams the audio for a track, from wherever it can be found.

    The signed url the source hands out is bound to the region it was issued
    in, so a phone elsewhere is refused even though the link looks valid. The
    server holds the signature that matches and serves the bytes on.

    Those bytes come from disk. A player asks for a track in pieces — several
    ranged requests before the first sound, more while it plays — and going
    back to the source for each one meant a new connection every time, which
    was almost all of the delay before playback began.

    And when the source will not serve the track at all — locked behind DRM,
    blocked, or only a thirty-second preview — the same recording is found
    elsewhere rather than answering with an error. That error used to be the
    end of the track: of the requests that reached here in the two weeks
    before this existed, most were exactly that, and every one was a song
    skipped in front of a listener.
    """
    # A copy found elsewhere earlier is used before asking the source again:
    # the source's answer for that track is already known.
    if (rescued := rescue.cached(track_id)) is not None:
        return _ranged_file(rescued, request, "audio/mp4")

    source: str | None = None
    try:
        source = await soundcloud.resolved_stream(track_id)
    except SoundCloudError:
        source = None

    if source is not None:
        path = await audio_cache.ensure(track_id, source)
        if path is not None:
            return _ranged_file(path, request, "audio/mpeg")

    wanted_title, wanted_artist, wanted_length = await _identity(track_id, title, artist, duration)
    rescued = await rescue.audio(track_id, wanted_title, wanted_artist, wanted_length)
    if rescued is not None:
        return _ranged_file(rescued, request, "audio/mp4")

    if source is not None:
        # The source did give a link, the download failed, and nothing else
        # had the song: pass the source through as the very last attempt.
        return await _passthrough(source, request)

    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail="Трек не удалось найти ни в одном источнике",
    )


def _ranged_file(path: Path, request: Request, content_type: str = "audio/mpeg") -> Response:
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
        "Content-Type": content_type,
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
    if _is_spotify_id(artist_id):
        sp = await spotify_meta.artist(artist_id)
        if sp:
            return CatalogArtist(
                id=sp["id"],
                name=sp["name"],
                avatar_url=sp.get("image_url"),
                followers=sp.get("followers"),
                is_verified=True,
            )
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Исполнитель не найден")

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
    session: SessionDep,
    limit: int = Query(50, ge=1, le=300),
    offset: int = Query(0, ge=0),
) -> list[CatalogTrack]:
    """The artist's whole catalogue, paged for the caller.

    The source hands out fifty at a time behind a link chain, so this walks
    it once and slices — asking for page three with an offset returns
    nothing useful from that endpoint.
    """
    if _is_spotify_id(artist_id):
        pool = await _spotify_artist_catalogue(artist_id)
        return await _catalog_from_spotify_tracks(session, pool[offset : offset + limit])

    # The profile fetch exists only to feed `name` to _artist_catalogue's
    # search-fallback source — which only runs on a cache miss; a cache hit
    # returns the first call's result untouched, ignoring `name` entirely.
    # Every later page of the same artist's "Все треки" used to pay for this
    # round trip for a value nothing was going to read.
    name = ""
    if not _artist_catalogue_is_warm(artist_id):
        try:
            profile = await soundcloud.user(artist_id)
        except SoundCloudError as exc:
            raise _guard(exc) from exc
        name = profile.get("username") or ""

    every = await _artist_catalogue(artist_id, name)

    # The account's own uploads (the bulk of `every` — `all_user_tracks`)
    # come back from that listing endpoint with no embedded `user` object at
    # all on some accounts, so normalise_track finds neither a track-level
    # artwork_url nor a user avatar to fall back to — the row stays blank
    # forever, not slowly, since there is nothing left to retry client-side.
    # Same class of bug as playlist/album tracks (see normalise_track's
    # fallback_artwork), fixed the same way: whichever entry in the merged
    # set — a repost or a search hit almost always does — actually carries a
    # picture stands in for the ones that don't, rather than a fresh profile
    # fetch, which the fix just above this stopped making on a warm cache.
    fallback_artwork = next(
        (
            picture
            for raw in every
            if (picture := raw.get("artwork_url") or (raw.get("user") or {}).get("avatar_url"))
        ),
        None,
    )

    return await catalog_meta.spotify_only(
        _tracks(every[offset : offset + limit], fallback_artwork=_upsize(fallback_artwork))
    )


_artist_cache: dict[str, tuple[list[dict], float]] = {}
_ARTIST_TTL = 15 * 60


def _artist_catalogue_is_warm(artist_id: str, cap: int = 300) -> bool:
    """Same freshness check `_artist_catalogue` makes internally, exposed so
    a caller can skip work that only matters on a miss (see `artist_tracks`)."""
    cached = _artist_cache.get(f"{artist_id}:{cap}")
    return cached is not None and time.monotonic() - cached[1] < _ARTIST_TTL


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


_sp_artist_cache: dict[str, tuple[list[dict], float]] = {}
_SP_ARTIST_TTL = 15 * 60

# The chart is the same for every listener, so the enriched result is worth
# holding onto — it is the first thing the search screen draws.
_chart_cache: dict[str, tuple[list["CatalogTrack"], float]] = {}
_CHART_TTL = 10 * 60


def _credits(track: dict, artist_id: str) -> bool:
    """Whether this artist is actually credited on the track.

    A discography listing includes compilations and "appears on" releases, so
    an album's track list is not by itself proof — without this check an
    artist's page fills up with other people's songs.
    """
    ids = track.get("artist_ids") or []
    if ids:
        return artist_id in ids
    return track.get("artist_id") == artist_id


async def _spotify_artist_catalogue(artist_id: str, *, albums: int = 40) -> list[dict]:
    """Every track the artist is credited on — top tracks first, then each
    album's tracks, flattened, filtered to this artist and de-duped.

    Assembling this is one request per album, so it is only ever built for the
    "all tracks" screen, never for the artist page itself, and the result is
    cached. `albums` caps how deep to go for a first page.
    """
    hit = _sp_artist_cache.get(artist_id)
    if hit and time.monotonic() - hit[1] < _SP_ARTIST_TTL and len(hit[0]) > 0:
        return hit[0]

    top, discography = await asyncio.gather(
        spotify_meta.artist_top_tracks(artist_id),
        spotify_meta.discography(artist_id, limit=albums),
    )

    seen: set[str] = set()
    pool: list[dict] = []

    def take(tracks: list[dict]) -> None:
        for tr in tracks:
            sid = tr.get("spotify_id")
            if sid and sid not in seen and _credits(tr, artist_id):
                seen.add(sid)
                pool.append(tr)

    take(top)

    sem = asyncio.Semaphore(8)

    async def one(al: dict) -> list[dict]:
        async with sem:
            full = await spotify_meta.album(al["id"])
        return (full or {}).get("tracks", []) or []

    for tracks in await asyncio.gather(
        *(one(a) for a in discography), return_exceptions=True
    ):
        if isinstance(tracks, list):
            take(tracks)

    _sp_artist_cache[artist_id] = (pool, time.monotonic())
    return pool


async def _spotify_artist_detail(session, artist_id: str) -> ArtistDetailResponse:
    """The artist screen: two upstream requests, not forty.

    Building the whole catalogue here took about eleven seconds — an album
    fetch each — which is why artist pages often never appeared. Top tracks
    and the release list are all this screen shows; the full catalogue is
    assembled only when someone opens "all tracks".
    """
    (sp, top), albums = await asyncio.gather(
        spotify_meta.artist_overview(artist_id),
        spotify_meta.discography(artist_id, limit=30),
    )
    if not sp:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Исполнитель не найден")

    artist_obj = CatalogArtist(
        id=sp["id"], name=sp["name"], avatar_url=sp.get("image_url"),
        followers=sp.get("followers"), is_verified=True,
    )
    top_tracks = await _catalog_from_spotify_tracks(
        session, [t for t in top if _credits(t, artist_id)][:12]
    )
    releases = [
        CatalogPlaylist(
            id=a["id"], title=a["title"], artwork_url=a.get("cover_url"),
            track_count=a.get("total_tracks") or 0, owner_name=a.get("artist_name") or sp["name"],
            year=int(a["year"]) if (a.get("year") or "").isdigit() else None,
            kind=a.get("kind") or "album",
        )
        for a in albums
        if a.get("id") and a.get("title")
    ]
    # Deliberately not re-sorted: a discography listing carries no release
    # date, so sorting by year would put everything in one bucket and scramble
    # the order Spotify already returns them in (newest first).

    # An honest lower bound without paying for the whole catalogue: the count
    # is only used to decide whether to offer "show all".
    cached = _sp_artist_cache.get(artist_id)
    total = len(cached[0]) if cached else sum(a.get("total_tracks") or 1 for a in albums)

    return ArtistDetailResponse(
        artist=artist_obj,
        top_tracks=top_tracks[:10],
        total_track_count=max(total, len(top_tracks)),
        releases=releases,
        similar_artists=[],
    )


@router.get("/artists/{artist_id}/detail", response_model=ArtistDetailResponse)
async def artist_detail(
    artist_id: str, user: CurrentUser, session: SessionDep
) -> ArtistDetailResponse:
    """Everything the artist screen needs, in one request.

    Four separate calls from the app meant four round trips before anything
    could be drawn; fanning them out here makes the screen appear at once.
    """
    if _is_spotify_id(artist_id):
        return await _spotify_artist_detail(session, artist_id)

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

    # Same cap the "all tracks" route below asks for (its default, 300) —
    # deliberately, not the smaller shortlist this screen actually shows.
    # `_artist_catalogue` caches by `{artist_id}:{cap}`, so a different cap
    # here meant opening an artist and then tapping "Все треки" moments
    # later paid for the same expensive gather (own uploads + reposts + a
    # name search, three SoundCloud round trips) *twice* — the second one
    # is exactly the "долго грузит все треки" complaint, on a page that had
    # just been fetched already.
    tracks = await _artist_catalogue(artist_id, normalised.name)

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
async def playlist_tracks(
    playlist_id: str, user: CurrentUser, session: SessionDep
) -> list[CatalogTrack]:
    # A Spotify album or playlist id — serve its tracks, each with a
    # SoundCloud stream resolved behind it.
    if _is_spotify_id(playlist_id):
        detail = await spotify_meta.album(playlist_id) or await spotify_meta.playlist(playlist_id)
        if detail:
            return await _catalog_from_spotify_tracks(session, detail.get("tracks") or [])
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Не найдено")

    try:
        raw = await soundcloud.playlist(playlist_id)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    # The set's own cover, for tracks inside it that have none of their own —
    # same fix as `normalise_playlist` already does for the set itself, just
    # applied the other direction, per-track.
    fallback_artwork = _upsize(raw.get("artwork_url"))

    items = raw.get("tracks") or []

    # A playlist response often carries only ids past the first few tracks;
    # those have to be fetched before they can be shown. They used to be
    # appended after the ones that arrived hydrated, which silently moved
    # every fetched-separately track to the end — a set's real running order
    # never survived that. Fetched by id instead, then re-assembled in the
    # order `items` already has.
    by_id: dict[str, dict] = {}
    missing: list[str] = []
    for item in items:
        item_id = str(item["id"]) if item.get("id") is not None else None
        if item.get("title"):
            if item_id:
                by_id[item_id] = item
        elif item_id:
            missing.append(item_id)

    for index in range(0, len(missing), 50):
        chunk = missing[index : index + 50]
        try:
            fetched = await soundcloud.tracks(chunk)
        except SoundCloudError:
            break
        for track in fetched:
            if track.get("id") is not None:
                by_id[str(track["id"])] = track

    ordered = [by_id[str(item["id"])] for item in items if str(item.get("id")) in by_id]

    return await catalog_meta.spotify_only(_tracks(ordered, fallback_artwork=fallback_artwork))


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
    # The same chart for everyone, so the enriched result is cached rather
    # than re-resolved per listener — this is what the search screen shows
    # first, and it was taking a couple of seconds to appear.
    key = f"{genre}:{kind}:{limit}"
    hit = _chart_cache.get(key)
    if hit and time.monotonic() - hit[1] < _CHART_TTL:
        return hit[0]

    try:
        raw = await soundcloud.charts(genre=genre, kind=kind, limit=limit * 2)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    tracks = await catalog_meta.spotify_only(_tracks(await filter_playable(raw, limit)))
    if tracks:
        _chart_cache[key] = (tracks, time.monotonic())
    return tracks
