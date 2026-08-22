from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin


class TrackSnapshot(Base, TimestampMixin):
    """Cached track metadata.

    Everything the app shows about a track (title, artist, cover, duration) is
    denormalised here so libraries, playlists and history render without a
    round trip to Yandex for every row — and still render if that source is
    unreachable.
    """

    __tablename__ = "track_snapshots"

    track_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    title: Mapped[str] = mapped_column(Text)
    artist_name: Mapped[str] = mapped_column(Text)
    artist_id: Mapped[str | None] = mapped_column(String(64), index=True, default=None)
    album_title: Mapped[str | None] = mapped_column(Text, default=None)
    album_id: Mapped[str | None] = mapped_column(String(64), index=True, default=None)
    cover_url: Mapped[str | None] = mapped_column(Text, default=None)
    duration_seconds: Mapped[float] = mapped_column(Float, default=0)
    extra: Mapped[dict] = mapped_column(JSONB, default=dict)


class Favorite(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "favorites"
    __table_args__ = (
        UniqueConstraint("user_id", "track_id", name="uq_favorite_user_track"),
        Index("ix_favorites_user_added", "user_id", "added_at"),
    )

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    track_id: Mapped[str] = mapped_column(
        ForeignKey("track_snapshots.track_id", ondelete="CASCADE")
    )
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))

    track: Mapped[TrackSnapshot] = relationship(lazy="joined")


class DislikedTrack(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "disliked_tracks"
    __table_args__ = (UniqueConstraint("user_id", "track_id", name="uq_dislike_user_track"),)

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    track_id: Mapped[str] = mapped_column(String(64))


class Playlist(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "playlists"

    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(120))
    description: Mapped[str | None] = mapped_column(String(500), default=None)
    cover_url: Mapped[str | None] = mapped_column(Text, default=None)
    is_public: Mapped[bool] = mapped_column(Boolean, default=True)
    is_collaborative: Mapped[bool] = mapped_column(Boolean, default=False)
    # Short opaque handle used in share links, so a playlist URL never leaks
    # a sequential id or the owner's internal uuid.
    share_slug: Mapped[str] = mapped_column(String(22), unique=True, index=True)
    track_count: Mapped[int] = mapped_column(default=0)
    total_duration_seconds: Mapped[float] = mapped_column(Float, default=0)

    owner: Mapped["User"] = relationship(back_populates="playlists", foreign_keys=[owner_id])
    items: Mapped[list["PlaylistItem"]] = relationship(
        back_populates="playlist",
        cascade="all, delete-orphan",
        order_by="PlaylistItem.position",
    )
    collaborators: Mapped[list["PlaylistCollaborator"]] = relationship(
        back_populates="playlist", cascade="all, delete-orphan"
    )


class PlaylistItem(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "playlist_items"
    __table_args__ = (
        UniqueConstraint("playlist_id", "track_id", name="uq_playlist_track"),
        Index("ix_playlist_items_order", "playlist_id", "position"),
    )

    playlist_id: Mapped[UUID] = mapped_column(
        ForeignKey("playlists.id", ondelete="CASCADE"), index=True
    )
    track_id: Mapped[str] = mapped_column(
        ForeignKey("track_snapshots.track_id", ondelete="CASCADE")
    )
    # Sparse ordering (steps of 1000) so a drag-and-drop reorder rewrites one
    # row instead of renumbering the whole playlist.
    position: Mapped[int] = mapped_column(BigInteger)
    added_by_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )

    playlist: Mapped[Playlist] = relationship(back_populates="items")
    track: Mapped[TrackSnapshot] = relationship(lazy="joined")


class PlaylistCollaborator(Base, TimestampMixin):
    __tablename__ = "playlist_collaborators"

    playlist_id: Mapped[UUID] = mapped_column(
        ForeignKey("playlists.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    can_edit: Mapped[bool] = mapped_column(Boolean, default=True)

    playlist: Mapped[Playlist] = relationship(back_populates="collaborators")


class PlaylistInvite(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "playlist_invites"

    playlist_id: Mapped[UUID] = mapped_column(
        ForeignKey("playlists.id", ondelete="CASCADE"), index=True
    )
    code: Mapped[str] = mapped_column(String(22), unique=True, index=True)
    created_by_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    max_uses: Mapped[int | None] = mapped_column(default=None)
    use_count: Mapped[int] = mapped_column(default=0)
