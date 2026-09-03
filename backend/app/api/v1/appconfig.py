"""What every launch asks before anything else.

Unauthenticated and cheap on purpose — this has to answer before a sign-in
attempt, before the language picker, before anything else the app might want
to do. One row read by primary key.
"""

from fastapi import APIRouter
from pydantic import BaseModel

from app.api.deps import SessionDep
from app.models import AppConfig

router = APIRouter(prefix="/app", tags=["app"])


class AppConfigOut(BaseModel):
    # Empty means "no floor" — every build is accepted. Set from Випка.
    min_supported_version: str = ""


@router.get("/config", response_model=AppConfigOut)
async def read_config(session: SessionDep) -> AppConfigOut:
    row = await session.get(AppConfig, "min_supported_version")
    return AppConfigOut(min_supported_version=row.value if row else "")
