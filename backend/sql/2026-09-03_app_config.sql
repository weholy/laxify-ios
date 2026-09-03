-- A tiny key/value table for operator-controlled settings that must not
-- need a redeploy: today, the minimum app version the server will let in.
-- Idempotent: safe to run more than once.

CREATE TABLE IF NOT EXISTS app_config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
