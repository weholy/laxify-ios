from datetime import date, datetime
from uuid import UUID

from sqlalchemy import (
    Boolean,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, UUIDMixin


class ListeningEvent(Base, UUIDMixin):
    """Append-only play log — the raw material for stats and recommendations."""

    __tablename__ = "listening_events"
    __table_args__ = (
        Index("ix_listening_user_time", "user_id", "played_at"),
        Index("ix_listening_track", "track_id"),
    )

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    track_id: Mapped[str] = mapped_column(String(64))
    artist_id: Mapped[str | None] = mapped_column(String(64), index=True, default=None)
    played_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # How much was actually heard, not the track length: a skip after three
    # seconds must not count the same as a full listen.
    seconds_played: Mapped[float] = mapped_column(Float, default=0)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    source: Mapped[str | None] = mapped_column(String(32), default=None)


class ListeningStat(Base, TimestampMixin):
    """Rolled-up totals, so the profile screen never scans the whole event log."""

    __tablename__ = "listening_stats"

    user_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    total_seconds: Mapped[float] = mapped_column(Float, default=0)
    total_tracks: Mapped[int] = mapped_column(Integer, default=0)
    current_streak_days: Mapped[int] = mapped_column(Integer, default=0)
    longest_streak_days: Mapped[int] = mapped_column(Integer, default=0)
    last_listened_day: Mapped[date | None] = mapped_column(Date, default=None)
    top_artists: Mapped[list] = mapped_column(JSONB, default=list)
    top_tracks: Mapped[list] = mapped_column(JSONB, default=list)


class SearchHistoryEntry(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "search_history"
    __table_args__ = (
        UniqueConstraint("user_id", "entity_id", name="uq_search_user_entity"),
    )

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    entity_id: Mapped[str] = mapped_column(String(64))
    kind: Mapped[str] = mapped_column(String(16))
    title: Mapped[str] = mapped_column(Text)
    subtitle: Mapped[str | None] = mapped_column(Text, default=None)
    cover_url: Mapped[str | None] = mapped_column(Text, default=None)
    searched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Download(Base, UUIDMixin, TimestampMixin):
    """Server-side record of offline saves, so the set follows the account."""

    __tablename__ = "downloads"
    __table_args__ = (UniqueConstraint("user_id", "track_id", name="uq_download_user_track"),)

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    track_id: Mapped[str] = mapped_column(
        ForeignKey("track_snapshots.track_id", ondelete="CASCADE")
    )
    device_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="SET NULL"), default=None
    )
    size_bytes: Mapped[int | None] = mapped_column(default=None)


class YandexToken(Base, UUIDMixin, TimestampMixin):
    """Pool of upstream credentials.

    Kept as rows rather than a single env value so tokens can be added,
    disabled or rotated without redeploying, and so a token that starts
    failing can be parked automatically.
    """

    __tablename__ = "yandex_tokens"

    label: Mapped[str] = mapped_column(String(64))
    token: Mapped[str] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    failure_count: Mapped[int] = mapped_column(Integer, default=0)
    last_error: Mapped[str | None] = mapped_column(Text, default=None)
    disabled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)


class AuditLog(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "audit_log"
    __table_args__ = (Index("ix_audit_actor_time", "actor_id", "created_at"),)

    actor_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    action: Mapped[str] = mapped_column(String(64))
    target_type: Mapped[str | None] = mapped_column(String(32), default=None)
    target_id: Mapped[str | None] = mapped_column(String(64), default=None)
    payload: Mapped[dict] = mapped_column(JSONB, default=dict)
    ip: Mapped[str | None] = mapped_column(String(64), default=None)
