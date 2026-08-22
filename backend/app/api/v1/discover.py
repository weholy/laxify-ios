"""Browsing, as opposed to searching.

Search answers a question someone already has. This is for the rest of the
time — the shelves the source curates, what a genre sounds like right now,
what a track leads to, and what other people are listening to.

Everything here is read-only and cached upstream, so these are cheap to call
and safe to call often.
"""

import asyncio

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel

from app.api.deps import CurrentUser, SessionDep
from app.api.v1.catalog import (
    CatalogArtist,
    CatalogPlaylist,
    CatalogTrack,
    normalise_artist,
    normalise_playlist,
    normalise_track,
)
from app.services.playability import filter_playable
from app.services.soundcloud import SoundCloudError, soundcloud

router = APIRouter(prefix="/discover", tags=["discover"])

# The genres worth showing. The source publishes far more, most of which are
# near-empty; these are the ones with enough behind them to fill a screen.
GENRES: list[tuple[str, str]] = [
    ("hiphoprap", "Хип-хоп"),
    ("pop", "Поп"),
    ("electronic", "Электроника"),
    ("rnb", "R&B"),
    ("rock", "Рок"),
    ("dance", "Танцевальная"),
    ("indie", "Инди"),
    ("house", "House"),
    ("trap", "Trap"),
    ("dubstep", "Dubstep"),
    ("drumbass", "Drum & Bass"),
    ("techno", "Techno"),
    ("ambient", "Эмбиент"),
    ("classical", "Классика"),
    ("jazzblues", "Джаз и блюз"),
    ("metal", "Метал"),
    ("reggae", "Регги"),
    ("soundtrack", "Саундтреки"),
    ("country", "Кантри"),
    ("latin", "Латина"),
]

GENRE_TITLES = dict(GENRES)


def _tracks(items: list[dict]) -> list[CatalogTrack]:
    return [track for track in (normalise_track(item) for item in items) if track]


def _guard(error: SoundCloudError) -> HTTPException:
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(error))


class Genre(BaseModel):
    id: str
    title: str


class Shelf(BaseModel):
    """One horizontal row on a browse screen."""

    id: str
    title: str
    subtitle: str | None = None
    tracks: list[CatalogTrack] = []
    playlists: list[CatalogPlaylist] = []
    artists: list[CatalogArtist] = []


class ShowcaseTrack(BaseModel):
    id: str
    title: str
    artist_name: str
    artwork_url: str


@router.get("/showcase", response_model=list[ShowcaseTrack])
async def showcase(limit: int = Query(30, ge=6, le=60)) -> list[ShowcaseTrack]:
    """Artwork for the sign-in screen.

    Deliberately unauthenticated: this is what someone sees *before* they
    have an account, and asking for a token they do not have yet is why the
    screen showed coloured squares instead of album covers.

    Only tracks with real artwork are returned — a placeholder in a wall of
    covers is more noticeable than no cover at all.
    """
    raw = await soundcloud.charts(limit=limit * 2)

    if len(raw) < limit:
        raw += await soundcloud.genre_tracks("hiphoprap", limit=limit)

    seen: set[str] = set()
    result: list[ShowcaseTrack] = []

    for item in raw:
        track = normalise_track(item)
        if track is None or not track.artwork_url or track.id in seen:
            continue
        # A user avatar standing in for missing artwork is usually a face,
        # which reads oddly in a grid of album covers.
        if "avatars" in track.artwork_url:
            continue

        seen.add(track.id)
        result.append(
            ShowcaseTrack(
                id=track.id,
                title=track.title,
                artist_name=track.artist_name,
                artwork_url=track.artwork_url,
            )
        )

        if len(result) >= limit:
            break

    return result


@router.get("/genres", response_model=list[Genre])
async def genres(user: CurrentUser) -> list[Genre]:
    return [Genre(id=key, title=title) for key, title in GENRES]


@router.get("/genres/{genre}/tracks", response_model=list[CatalogTrack])
async def genre_tracks(
    genre: str,
    user: CurrentUser,
    limit: int = Query(40, ge=1, le=100),
) -> list[CatalogTrack]:
    raw = await soundcloud.genre_tracks(genre, limit=limit * 2)
    return _tracks(await filter_playable(raw, limit))


@router.get("/shelves", response_model=list[Shelf])
async def shelves(user: CurrentUser, limit: int = Query(20, ge=5, le=40)) -> list[Shelf]:
    """The editorial rows the source's own front page is built from.

    Fetched together rather than one at a time, since a browse screen wants
    all of them before it can draw anything.
    """
    selections, trending = await asyncio.gather(
        soundcloud.mixed_selections(limit=10),
        soundcloud.charts(limit=limit * 2),
        return_exceptions=True,
    )

    rows: list[Shelf] = []

    if not isinstance(trending, BaseException) and trending:
        rows.append(
            Shelf(
                id="trending",
                title="Сейчас слушают",
                subtitle="Популярное прямо сейчас",
                tracks=_tracks(await filter_playable(trending, limit)),
            )
        )

    if not isinstance(selections, BaseException):
        for shelf in selections:
            items = (shelf.get("items") or {}).get("collection", [])
            playlists = [p for p in (normalise_playlist(item) for item in items) if p]
            if not playlists:
                continue

            rows.append(
                Shelf(
                    id=str(shelf.get("id") or shelf.get("title") or len(rows)),
                    title=shelf.get("title") or "Подборка",
                    playlists=playlists[:limit],
                )
            )

    return rows


@router.get("/tracks/{track_id}/related", response_model=list[CatalogTrack])
async def related(
    track_id: str,
    user: CurrentUser,
    limit: int = Query(30, ge=1, le=50),
) -> list[CatalogTrack]:
    """What this track leads to — the source's own "listeners also played"."""
    try:
        raw = await soundcloud.related_tracks(track_id, limit=limit * 2)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    return _tracks(await filter_playable(raw, limit))


@router.get("/artists/{artist_id}/related", response_model=list[CatalogArtist])
async def related_artists(
    artist_id: str,
    user: CurrentUser,
    limit: int = Query(12, ge=1, le=30),
) -> list[CatalogArtist]:
    raw = await soundcloud.related_artists(artist_id, limit=limit)
    return [artist for artist in (normalise_artist(item) for item in raw) if artist]


@router.get("/artists/{artist_id}/playlists", response_model=list[CatalogPlaylist])
async def artist_playlists(
    artist_id: str,
    user: CurrentUser,
    limit: int = Query(20, ge=1, le=50),
) -> list[CatalogPlaylist]:
    try:
        raw = await soundcloud.user_playlists(artist_id, limit=limit)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    return [playlist for playlist in (normalise_playlist(item) for item in raw) if playlist]


@router.get("/artists/{artist_id}/likes", response_model=list[CatalogTrack])
async def artist_likes(
    artist_id: str,
    user: CurrentUser,
    limit: int = Query(30, ge=1, le=50),
) -> list[CatalogTrack]:
    """What an artist listens to, which is often the best recommendation
    anyone could give for what to play next."""
    raw = await soundcloud.user_likes(artist_id, limit=limit * 2)
    return _tracks(await filter_playable(raw, limit))


class ResolveResponse(BaseModel):
    kind: str
    track: CatalogTrack | None = None
    artist: CatalogArtist | None = None
    playlist: CatalogPlaylist | None = None


@router.get("/resolve", response_model=ResolveResponse)
async def resolve(url: str, user: CurrentUser) -> ResolveResponse:
    """Turns a shared link into something the app can open.

    Someone pasting a link into the app should land on the thing it points
    at, whatever kind of thing that is.
    """
    try:
        raw = await soundcloud.resolve(url)
    except SoundCloudError as exc:
        raise _guard(exc) from exc

    kind = raw.get("kind") or "unknown"

    return ResolveResponse(
        kind=kind,
        track=normalise_track(raw) if kind == "track" else None,
        artist=normalise_artist(raw) if kind == "user" else None,
        playlist=normalise_playlist(raw) if kind in ("playlist", "system-playlist") else None,
    )


class SuggestionsResponse(BaseModel):
    queries: list[str]


@router.get("/suggest", response_model=SuggestionsResponse)
async def suggest(
    q: str = Query(min_length=1, max_length=100),
    user: CurrentUser = None,
    limit: int = Query(8, ge=1, le=15),
) -> SuggestionsResponse:
    """Completions for a half-typed query.

    Searching on every keystroke is expensive and the results flicker;
    suggesting what to search for instead is both cheaper and easier to use.
    """
    raw = await soundcloud.query_suggestions(q, limit=limit)
    return SuggestionsResponse(queries=raw)
