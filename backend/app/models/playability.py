from datetime import datetime

from sqlalchemy import Boolean, DateTime, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class TrackPlayability(Base):
    """Whether a track actually plays, per region, and who found out.

    This lived in a dict on the server, which lost it on every restart and —
    worse — only ever recorded what Frankfurt could see. SoundCloud answers by
    region: a track the server streams without trouble arrives at a phone in
    another country as ``policy=BLOCK`` with an empty transcoding list. The
    server was vouching for tracks it had no way to judge, and the listener
    got the silence.

    So the phone reports what it found, and a report from a phone outranks a
    check from the server: it is the one that has to make sound.
    """

    __tablename__ = "track_playability"

    track_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    region: Mapped[str] = mapped_column(String(8), primary_key=True, default="??")

    playable: Mapped[bool] = mapped_column(Boolean, nullable=False)
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="server")
    reason: Mapped[str | None] = mapped_column(String(64), default=None)
    reports: Mapped[int] = mapped_column(Integer, nullable=False, default=1)

    checked_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
