-- Spotify metadata overlay for SoundCloud tracks.
-- The SoundCloud id stays the identity everywhere; this only supplies clean
-- names / covers for display and records whether Spotify knows the track.
-- Idempotent: safe to run more than once.

CREATE TABLE IF NOT EXISTS track_meta (
    sc_track_id  VARCHAR(64) PRIMARY KEY,
    matched      BOOLEAN NOT NULL DEFAULT false,
    checked_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    spotify_id   VARCHAR(32),
    title        TEXT,
    artist_name  TEXT,
    artist_id    VARCHAR(32),
    album        TEXT,
    album_id     VARCHAR(32),
    cover_url    TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_track_meta_spotify ON track_meta (spotify_id);
CREATE INDEX IF NOT EXISTS ix_track_meta_recheck ON track_meta (matched, checked_at);

ALTER TABLE track_meta OWNER TO laxify;
