-- Comments, comment reactions, profile likes, notifications, and two new
-- columns on users. Idempotent: safe to run more than once.

ALTER TABLE users ADD COLUMN IF NOT EXISTS primary_auth_method VARCHAR(16) NOT NULL DEFAULT 'google';
ALTER TABLE users ADD COLUMN IF NOT EXISTS hide_profile_likes BOOLEAN NOT NULL DEFAULT FALSE;

-- Backfill the existing 71 accounts from what they actually have.
UPDATE users SET primary_auth_method = CASE
    WHEN telegram_id IS NOT NULL AND google_sub IS NULL THEN 'telegram'
    WHEN google_sub IS NOT NULL THEN 'google'
    WHEN password_hash IS NOT NULL THEN 'email'
    ELSE 'google'
END
WHERE primary_auth_method = 'google';

CREATE TABLE IF NOT EXISTS track_comments (
    id UUID PRIMARY KEY,
    track_id VARCHAR(64) NOT NULL,
    author_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES track_comments(id) ON DELETE CASCADE,
    body TEXT,
    media_url TEXT,
    gif_url TEXT,
    like_count INTEGER NOT NULL DEFAULT 0,
    dislike_count INTEGER NOT NULL DEFAULT 0,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_track_comments_track_id ON track_comments (track_id);
CREATE INDEX IF NOT EXISTS ix_track_comments_author_id ON track_comments (author_id);
CREATE INDEX IF NOT EXISTS ix_track_comments_track_time ON track_comments (track_id, created_at);
CREATE INDEX IF NOT EXISTS ix_track_comments_parent ON track_comments (parent_id);

CREATE TABLE IF NOT EXISTS comment_reactions (
    comment_id UUID NOT NULL REFERENCES track_comments(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    value INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (comment_id, user_id)
);

CREATE TABLE IF NOT EXISTS profile_likes (
    target_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    liker_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (target_id, liker_id)
);
CREATE INDEX IF NOT EXISTS ix_profile_likes_target ON profile_likes (target_id);

CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind VARCHAR(24) NOT NULL,
    title VARCHAR(160) NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    actor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    read_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_notifications_user_id ON notifications (user_id);
CREATE INDEX IF NOT EXISTS ix_notifications_user_time ON notifications (user_id, created_at);

-- Run as the postgres superuser, so the new tables end up owned by postgres
-- and the app's `laxify` role cannot touch them. Hand them over.
ALTER TABLE track_comments     OWNER TO laxify;
ALTER TABLE comment_reactions  OWNER TO laxify;
ALTER TABLE profile_likes      OWNER TO laxify;
ALTER TABLE notifications      OWNER TO laxify;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO laxify;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO laxify;
