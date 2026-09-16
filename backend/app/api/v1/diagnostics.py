from datetime import UTC, datetime

import httpx
from fastapi import APIRouter, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import desc, func, select

from app.api.deps import AdminUser, ClientIP, CurrentUser, OptionalUser, SessionDep
from app.core.config import settings
from app.models import ClientReport
from app.schemas.common import MessageOut, Page

router = APIRouter(tags=["diagnostics"])


async def _notify_telegram(text: str, photo_url: str | None) -> None:
    """Best-effort relay to the admin's Telegram. Never raises — a report
    that fails to arrive on Telegram still saved to `client_reports` and
    shows in Випка → Ошибки, so there is nothing to roll back or retry here."""
    token = settings.telegram_bot_token
    chat_id = settings.telegram_report_chat_id
    if not token or not chat_id:
        return

    base = f"https://api.telegram.org/bot{token}"
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            if photo_url:
                await client.post(
                    f"{base}/sendPhoto",
                    data={"chat_id": chat_id, "photo": photo_url, "caption": text[:1024]},
                )
            else:
                await client.post(f"{base}/sendMessage", data={"chat_id": chat_id, "text": text[:4096]})
    except httpx.HTTPError:
        pass


class ClientReportIn(BaseModel):
    kind: str = Field(max_length=32, description="crash | error | log")
    message: str = Field(max_length=2000)
    detail: str | None = Field(default=None, max_length=20000)
    app_version: str | None = Field(default=None, max_length=32)
    os_version: str | None = Field(default=None, max_length=32)
    device_model: str | None = Field(default=None, max_length=64)
    occurred_at: datetime | None = None
    context: dict = Field(default_factory=dict)


class ClientReportOut(BaseModel):
    id: str
    kind: str
    message: str
    detail: str | None
    app_version: str | None
    os_version: str | None
    device_model: str | None
    occurred_at: datetime
    context: dict
    created_at: datetime


@router.post("/diagnostics/report", response_model=MessageOut)
async def submit_report(
    payload: ClientReportIn,
    session: SessionDep,
    user: OptionalUser,
    ip: ClientIP,
) -> MessageOut:
    """Accepts a crash or error report from the app.

    Deliberately open to unauthenticated callers: the most valuable reports
    are the ones from a launch that failed before sign-in, and requiring a
    token would drop exactly those.
    """
    session.add(
        ClientReport(
            user_id=user.id if user else None,
            kind=payload.kind[:32],
            message=payload.message,
            detail=payload.detail,
            app_version=payload.app_version,
            os_version=payload.os_version,
            device_model=payload.device_model,
            occurred_at=payload.occurred_at or datetime.now(UTC),
            context=payload.context,
            ip=ip,
        )
    )
    return MessageOut(detail="Принято")


class TrackReportIn(BaseModel):
    track_id: str = Field(max_length=64)
    track_title: str = Field(max_length=300)
    track_artist: str = Field(max_length=300)
    reasons: list[str] = Field(min_length=1, max_length=10)
    message: str | None = Field(default=None, max_length=2000)
    photo_url: str | None = Field(default=None, max_length=1000)


@router.post("/reports/track", response_model=MessageOut)
async def submit_track_report(
    payload: TrackReportIn,
    session: SessionDep,
    user: CurrentUser,
) -> MessageOut:
    """A listener flags something wrong with a specific track — audio that
    does not match, lyrics that do not match, one that will not play.

    Saved as a `ClientReport` (kind="track_report") rather than a table of
    its own: it already shows in Випка → Ошибки, filterable by kind, with
    nothing new to build there. The Telegram push on top is best-effort.
    """
    reasons = [r.strip() for r in payload.reasons if r.strip()][:10]
    session.add(
        ClientReport(
            user_id=user.id,
            kind="track_report",
            message=", ".join(reasons) or "Без причины",
            detail=payload.message,
            occurred_at=datetime.now(UTC),
            context={
                "track_id": payload.track_id,
                "track_title": payload.track_title,
                "track_artist": payload.track_artist,
                "reasons": reasons,
                "photo_url": payload.photo_url,
            },
        )
    )

    lines = [
        "🚩 Жалоба на трек",
        f"{payload.track_title} — {payload.track_artist}",
        f"id: {payload.track_id}",
        f"Причины: {', '.join(reasons) or '—'}",
    ]
    if payload.message:
        lines.append(payload.message)
    lines.append(f"От: @{user.username}")
    await _notify_telegram("\n".join(lines), payload.photo_url)

    return MessageOut(detail="Спасибо, разберёмся")


@router.get("/admin/diagnostics", response_model=Page[ClientReportOut])
async def list_reports(
    admin: AdminUser,
    session: SessionDep,
    kind: str | None = Query(default=None, max_length=32),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> Page[ClientReportOut]:
    stmt = select(ClientReport)
    count_stmt = select(func.count()).select_from(ClientReport)

    if kind:
        stmt = stmt.where(ClientReport.kind == kind)
        count_stmt = count_stmt.where(ClientReport.kind == kind)

    total = await session.scalar(count_stmt) or 0
    rows = (
        await session.scalars(
            stmt.order_by(desc(ClientReport.created_at)).limit(limit).offset(offset)
        )
    ).all()

    return Page(
        items=[
            ClientReportOut(
                id=str(row.id),
                kind=row.kind,
                message=row.message,
                detail=row.detail,
                app_version=row.app_version,
                os_version=row.os_version,
                device_model=row.device_model,
                occurred_at=row.occurred_at,
                context=row.context,
                created_at=row.created_at,
            )
            for row in rows
        ],
        total=total,
        limit=limit,
        offset=offset,
    )
