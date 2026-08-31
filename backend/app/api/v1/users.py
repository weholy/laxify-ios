from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError

from app.api.deps import CurrentDeviceId, CurrentUser, OptionalUser, SessionDep
from app.models import Device, Follow, User
from app.schemas.common import MessageOut, Page
from app.schemas.user import (
    DeviceOut,
    OnboardingRequest,
    UsernameAvailability,
    UserProfileOut,
    UserUpdate,
    UserWithCounts,
)
from app.services.reserved_usernames import is_reserved
from app.services.users import (
    is_following,
    is_username_taken,
    profile_counts,
    suggest_usernames,
)

router = APIRouter(tags=["users"])


@router.get("/me", response_model=UserProfileOut)
async def read_me(user: CurrentUser) -> User:
    return user


@router.patch("/me", response_model=UserProfileOut)
async def update_me(payload: UserUpdate, user: CurrentUser, session: SessionDep) -> User:
    data = payload.model_dump(exclude_unset=True)

    if "username" in data and data["username"] != user.username:
        if await is_username_taken(session, data["username"], exclude_id=user.id):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=(
                    "Этот юзернейм зарезервирован"
                    if is_reserved(data["username"])
                    else "Этот юзернейм уже занят"
                ),
            )

    if "settings" in data and data["settings"] is not None:
        # Merge rather than replace: a client on an older build must not wipe
        # settings keys it doesn't know about yet.
        user.settings = {**(user.settings or {}), **data.pop("settings")}

    for field, value in data.items():
        setattr(user, field, value)

    try:
        await session.flush()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Этот юзернейм уже занят"
        ) from exc

    return user


@router.post("/me/onboarding", response_model=UserProfileOut)
async def complete_onboarding(
    payload: OnboardingRequest, user: CurrentUser, session: SessionDep
) -> User:
    if await is_username_taken(session, payload.username, exclude_id=user.id):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                "Этот юзернейм зарезервирован"
                if is_reserved(payload.username)
                else "Этот юзернейм уже занят"
            ),
        )

    user.display_name = payload.display_name
    user.username = payload.username
    if payload.avatar_url:
        user.avatar_url = payload.avatar_url
    user.has_completed_onboarding = True

    try:
        await session.flush()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Этот юзернейм уже занят"
        ) from exc

    return user


@router.get("/users/username-available", response_model=UsernameAvailability)
async def check_username(
    session: SessionDep,
    viewer: OptionalUser,
    username: str = Query(min_length=2, max_length=32),
) -> UsernameAvailability:
    """Is this handle free — for the person asking?

    The caller's own handle has to come back as available. Onboarding shows
    the auto-generated one already filled in, so without this exclusion the
    very first thing a new account is told is that its own name is taken.
    """
    normalised = username.strip().lower()
    taken = await is_username_taken(
        session, normalised, exclude_id=viewer.id if viewer else None
    )
    return UsernameAvailability(
        username=normalised,
        available=not taken,
        reason=(
            None
            if not taken
            else "Этот юзернейм зарезервирован"
            if is_reserved(normalised)
            else "Этот юзернейм уже занят"
        ),
        suggestions=await suggest_usernames(session, normalised) if taken else [],
    )


@router.get("/users/search", response_model=Page[UserWithCounts])
async def search_users(
    session: SessionDep,
    viewer: OptionalUser,
    q: str = Query(min_length=1, max_length=64),
    limit: int = Query(20, ge=1, le=50),
    offset: int = Query(0, ge=0),
) -> Page[UserWithCounts]:
    pattern = f"%{q.strip().lower()}%"
    conditions = [
        User.is_profile_public.is_(True),
        User.is_banned.is_(False),
        or_(func.lower(User.username).like(pattern), func.lower(User.display_name).like(pattern)),
    ]

    total = await session.scalar(select(func.count()).select_from(User).where(*conditions)) or 0
    rows = (
        await session.scalars(
            select(User).where(*conditions).order_by(User.username).limit(limit).offset(offset)
        )
    ).all()

    items = []
    for row in rows:
        counts = await profile_counts(session, row.id)
        items.append(
            UserWithCounts(
                **UserWithCounts.model_validate(row).model_dump(
                    exclude=set(counts) | {"is_following"}
                ),
                **counts,
                is_following=(
                    await is_following(session, viewer.id, row.id) if viewer else False
                ),
            )
        )

    return Page(items=items, total=total, limit=limit, offset=offset)


@router.get("/users/{username}", response_model=UserWithCounts)
async def read_user(username: str, session: SessionDep, viewer: OptionalUser) -> UserWithCounts:
    target = await session.scalar(
        select(User).where(func.lower(User.username) == username.strip().lower())
    )
    if target is None or target.is_banned:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")

    is_self = viewer is not None and viewer.id == target.id
    if not target.is_profile_public and not is_self:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Профиль закрыт")

    counts = await profile_counts(session, target.id)
    return UserWithCounts(
        **UserWithCounts.model_validate(target).model_dump(exclude=set(counts) | {"is_following"}),
        **counts,
        is_following=(await is_following(session, viewer.id, target.id) if viewer else False),
    )


@router.post("/users/{user_id}/follow", response_model=MessageOut)
async def follow_user(user_id: UUID, user: CurrentUser, session: SessionDep) -> MessageOut:
    if user_id == user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Нельзя подписаться на себя"
        )

    target = await session.get(User, user_id)
    if target is None or target.is_banned:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Пользователь не найден")

    if not await is_following(session, user.id, user_id):
        session.add(Follow(follower_id=user.id, following_id=user_id))

    return MessageOut(detail="Вы подписались")


@router.delete("/users/{user_id}/follow", response_model=MessageOut)
async def unfollow_user(user_id: UUID, user: CurrentUser, session: SessionDep) -> MessageOut:
    link = await session.get(Follow, {"follower_id": user.id, "following_id": user_id})
    if link is not None:
        await session.delete(link)
    return MessageOut(detail="Вы отписались")


@router.get("/me/devices", response_model=list[DeviceOut])
async def list_devices(
    user: CurrentUser, session: SessionDep, current_device_id: CurrentDeviceId
) -> list[DeviceOut]:
    devices = (
        await session.scalars(
            select(Device)
            .where(Device.user_id == user.id, Device.revoked_at.is_(None))
            .order_by(Device.last_used_at.desc().nullslast())
        )
    ).all()
    return [
        DeviceOut(
            **DeviceOut.model_validate(device).model_dump(exclude={"is_current"}),
            is_current=device.id == current_device_id,
        )
        for device in devices
    ]


@router.delete("/me/devices/{device_id}", response_model=MessageOut)
async def revoke_device(device_id: UUID, user: CurrentUser, session: SessionDep) -> MessageOut:
    device = await session.get(Device, device_id)
    if device is None or device.user_id != user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Устройство не найдено")
    device.revoked_at = datetime.now(UTC)
    return MessageOut(detail="Устройство отключено")
