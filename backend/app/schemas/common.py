from datetime import datetime
from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

T = TypeVar("T")


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class Page(BaseModel, Generic[T]):
    items: list[T]
    total: int
    limit: int
    offset: int

    @property
    def has_more(self) -> bool:
        return self.offset + len(self.items) < self.total


class TrackOut(ORMModel):
    track_id: str
    title: str
    artist_name: str
    artist_id: str | None = None
    album_title: str | None = None
    album_id: str | None = None
    cover_url: str | None = None
    duration_seconds: float = 0


class TrackIn(BaseModel):
    """Client-supplied track metadata, cached server-side on first sight."""

    track_id: str = Field(max_length=64)
    title: str
    artist_name: str
    artist_id: str | None = Field(default=None, max_length=64)
    album_title: str | None = None
    album_id: str | None = Field(default=None, max_length=64)
    cover_url: str | None = None
    duration_seconds: float = 0


class MessageOut(BaseModel):
    detail: str


class TimestampedOut(ORMModel):
    created_at: datetime
    updated_at: datetime
