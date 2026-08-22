from fastapi import APIRouter

from app.api.v1 import activity, admin, auth, library, music, playlists, users

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(users.router)
api_router.include_router(library.router)
api_router.include_router(playlists.router)
api_router.include_router(activity.router)
api_router.include_router(music.router)
api_router.include_router(admin.router)
