import re
import secrets
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Follow, Playlist, User

USERNAME_SAFE = re.compile(r"[^a-z0-9_.]")


def slugify_username(source: str) -> str:
    base = USERNAME_SAFE.sub("", source.strip().lower().replace(" ", "_"))
    return base[:24] or "user"


async def is_username_taken(session: AsyncSession, username: str, exclude_id: UUID | None = None) -> bool:
    stmt = select(User.id).where(func.lower(User.username) == username.lower())
    if exclude_id:
        stmt = stmt.where(User.id != exclude_id)
    return (await session.execute(stmt.limit(1))).scalar_one_or_none() is not None


async def generate_unique_username(session: AsyncSession, source: str) -> str:
    """Pick a free handle derived from the Google display name/email.

    Onboarding lets the user change it, but they must never land on a
    collision or an empty field.
    """
    base = slugify_username(source)
    if not await is_username_taken(session, base):
        return base

    for _ in range(10):
        candidate = f"{base}{secrets.randbelow(9000) + 1000}"[:32]
        if not await is_username_taken(session, candidate):
            return candidate

    return f"{base[:24]}{secrets.token_hex(4)}"[:32]


async def suggest_usernames(session: AsyncSession, wanted: str, count: int = 3) -> list[str]:
    base = slugify_username(wanted)
    out: list[str] = []
    for _ in range(count * 4):
        if len(out) >= count:
            break
        candidate = f"{base}{secrets.randbelow(9000) + 1000}"[:32]
        if candidate in out:
            continue
        if not await is_username_taken(session, candidate):
            out.append(candidate)
    return out


async def profile_counts(session: AsyncSession, user_id: UUID) -> dict[str, int]:
    followers = await session.scalar(
        select(func.count()).select_from(Follow).where(Follow.following_id == user_id)
    )
    following = await session.scalar(
        select(func.count()).select_from(Follow).where(Follow.follower_id == user_id)
    )
    playlists = await session.scalar(
        select(func.count())
        .select_from(Playlist)
        .where(Playlist.owner_id == user_id, Playlist.is_public.is_(True))
    )
    return {
        "followers_count": followers or 0,
        "following_count": following or 0,
        "playlists_count": playlists or 0,
    }


async def is_following(session: AsyncSession, follower_id: UUID, following_id: UUID) -> bool:
    found = await session.scalar(
        select(Follow.follower_id).where(
            Follow.follower_id == follower_id, Follow.following_id == following_id
        )
    )
    return found is not None
