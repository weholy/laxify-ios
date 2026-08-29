-- Telegram Login Widget: columns on `users` for accounts that come in
-- through @LaxifyAppBot. All nullable, so existing rows are untouched.
-- Idempotent: safe to run more than once.

ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_id BIGINT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_username VARCHAR(64);
ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_photo_url TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS ix_users_telegram_id ON users (telegram_id);
