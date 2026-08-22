from datetime import date, datetime
from uuid import UUID

from sqlalchemy import Boolean, Date, DateTime, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin


class User(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "users"

    google_sub: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    email: Mapped[str] = mapped_column(String(320), index=True)
    display_name: Mapped[str] = mapped_column(String(80))
    # Always stored lowercased, so the plain unique index gives
    # case-insensitive handles for free.
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    avatar_url: Mapped[str | None] = mapped_column(Text, default=None)
    google_avatar_url: Mapped[str | None] = mapped_column(Text, default=None)
    birthdate: Mapped[date | None] = mapped_column(Date, default=None)
    bio: Mapped[str | None] = mapped_column(String(160), default=None)

    is_profile_public: Mapped[bool] = mapped_column(Boolean, default=True)
    is_stats_public: Mapped[bool] = mapped_column(Boolean, default=False)

    # Email/password is a second way in, added so the app works where
    # Google's sign-in is unreachable. Google accounts start with no password.
    email_verified: Mapped[bool] = mapped_column(Boolean, default=False)
    password_hash: Mapped[str | None] = mapped_column(String(256), default=None)

    is_admin: Mapped[bool] = mapped_column(Boolean, default=False)
    is_banned: Mapped[bool] = mapped_column(Boolean, default=False)
    ban_reason: Mapped[str | None] = mapped_column(Text, default=None)

    settings: Mapped[dict] = mapped_column(JSONB, default=dict)
    has_completed_onboarding: Mapped[bool] = mapped_column(Boolean, default=False)
    has_migrated_local_data: Mapped[bool] = mapped_column(Boolean, default=False)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    devices: Mapped[list["Device"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    playlists: Mapped[list["Playlist"]] = relationship(
        back_populates="owner", cascade="all, delete-orphan", foreign_keys="Playlist.owner_id"
    )


class Device(Base, UUIDMixin, TimestampMixin):
    """One row per signed-in device, so sessions can be listed and revoked."""

    __tablename__ = "devices"

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(120), default="iPhone")
    model: Mapped[str | None] = mapped_column(String(80), default=None)
    app_version: Mapped[str | None] = mapped_column(String(32), default=None)
    # Only a hash is stored: a database leak must not hand out live sessions.
    refresh_token_hash: Mapped[str] = mapped_column(String(128), index=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    user: Mapped[User] = relationship(back_populates="devices")


class PushToken(Base, UUIDMixin, TimestampMixin):
    __tablename__ = "push_tokens"
    __table_args__ = (UniqueConstraint("user_id", "token", name="uq_push_user_token"),)

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    device_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("devices.id", ondelete="CASCADE"), default=None
    )
    token: Mapped[str] = mapped_column(String(200))
    is_sandbox: Mapped[bool] = mapped_column(Boolean, default=True)
    failed_count: Mapped[int] = mapped_column(default=0)


class Follow(Base, TimestampMixin):
    __tablename__ = "follows"

    follower_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    following_id: Mapped[UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )


class EmailVerification(Base, UUIDMixin, TimestampMixin):
    """One outstanding email code.

    Only the hash of the code is stored: a database leak must not hand out
    working verification codes. Attempts are counted so a four-digit code
    cannot be brute-forced.
    """

    __tablename__ = "email_verifications"

    user_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), default=None, index=True
    )
    email: Mapped[str] = mapped_column(String(320), index=True)
    purpose: Mapped[str] = mapped_column(String(24))
    code_hash: Mapped[str] = mapped_column(String(128))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    attempts: Mapped[int] = mapped_column(default=0)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
