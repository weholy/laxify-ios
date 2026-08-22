from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.schemas.common import ORMModel

USERNAME_PATTERN = r"^[a-z0-9_](?:[a-z0-9_.]{1,30})$"


class UserPublic(ORMModel):
    id: UUID
    username: str
    display_name: str
    avatar_url: str | None = None
    google_avatar_url: str | None = None
    bio: str | None = None
    is_profile_public: bool
    created_at: datetime


class UserProfileOut(UserPublic):
    email: str
    birthdate: date | None = None
    is_stats_public: bool
    has_completed_onboarding: bool
    settings: dict = Field(default_factory=dict)
    is_admin: bool = False


class UserWithCounts(UserPublic):
    followers_count: int = 0
    following_count: int = 0
    playlists_count: int = 0
    is_following: bool = False


class UserUpdate(BaseModel):
    display_name: str | None = Field(default=None, min_length=1, max_length=80)
    username: str | None = Field(default=None, min_length=2, max_length=32)
    bio: str | None = Field(default=None, max_length=160)
    birthdate: date | None = None
    avatar_url: str | None = None
    is_profile_public: bool | None = None
    is_stats_public: bool | None = None
    settings: dict | None = None

    @field_validator("username")
    @classmethod
    def normalise_username(cls, value: str | None) -> str | None:
        if value is None:
            return None
        lowered = value.strip().lower()
        import re

        if not re.match(USERNAME_PATTERN, lowered):
            raise ValueError(
                "Юзернейм может содержать только латиницу, цифры, точку и подчёркивание"
            )
        return lowered


class OnboardingRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=80)
    username: str = Field(min_length=2, max_length=32)
    birthdate: date | None = None
    avatar_url: str | None = None

    @field_validator("username")
    @classmethod
    def normalise_username(cls, value: str) -> str:
        lowered = value.strip().lower()
        import re

        if not re.match(USERNAME_PATTERN, lowered):
            raise ValueError(
                "Юзернейм может содержать только латиницу, цифры, точку и подчёркивание"
            )
        return lowered


class UsernameAvailability(BaseModel):
    username: str
    available: bool
    reason: str | None = None
    suggestions: list[str] = Field(default_factory=list)


class DeviceOut(ORMModel):
    id: UUID
    name: str
    model: str | None
    app_version: str | None
    last_used_at: datetime | None
    created_at: datetime
    is_current: bool = False
