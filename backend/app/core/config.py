from functools import lru_cache
from typing import Literal

from pydantic import Field, PostgresDsn, RedisDsn
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    environment: Literal["dev", "prod"] = "dev"
    debug: bool = False
    api_prefix: str = "/api/v1"
    project_name: str = "Laxify API"

    database_url: PostgresDsn
    redis_url: RedisDsn

    jwt_secret: str = Field(min_length=32)
    jwt_algorithm: str = "HS256"
    access_token_ttl_minutes: int = 30
    # Long-lived by design: the client keeps the refresh token in the Keychain
    # and silently renews, so a signed-in user stays signed in until they
    # explicitly log out or the device is revoked.
    refresh_token_ttl_days: int = 365

    google_client_ids: list[str] = Field(default_factory=list)

    # Telegram Login Widget. The bot is created in @BotFather and its domain
    # is pointed (via /setdomain) at the host that serves /tg-login. Unset
    # means the /auth/telegram endpoint refuses every request.
    telegram_bot_token: str | None = None
    telegram_bot_username: str = "LaxifyAppBot"
    # How old a widget payload's auth_date may be before it is rejected.
    telegram_login_ttl_seconds: int = 86400
    # Numeric chat id the same bot relays track-problem reports to. Unset
    # means reports still save (they show in Випка → Ошибки either way) but
    # nothing is pushed to Telegram.
    telegram_report_chat_id: str | None = None

    # Comment attachments go to Catbox; a userhash ties uploads to an account
    # (optional — anonymous uploads work without it). Litterbox is the
    # fallback when Catbox is down.
    catbox_userhash: str | None = None
    # GIF search proxy. Empty means the picker returns nothing.
    tenor_api_key: str | None = None

    # Mail relay. Unset means codes are logged instead of sent, so the server
    # runs without a mail account configured.
    smtp_host: str | None = None
    smtp_port: int = 587
    smtp_user: str | None = None
    smtp_password: str | None = None
    # Must match the host the reverse record names, or receiving
    # servers treat the message as forged.
    smtp_from: str = "no-reply@netevpn.play2go.cloud"
    smtp_use_tls: bool = True
    smtp_use_ssl: bool = False

    # Genius, for lyrics the timed sources do not have. Its API returns a
    # link rather than the words, so the page is read — which is the only way
    # it is ever done.
    genius_client_id: str | None = None
    genius_client_secret: str | None = None

    # Yandex access is pooled server-side. One token today, more later —
    # rotation logic keys off this table rather than a single env value.
    yandex_tokens: list[str] = Field(default_factory=list)

    # The proxy layer is written but stays off until a Russian-IP host exists.
    # With it disabled the app talks to Yandex directly, exactly as before.
    #
    # Measured from this host on 2026-09-05, so nobody has to guess again:
    # `/account/status` answers 200 — the token and the account are fine from
    # here — while `/search` answers 451. It is the content that is refused by
    # region, not the credentials. Turning this on before the server has a
    # Russian address would replace a working direct connection with a wall.
    music_proxy_enabled: bool = False
    music_proxy_upstream: str | None = None

    # YouTube Music needs nothing signed in, but its media urls name the
    # address that asked for them, so audio is relayed from here. The
    # extractor is invoked as a separate process; this is where it lives when
    # it is not simply on PATH.
    ytmusic_enabled: bool = True
    ytdlp_path: str | None = None

    cors_origins: list[str] = Field(default_factory=list)
    rate_limit_per_minute: int = 120

    admin_google_subs: list[str] = Field(default_factory=list)

    apns_key_id: str | None = None
    apns_team_id: str | None = None
    apns_bundle_id: str = "com.laxify.app"
    apns_private_key: str | None = None
    apns_use_sandbox: bool = True

    @property
    def is_prod(self) -> bool:
        return self.environment == "prod"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
