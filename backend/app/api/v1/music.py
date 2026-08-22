from typing import Any

from fastapi import APIRouter, HTTPException, Query, status

from app.api.deps import CurrentUser, SessionDep
from app.core.config import settings
from app.schemas.common import TrackIn
from app.services.recommendations import rank_candidates, seed_artists
from app.services.yandex import MusicUpstreamError, RegionBlockedError
from app.services.yandex import request as upstream

router = APIRouter(prefix="/music", tags=["music"])


def _proxy_guard() -> None:
    if not settings.music_proxy_enabled:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Загрузка музыки через сервер сейчас отключена",
        )


async def _call(session, method: str, path: str, **kwargs) -> Any:
    _proxy_guard()
    try:
        return await upstream(session, method, path, **kwargs)
    except RegionBlockedError as exc:
        raise HTTPException(
            status_code=status.HTTP_451_UNAVAILABLE_FOR_LEGAL_REASONS, detail=str(exc)
        ) from exc
    except MusicUpstreamError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY, detail=str(exc)
        ) from exc


@router.get("/status")
async def proxy_status() -> dict[str, Any]:
    """Lets the app discover whether it should route music through the server
    or go direct, without shipping a new build to flip the behaviour."""
    return {
        "proxy_enabled": settings.music_proxy_enabled,
        "direct_fallback": not settings.music_proxy_enabled,
    }


@router.get("/search")
async def search(
    session: SessionDep,
    user: CurrentUser,
    q: str = Query(min_length=1, max_length=200),
    page: int = Query(0, ge=0),
) -> Any:
    return await _call(
        session,
        "GET",
        "/search",
        params={"text": q, "type": "all", "page": page, "nocorrect": "false"},
    )


@router.get("/tracks/{track_id}")
async def track(track_id: str, session: SessionDep, user: CurrentUser) -> Any:
    return await _call(session, "GET", "/tracks", params={"track-ids": track_id})


@router.get("/tracks/{track_id}/stream")
async def track_stream(track_id: str, session: SessionDep, user: CurrentUser) -> Any:
    return await _call(session, "GET", f"/tracks/{track_id}/download-info")


@router.get("/artists/{artist_id}")
async def artist(artist_id: str, session: SessionDep, user: CurrentUser) -> Any:
    return await _call(session, "GET", "/artists", params={"artist-ids": artist_id})


@router.get("/artists/{artist_id}/tracks")
async def artist_tracks(
    artist_id: str,
    session: SessionDep,
    user: CurrentUser,
    page: int = Query(0, ge=0),
    page_size: int = Query(50, ge=1, le=100),
) -> Any:
    return await _call(
        session,
        "GET",
        f"/artists/{artist_id}/tracks",
        params={"page": page, "page-size": page_size},
    )


@router.get("/albums/{album_id}")
async def album(album_id: str, session: SessionDep, user: CurrentUser) -> Any:
    return await _call(session, "GET", f"/albums/{album_id}/with-tracks")


@router.post("/wave")
async def personalised_wave(
    candidates: list[TrackIn],
    session: SessionDep,
    user: CurrentUser,
    limit: int = Query(40, ge=1, le=100),
) -> dict[str, Any]:
    """Rank a client-supplied candidate pool against the user's taste profile.

    Ranking lives on the server even while fetching stays on the device, so
    the wave already reflects listening history from every device — and it
    starts working through the proxy later without a client change.
    """
    ranked = await rank_candidates(
        session, user.id, [track.model_dump() for track in candidates]
    )
    return {
        "items": ranked[:limit],
        "seed_artist_ids": await seed_artists(session, user.id),
    }


@router.get("/wave/seeds")
async def wave_seeds(session: SessionDep, user: CurrentUser) -> dict[str, Any]:
    return {"seed_artist_ids": await seed_artists(session, user.id)}
