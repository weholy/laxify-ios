from fastapi import APIRouter

from app.api.v1 import (
    activity,
    admin,
    auth,
    catalog,
    diagnostics,
    discover,
    email_auth,
    library,
    lyrics,
    music,
    playlists,
    replay,
    telemetry,
    users,
    wave,
)

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(email_auth.router)
api_router.include_router(users.router)
api_router.include_router(library.router)
api_router.include_router(lyrics.router)
api_router.include_router(playlists.router)
api_router.include_router(activity.router)
api_router.include_router(replay.router)
api_router.include_router(music.router)
api_router.include_router(admin.router)
api_router.include_router(diagnostics.router)
api_router.include_router(telemetry.router)
api_router.include_router(catalog.router)
api_router.include_router(discover.router)
api_router.include_router(wave.router)
