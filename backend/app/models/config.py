from sqlalchemy import Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin


class AppConfig(Base, TimestampMixin):
    """A tiny key/value store for the handful of things an operator needs to
    change without a redeploy.

    One row so far: ``min_supported_version``. Kept as its own table rather
    than an env var because an env var needs a restart and a person with SSH
    access to change it; this needs neither — it is read on every launch and
    written from Випка.
    """

    __tablename__ = "app_config"

    key: Mapped[str] = mapped_column(Text, primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="")
