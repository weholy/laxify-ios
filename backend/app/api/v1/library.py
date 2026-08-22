from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import delete, func, select
from sqlalchemy.orm import selectinload

from app.api.deps import CurrentUser, SessionDep
from app.models import DislikedTrack, Favorite
from app.schemas.common import MessageOut, Page
from app.schemas.library import DislikeIn, FavoriteAdd, FavoriteBulkAdd, FavoriteOut
from app.services.tracks import upsert_track, upsert_tracks

router = APIRouter(prefix="/me", tags=["library"])


@router.get("/favorites", response_model=Page[FavoriteOut])
async def list_favorites(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> Page[FavoriteOut]:
    total = (
        await session.scalar(
            select(func.count()).select_from(Favorite).where(Favorite.user_id == user.id)
        )
        or 0
    )
    rows = (
        await session.scalars(
            select(Favorite)
            .where(Favorite.user_id == user.id)
            .options(selectinload(Favorite.track))
            .order_by(Favorite.added_at.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()
    return Page(
        items=[FavoriteOut.model_validate(row) for row in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.put("/favorites", response_model=FavoriteOut, status_code=status.HTTP_201_CREATED)
async def add_favorite(payload: FavoriteAdd, user: CurrentUser, session: SessionDep) -> Favorite:
    await upsert_track(session, payload.track)

    existing = await session.scalar(
        select(Favorite).where(
            Favorite.user_id == user.id, Favorite.track_id == payload.track.track_id
        )
    )
    if existing is not None:
        return existing

    favorite = Favorite(
        user_id=user.id,
        track_id=payload.track.track_id,
        added_at=payload.added_at or datetime.now(UTC),
    )
    session.add(favorite)
    await session.flush()
    await session.refresh(favorite, ["track"])
    return favorite


@router.post("/favorites/bulk", response_model=MessageOut)
async def add_favorites_bulk(
    payload: FavoriteBulkAdd, user: CurrentUser, session: SessionDep
) -> MessageOut:
    if not payload.items:
        return MessageOut(detail="Нечего добавлять")

    await upsert_tracks(session, [item.track for item in payload.items])

    known = set(
        (
            await session.scalars(
                select(Favorite.track_id).where(Favorite.user_id == user.id)
            )
        ).all()
    )

    added = 0
    for item in payload.items:
        if item.track.track_id in known:
            continue
        known.add(item.track.track_id)
        session.add(
            Favorite(
                user_id=user.id,
                track_id=item.track.track_id,
                added_at=item.added_at or datetime.now(UTC),
            )
        )
        added += 1

    return MessageOut(detail=f"Добавлено треков: {added}")


@router.delete("/favorites/{track_id}", response_model=MessageOut)
async def remove_favorite(track_id: str, user: CurrentUser, session: SessionDep) -> MessageOut:
    result = await session.execute(
        delete(Favorite).where(Favorite.user_id == user.id, Favorite.track_id == track_id)
    )
    if result.rowcount == 0:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Трек не в избранном")
    return MessageOut(detail="Удалено из избранного")


@router.get("/dislikes", response_model=list[str])
async def list_dislikes(user: CurrentUser, session: SessionDep) -> list[str]:
    rows = await session.scalars(
        select(DislikedTrack.track_id).where(DislikedTrack.user_id == user.id)
    )
    return list(rows.all())


@router.put("/dislikes", response_model=MessageOut)
async def add_dislike(payload: DislikeIn, user: CurrentUser, session: SessionDep) -> MessageOut:
    existing = await session.scalar(
        select(DislikedTrack).where(
            DislikedTrack.user_id == user.id, DislikedTrack.track_id == payload.track_id
        )
    )
    if existing is None:
        session.add(DislikedTrack(user_id=user.id, track_id=payload.track_id))

    # Disliking something already liked is a contradiction; drop the like.
    await session.execute(
        delete(Favorite).where(Favorite.user_id == user.id, Favorite.track_id == payload.track_id)
    )
    return MessageOut(detail="Трек больше не будет рекомендоваться")


@router.delete("/dislikes/{track_id}", response_model=MessageOut)
async def remove_dislike(track_id: str, user: CurrentUser, session: SessionDep) -> MessageOut:
    await session.execute(
        delete(DislikedTrack).where(
            DislikedTrack.user_id == user.id, DislikedTrack.track_id == track_id
        )
    )
    return MessageOut(detail="Отметка снята")
