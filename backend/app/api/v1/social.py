from uuid import UUID

from fastapi import APIRouter, HTTPException
from sqlalchemy import func, select

from app.api.deps import CurrentUser, OptionalUser, SessionDep
from app.models import Notification, ProfileLike, User
from app.schemas.common import MessageOut
from app.schemas.social import ProfileLikeOut

router = APIRouter(prefix="/users", tags=["social"])


async def _count(session, target_id: UUID) -> int:
    return await session.scalar(
        select(func.count()).select_from(ProfileLike).where(ProfileLike.target_id == target_id)
    ) or 0


def _visible_count(target: User, viewer_id: UUID | None, count: int) -> int | None:
    if target.hide_profile_likes and viewer_id != target.id:
        return None
    return count


@router.get("/{user_id}/likes", response_model=ProfileLikeOut)
async def profile_likes(user_id: UUID, session: SessionDep, viewer: OptionalUser) -> ProfileLikeOut:
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="Пользователь не найден")

    viewer_id = viewer.id if viewer else None
    liked = False
    if viewer_id:
        liked = (
            await session.get(ProfileLike, {"target_id": user_id, "liker_id": viewer_id})
        ) is not None

    return ProfileLikeOut(
        liked_by_me=liked,
        like_count=_visible_count(target, viewer_id, await _count(session, user_id)),
    )


@router.post("/{user_id}/like", response_model=ProfileLikeOut)
async def like_profile(user_id: UUID, session: SessionDep, user: CurrentUser) -> ProfileLikeOut:
    if user_id == user.id:
        raise HTTPException(status_code=400, detail="Нельзя лайкнуть свой профиль")
    target = await session.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=404, detail="Пользователь не найден")

    existing = await session.get(ProfileLike, {"target_id": user_id, "liker_id": user.id})
    if existing is None:
        session.add(ProfileLike(target_id=user_id, liker_id=user.id))
        session.add(
            Notification(
                user_id=user_id,
                kind="like",
                title="Вам поставили лайк",
                body=f"@{user.username} лайкнул ваш профиль",
                actor_id=user.id,
                payload={"user_id": str(user.id)},
            )
        )
        await session.commit()

    return ProfileLikeOut(
        liked_by_me=True,
        like_count=_visible_count(target, user.id, await _count(session, user_id)),
    )


@router.delete("/{user_id}/like", response_model=ProfileLikeOut)
async def unlike_profile(user_id: UUID, session: SessionDep, user: CurrentUser) -> ProfileLikeOut:
    existing = await session.get(ProfileLike, {"target_id": user_id, "liker_id": user.id})
    if existing is not None:
        await session.delete(existing)
        await session.commit()

    target = await session.get(User, user_id)
    count = await _count(session, user_id)
    return ProfileLikeOut(
        liked_by_me=False,
        like_count=_visible_count(target, user.id, count) if target else count,
    )


@router.post("/me/hide-likes", response_model=MessageOut)
async def set_hide_likes(session: SessionDep, user: CurrentUser, hidden: bool = True) -> MessageOut:
    user.hide_profile_likes = hidden
    await session.commit()
    return MessageOut(detail="Сохранено")
