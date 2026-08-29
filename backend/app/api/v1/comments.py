from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, UploadFile, status
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

from app.api.deps import CurrentUser, OptionalUser, SessionDep
from app.models import CommentReaction, Notification, TrackComment
from app.schemas.common import MessageOut
from app.schemas.social import (
    CommentAuthor,
    CommentCreate,
    CommentOut,
    MediaUploadOut,
    ReactionIn,
)
from app.services.media import MediaUploadError, upload_media

router = APIRouter(tags=["comments"])

_REPLY_PREVIEW = 3


def _serialise(comment: TrackComment, my_value: int, viewer_id: UUID | None) -> CommentOut:
    reaction = {1: "like", -1: "dislike"}.get(my_value, "none")
    return CommentOut(
        id=comment.id,
        parent_id=comment.parent_id,
        author=CommentAuthor.model_validate(comment.author),
        body=None if comment.deleted_at else comment.body,
        media_url=None if comment.deleted_at else comment.media_url,
        gif_url=None if comment.deleted_at else comment.gif_url,
        like_count=comment.like_count,
        dislike_count=comment.dislike_count,
        my_reaction=reaction,
        created_at=comment.created_at,
        can_delete=viewer_id is not None and comment.author_id == viewer_id,
    )


async def _my_reactions(session, comment_ids: list[UUID], user_id: UUID | None) -> dict[UUID, int]:
    if not user_id or not comment_ids:
        return {}
    rows = await session.execute(
        select(CommentReaction.comment_id, CommentReaction.value).where(
            CommentReaction.user_id == user_id,
            CommentReaction.comment_id.in_(comment_ids),
        )
    )
    return {cid: val for cid, val in rows.all()}


@router.get("/tracks/{track_id}/comments", response_model=list[CommentOut])
async def list_comments(
    track_id: str,
    session: SessionDep,
    viewer: OptionalUser,
    limit: int = Query(30, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> list[CommentOut]:
    viewer_id = viewer.id if viewer else None

    top_stmt = (
        select(TrackComment)
        .where(TrackComment.track_id == track_id, TrackComment.parent_id.is_(None))
        .options(selectinload(TrackComment.author))
        .order_by(TrackComment.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    top = (await session.scalars(top_stmt)).all()
    if not top:
        return []

    top_ids = [c.id for c in top]

    reply_rows = (
        await session.scalars(
            select(TrackComment)
            .where(TrackComment.parent_id.in_(top_ids))
            .options(selectinload(TrackComment.author))
            .order_by(TrackComment.created_at.asc())
        )
    ).all()
    replies_by_parent: dict[UUID, list[TrackComment]] = {}
    for reply in reply_rows:
        replies_by_parent.setdefault(reply.parent_id, []).append(reply)

    all_ids = top_ids + [r.id for r in reply_rows]
    mine = await _my_reactions(session, all_ids, viewer_id)

    out: list[CommentOut] = []
    for comment in top:
        node = _serialise(comment, mine.get(comment.id, 0), viewer_id)
        kids = replies_by_parent.get(comment.id, [])
        node.reply_count = len(kids)
        node.replies = [
            _serialise(reply, mine.get(reply.id, 0), viewer_id)
            for reply in kids[:_REPLY_PREVIEW]
        ]
        out.append(node)
    return out


@router.post("/tracks/{track_id}/comments", response_model=CommentOut, status_code=201)
async def add_comment(
    track_id: str, payload: CommentCreate, session: SessionDep, user: CurrentUser
) -> CommentOut:
    if not (payload.body and payload.body.strip()) and not payload.media_url and not payload.gif_url:
        raise HTTPException(status_code=422, detail="Комментарий пустой")

    parent: TrackComment | None = None
    if payload.parent_id is not None:
        parent = await session.get(TrackComment, payload.parent_id)
        if parent is None or parent.track_id != track_id:
            raise HTTPException(status_code=404, detail="Комментарий не найден")
        # One level only — a reply to a reply attaches to the top comment.
        if parent.parent_id is not None:
            parent = await session.get(TrackComment, parent.parent_id)

    comment = TrackComment(
        track_id=track_id,
        author_id=user.id,
        parent_id=parent.id if parent else None,
        body=(payload.body or "").strip() or None,
        media_url=payload.media_url,
        gif_url=payload.gif_url,
    )
    session.add(comment)
    await session.flush()

    if parent is not None and parent.author_id != user.id:
        session.add(
            Notification(
                user_id=parent.author_id,
                kind="reply",
                title="Ответ на ваш комментарий",
                body=(comment.body or "GIF" if comment.gif_url else "Вложение")[:160],
                actor_id=user.id,
                payload={"track_id": track_id, "comment_id": str(comment.id)},
            )
        )

    await session.commit()
    await session.refresh(comment, ["author"])
    return _serialise(comment, 0, user.id)


@router.post("/comments/{comment_id}/reaction", response_model=CommentOut)
async def react(
    comment_id: UUID, payload: ReactionIn, session: SessionDep, user: CurrentUser
) -> CommentOut:
    comment = await session.get(TrackComment, comment_id)
    if comment is None or comment.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Комментарий не найден")

    wanted = {"like": 1, "dislike": -1, "none": 0}[payload.value]
    existing = await session.get(CommentReaction, {"comment_id": comment_id, "user_id": user.id})
    previous = existing.value if existing else 0

    if previous == wanted:
        pass
    else:
        # Undo the old vote's contribution.
        if previous == 1:
            comment.like_count = max(0, comment.like_count - 1)
        elif previous == -1:
            comment.dislike_count = max(0, comment.dislike_count - 1)

        if wanted == 0:
            if existing:
                await session.delete(existing)
        else:
            if existing:
                existing.value = wanted
            else:
                session.add(
                    CommentReaction(comment_id=comment_id, user_id=user.id, value=wanted)
                )
            if wanted == 1:
                comment.like_count += 1
            else:
                comment.dislike_count += 1

    await session.commit()
    await session.refresh(comment, ["author"])
    return _serialise(comment, wanted, user.id)


@router.delete("/comments/{comment_id}", response_model=MessageOut)
async def delete_comment(comment_id: UUID, session: SessionDep, user: CurrentUser) -> MessageOut:
    comment = await session.get(TrackComment, comment_id)
    if comment is None:
        raise HTTPException(status_code=404, detail="Комментарий не найден")
    if comment.author_id != user.id and not user.is_admin:
        raise HTTPException(status_code=403, detail="Можно удалить только свой комментарий")

    comment.deleted_at = datetime.now(UTC)
    comment.body = None
    comment.media_url = None
    comment.gif_url = None
    await session.commit()
    return MessageOut(detail="Комментарий удалён")


@router.post("/media/upload", response_model=MediaUploadOut)
async def upload(file: UploadFile, user: CurrentUser) -> MediaUploadOut:
    """Photo or short clip for a comment — goes to Catbox, DB keeps the URL."""
    data = await file.read()
    if len(data) > 25 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Файл больше 25 МБ")
    try:
        url = await upload_media(data, filename=file.filename or "upload")
    except MediaUploadError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(exc)) from exc
    return MediaUploadOut(url=url)


@router.get("/tracks/{track_id}/comments/count")
async def comment_count(track_id: str, session: SessionDep) -> dict[str, int]:
    total = await session.scalar(
        select(func.count())
        .select_from(TrackComment)
        .where(TrackComment.track_id == track_id, TrackComment.deleted_at.is_(None))
    )
    return {"count": total or 0}
