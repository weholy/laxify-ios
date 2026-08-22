from datetime import date, datetime

from pydantic import BaseModel, Field

from app.schemas.common import ORMModel, TrackIn, TrackOut


class PlaybackEventIn(BaseModel):
    track: TrackIn
    played_at: datetime
    seconds_played: float = Field(ge=0)
    completed: bool = False
    source: str | None = Field(default=None, max_length=32)


class PlaybackBatchIn(BaseModel):
    """Play events are sent in batches — a phone that was offline should be
    able to flush a backlog in one request instead of hundreds."""

    events: list[PlaybackEventIn] = Field(min_length=1, max_length=500)


class TopArtistOut(BaseModel):
    artist_id: str | None
    artist_name: str
    seconds: float
    play_count: int


class TopTrackOut(BaseModel):
    track: TrackOut
    seconds: float
    play_count: int


class StatsOut(ORMModel):
    total_seconds: float
    total_tracks: int
    current_streak_days: int
    longest_streak_days: int
    last_listened_day: date | None
    top_artists: list[TopArtistOut] = Field(default_factory=list)
    top_tracks: list[TopTrackOut] = Field(default_factory=list)


class SearchHistoryIn(BaseModel):
    entity_id: str = Field(max_length=64)
    kind: str = Field(pattern="^(track|artist|album|playlist)$")
    title: str
    subtitle: str | None = None
    cover_url: str | None = None
    searched_at: datetime | None = None


class SearchHistoryOut(ORMModel):
    entity_id: str
    kind: str
    title: str
    subtitle: str | None
    cover_url: str | None
    searched_at: datetime


class DownloadIn(BaseModel):
    track: TrackIn
    size_bytes: int | None = Field(default=None, ge=0)


class DownloadOut(ORMModel):
    track: TrackOut
    size_bytes: int | None
    created_at: datetime


class LocalMigrationIn(BaseModel):
    """One-shot import of whatever the app had stored locally before sign-in."""

    favorites: list[dict] = Field(default_factory=list, max_length=5000)
    disliked_track_ids: list[str] = Field(default_factory=list, max_length=5000)
    search_history: list[SearchHistoryIn] = Field(default_factory=list, max_length=500)
    total_seconds_listened: float = Field(default=0, ge=0)


class MigrationResultOut(BaseModel):
    favorites_imported: int
    dislikes_imported: int
    search_history_imported: int
    seconds_merged: float
