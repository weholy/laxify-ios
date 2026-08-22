from datetime import UTC, datetime

from fastapi import APIRouter, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import desc, func, select

from app.api.deps import AdminUser, ClientIP, OptionalUser, SessionDep
from app.models import ClientReport
from app.schemas.common import MessageOut, Page

router = APIRouter(tags=["diagnostics"])


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
