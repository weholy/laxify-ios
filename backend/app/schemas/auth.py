from pydantic import BaseModel, Field


class DeviceInfo(BaseModel):
    name: str = Field(default="iPhone", max_length=120)
    model: str | None = Field(default=None, max_length=80)
    app_version: str | None = Field(default=None, max_length=32)


class GoogleSignInRequest(BaseModel):
    id_token: str
    device: DeviceInfo = Field(default_factory=DeviceInfo)


class TelegramSignInRequest(BaseModel):
    # The raw field set from the Telegram Login Widget, `hash` included, exactly
    # as the widget produced it — the server re-checks the signature itself.
    payload: dict[str, str]
    device: DeviceInfo = Field(default_factory=DeviceInfo)


class RefreshRequest(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class SessionOut(BaseModel):
    tokens: TokenPair
    is_new_user: bool
    needs_onboarding: bool
    needs_local_migration: bool
