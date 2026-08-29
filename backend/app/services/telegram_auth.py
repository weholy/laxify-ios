"""Verify a Telegram Login Widget payload.

Telegram signs the fields it hands back with the bot token. The client
receives `id`, `first_name`, optionally `last_name`, `username`,
`photo_url`, plus `auth_date` and a `hash`. The hash is HMAC-SHA256 over
the other fields joined as sorted "key=value" lines, keyed by the SHA256
of the bot token. A matching hash on a fresh `auth_date` means the payload
is genuine and untampered.

https://core.telegram.org/widgets/login#checking-authorization
"""
import hashlib
import hmac
import time
from dataclasses import dataclass

from app.core.config import settings


class TelegramAuthError(Exception):
    """Raised with a message safe to show the user."""


@dataclass(slots=True)
class TelegramIdentity:
    id: int
    first_name: str | None
    last_name: str | None
    username: str | None
    photo_url: str | None

    @property
    def full_name(self) -> str:
        return " ".join(p for p in (self.first_name, self.last_name) if p).strip()


def verify_login(data: dict[str, str]) -> TelegramIdentity:
    token = settings.telegram_bot_token
    if not token:
        raise TelegramAuthError("Вход через Telegram не настроен")

    received_hash = data.get("hash")
    if not received_hash:
        raise TelegramAuthError("Подпись отсутствует")

    check_string = "\n".join(
        sorted(f"{key}={value}" for key, value in data.items() if key != "hash")
    )
    secret_key = hashlib.sha256(token.encode()).digest()
    expected = hmac.new(secret_key, check_string.encode(), hashlib.sha256).hexdigest()

    if not hmac.compare_digest(expected, received_hash):
        raise TelegramAuthError("Подпись не совпадает")

    try:
        auth_date = int(data.get("auth_date", "0"))
    except ValueError as exc:
        raise TelegramAuthError("Некорректная дата входа") from exc

    if time.time() - auth_date > settings.telegram_login_ttl_seconds:
        raise TelegramAuthError("Ссылка устарела, войдите заново")

    try:
        telegram_id = int(data["id"])
    except (KeyError, ValueError) as exc:
        raise TelegramAuthError("Нет идентификатора пользователя") from exc

    return TelegramIdentity(
        id=telegram_id,
        first_name=data.get("first_name") or None,
        last_name=data.get("last_name") or None,
        username=data.get("username") or None,
        photo_url=data.get("photo_url") or None,
    )
