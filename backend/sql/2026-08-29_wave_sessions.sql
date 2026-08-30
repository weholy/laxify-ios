-- Personal-wave session state — the server-side equivalent of Yandex's rotor
-- session (a running batch that remembers this session's skips and finishes
-- and reshapes what comes next from them).
-- Idempotent: safe to run more than once.

CREATE TABLE IF NOT EXISTS wave_sessions (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    station     VARCHAR(64) NOT NULL DEFAULT 'user:onyourwave',
    settings    JSONB NOT NULL DEFAULT '{}'::jsonb,
    queue       JSONB NOT NULL DEFAULT '[]'::jsonb,
    history     JSONB NOT NULL DEFAULT '[]'::jsonb,
    suppressed  JSONB NOT NULL DEFAULT '[]'::jsonb,
    favored     JSONB NOT NULL DEFAULT '[]'::jsonb,
    boosted     JSONB NOT NULL DEFAULT '[]'::jsonb,
    served      JSONB NOT NULL DEFAULT '[]'::jsonb,
    skips       JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_wave_sessions_user
    ON wave_sessions (user_id, updated_at);

-- Owned by the app role, like every other table it writes.
ALTER TABLE wave_sessions OWNER TO laxify;
