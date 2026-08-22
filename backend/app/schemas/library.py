from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from app.schemas.common import ORMModel, TrackIn, TrackOut
from app.schemas.user import UserPublic


class FavoriteOut(ORMModel):
    track: TrackOut
    added_at: datetime


class FavoriteAdd(BaseModel):
    track: TrackIn
    added_at: datetime | None = None


class FavoriteBulkAdd(BaseModel):
    items: list[FavoriteAdd] = Field(max_length=2000)


class PlaylistOut(ORMModel):
    id: UUID
    title: str
    description: str | None
    cover_url: str | None
    is_public: bool
    is_collaborative: bool
    share_slug: str
    track_count: int
    total_duration_seconds: float
    created_at: datetime
    updated_at: datetime
    owner: UserPublic | None = None


class PlaylistItemOut(ORMModel):
    id: UUID
    track: TrackOut
    position: int
    added_by_id: UUID | None
    created_at: datetime


class PlaylistDetailOut(PlaylistOut):
    items: list[PlaylistItemOut] = Field(default_factory=list)
    collaborators: list[UserPublic] = Field(default_factory=list)
    can_edit: bool = False


class PlaylistCreate(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    cover_url: str | None = None
    is_public: bool = True
    is_collaborative: bool = False
    tracks: list[TrackIn] = Field(default_factory=list, max_length=1000)


class PlaylistUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    cover_url: str | None = None
    is_public: bool | None = None
    is_collaborative: bool | None = None


class PlaylistTracksAdd(BaseModel):
    tracks: list[TrackIn] = Field(min_length=1, max_length=500)
    position: int | None = Field(
        default=None, description="Куда вставить; по умолчанию — в конец"
    )


class PlaylistReorder(BaseModel):
    track_id: str
    new_index: int = Field(ge=0)


class InviteOut(ORMModel):
    code: str
    expires_at: datetime | None
    max_uses: int | None
    use_count: int


class InviteCreate(BaseModel):
    expires_in_hours: int | None = Field(default=None, ge=1, le=24 * 30)
    max_uses: int | None = Field(default=None, ge=1, le=1000)


class DislikeIn(BaseModel):
    track_id: str = Field(max_length=64)
