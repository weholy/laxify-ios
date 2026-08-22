"""What the app is actually doing, as it happens.

A description of a problem — "the track takes ten seconds to start" — is not
enough to fix one, because the interesting part is which of the several steps
between a tap and a sound took those seconds. Reproducing it here is no help
either: the server is fast from the server.

So the app measures each step and sends the numbers. These are cheap to
write, batched by the client, and queried here rather than read one by one.
"""

from datetime import UTC, datetime

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field
from sqlalchemy import desc, func, select

from app.api.deps import CurrentUser, OptionalUser, SessionDep
from app.models import ClientLog
from app.schemas.common import MessageOut, Page

router = APIRouter(tags=["telemetry"])

MAX_BATCH = 200


class LogEntry(BaseModel):
    """One line, or one measured step."""

    at: datetime
    level: str = Field(default="info", max_length=16)
    category: str = Field(default="app", max_length=32)
    message: str = Field(max_length=2000)
    # Milliseconds, when the line is describing something that took time.
    duration_ms: int | None = None
    # Free-form, for the numbers that only make sense with this line.
    context: dict[str, str] = Field(default_factory=dict)


class LogBatch(BaseModel):
    session_id: str = Field(max_length=64)
    app_version: str | None = Field(default=None, max_length=32)
    os_version: str | None = Field(default=None, max_length=32)
    device_model: str | None = Field(default=None, max_length=64)
    entries: list[LogEntry] = Field(max_length=MAX_BATCH)


@router.post("/telemetry/logs", response_model=MessageOut)
async def ingest(
    payload: LogBatch, user: OptionalUser, session: SessionDep, request_id: str = ""
) -> MessageOut:
    """Accepts a batch of log lines.

    Unauthenticated on purpose: the moments most worth seeing are the ones
    before anyone has managed to sign in.
    """
    now = datetime.now(UTC)

    session.add_all(
        ClientLog(
            user_id=user.id if user else None,
            session_id=payload.session_id,
            app_version=payload.app_version,
            os_version=payload.os_version,
            device_model=payload.device_model,
            level=entry.level,
            category=entry.category,
            message=entry.message,
            duration_ms=entry.duration_ms,
            context=entry.context,
            # Trust the device for ordering within a session, but keep our own
            # clock too: a phone with the wrong time would otherwise scatter
            # its lines across the timeline.
            happened_at=entry.at,
            received_at=now,
        )
        for entry in payload.entries[:MAX_BATCH]
    )
    await session.commit()

    return MessageOut(detail="ok")


class LogOut(BaseModel):
    id: str
    session_id: str
    level: str
    category: str
    message: str
    duration_ms: int | None
    context: dict
    app_version: str | None
    device_model: str | None
    happened_at: datetime


@router.get("/admin/logs", response_model=Page[LogOut])
async def recent(
    user: CurrentUser,
    session: SessionDep,
    category: str | None = Query(None, max_length=32),
    level: str | None = Query(None, max_length=16),
    session_id: str | None = Query(None, max_length=64),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
) -> Page[LogOut]:
    clauses = []
    if category:
        clauses.append(ClientLog.category == category)
    if level:
        clauses.append(ClientLog.level == level)
    if session_id:
        clauses.append(ClientLog.session_id == session_id)

    statement = select(ClientLog).where(*clauses).order_by(desc(ClientLog.happened_at))
    total = await session.scalar(
        select(func.count()).select_from(ClientLog).where(*clauses)
    )

    rows = (await session.scalars(statement.limit(limit).offset(offset))).all()

    return Page(
        items=[
            LogOut(
                id=str(row.id),
                session_id=row.session_id,
                level=row.level,
                category=row.category,
                message=row.message,
                duration_ms=row.duration_ms,
                context=row.context or {},
                app_version=row.app_version,
                device_model=row.device_model,
                happened_at=row.happened_at,
            )
            for row in rows
        ],
        total=total or 0,
        limit=limit,
        offset=offset,
    )


class TimingSummary(BaseModel):
    """How long one step takes, across everyone it happened to."""

    message: str
    samples: int
    median_ms: int
    p90_ms: int
    worst_ms: int


@router.get("/admin/logs/timings", response_model=list[TimingSummary])
async def timings(
    user: CurrentUser,
    session: SessionDep,
    category: str = Query("playback", max_length=32),
    limit: int = Query(20, ge=1, le=50),
) -> list[TimingSummary]:
    """The slow steps, ranked.

    A median and a ninetieth percentile together say whether something is
    slow for everyone or slow occasionally — which point at very different
    causes.
    """
    rows = (
        await session.execute(
            select(
                ClientLog.message,
                func.count().label("samples"),
                func.percentile_cont(0.5)
                .within_group(ClientLog.duration_ms)
                .label("median"),
                func.percentile_cont(0.9)
                .within_group(ClientLog.duration_ms)
                .label("p90"),
                func.max(ClientLog.duration_ms).label("worst"),
            )
            .where(ClientLog.category == category, ClientLog.duration_ms.isnot(None))
            .group_by(ClientLog.message)
            .order_by(desc("p90"))
            .limit(limit)
        )
    ).all()

    return [
        TimingSummary(
            message=message,
            samples=samples,
            median_ms=int(median or 0),
            p90_ms=int(p90 or 0),
            worst_ms=int(worst or 0),
        )
        for message, samples, median, p90, worst in rows
    ]
