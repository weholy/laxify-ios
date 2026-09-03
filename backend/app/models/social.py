from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin


class TrackComment(Base, UUIDMixin, TimestampMixin):
    """One comment on a track. `parent_id` set means it is a reply; replies
    never have replies of their own (one level, like Instagram / Telegram
    channel comments)."""

    __tablename__ = "track_comments"
    __table_args__ = (
        Index("ix_track_comments_track_time", "track_id", "created_at"),
        Index("ix_track_comments_parent", "parent_id"),
    )

    track_id: Mapped[str] = mapped_column(String(64), index=True)
    author_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    parent_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("track_comments.id", ondelete="CASCADE"), default=None
    )

    # Any one of these carries the comment: text, an uploaded photo/clip, or a GIF.
    body: Mapped[str | None] = mapped_column(Text, default=None)
    media_url: Mapped[str | None] = mapped_column(Text, default=None)
    gif_url: Mapped[str | None] = mapped_column(Text, default=None)

    # Denormalised so a listing does not need a count per row.
    like_count: Mapped[int] = mapped_column(Integer, default=0)
    dislike_count: Mapped[int] = mapped_column(Integer, default=0)

    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    author = relationship("User", lazy="joined")
    reactions: Mapped[list["CommentReaction"]] = relationship(
        back_populates="comment", cascade="all, delete-orphan"
    )


class CommentReaction(Base, TimestampMixin):
    """+1 like or -1 dislike, one per user per comment."""

    __tablename__ = "comment_reactions"

    comment_id: Mapped[UUID] = mapped_column(
        ForeignKey("track_comments.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    value: Mapped[int] = mapped_column(Integer)  # 1 or -1

    comment: Mapped[TrackComment] = relationship(back_populates="reactions")


class ProfileLike(Base, TimestampMixin):
    """Someone liked someone else's profile."""

    __tablename__ = "profile_likes"

    target_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True, index=True
    )
    liker_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )


class Notification(Base, UUIDMixin, TimestampMixin):
    """A row in someone's bell feed — system notices and social events."""

    __tablename__ = "notifications"
    __table_args__ = (Index("ix_notifications_user_time", "user_id", "created_at"),)

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    # system | build | month_reset | like | reply
    kind: Mapped[str] = mapped_column(String(24))
    title: Mapped[str] = mapped_column(String(160))
    body: Mapped[str] = mapped_column(Text, default="")
    actor_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), default=None
    )
    # Set only on notices an operator sent with an image attached — a social
    # notification (like/reply) always shows the actor's own avatar instead,
    # and a plain system notice falls back to the app's own mark on the
    # client. Never both at once.
    icon_url: Mapped[str | None] = mapped_column(Text, default=None)
    payload: Mapped[dict] = mapped_column(JSONB, default=dict)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    actor = relationship("User", foreign_keys=[actor_id], lazy="joined")
