from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

from app.schemas.common import ORMModel


class CommentAuthor(ORMModel):
    id: UUID
    username: str
    display_name: str
    avatar_url: str | None = None


class CommentOut(BaseModel):
    id: UUID
    parent_id: UUID | None
    author: CommentAuthor
    body: str | None
    media_url: str | None
    gif_url: str | None
    like_count: int
    dislike_count: int
    my_reaction: Literal["like", "dislike", "none"] = "none"
    created_at: datetime
    replies: list["CommentOut"] = Field(default_factory=list)
    reply_count: int = 0
    can_delete: bool = False


class CommentCreate(BaseModel):
    body: str | None = Field(default=None, max_length=2000)
    parent_id: UUID | None = None
    media_url: str | None = Field(default=None, max_length=1000)
    gif_url: str | None = Field(default=None, max_length=1000)


class ReactionIn(BaseModel):
    value: Literal["like", "dislike", "none"]


class MediaUploadOut(BaseModel):
    url: str


class GifItemOut(BaseModel):
    id: str
    url: str
    preview_url: str


class NotificationOut(ORMModel):
    id: UUID
    kind: str
    title: str
    body: str
    actor_avatar_url: str | None = None
    actor_username: str | None = None
    icon_url: str | None = None
    payload: dict = Field(default_factory=dict)
    is_read: bool
    created_at: datetime


class UnreadCountOut(BaseModel):
    count: int


class ProfileLikeOut(BaseModel):
    liked_by_me: bool
    like_count: int | None = None


class TelegramLinkIn(BaseModel):
    payload: dict[str, str]


class GoogleLinkIn(BaseModel):
    id_token: str
