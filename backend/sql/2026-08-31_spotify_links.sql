-- Which SoundCloud track streams the audio behind a Spotify track.
-- Search returns Spotify entities now; this caches the SoundCloud match.
-- Idempotent.

CREATE TABLE IF NOT EXISTS spotify_links (
    spotify_id   VARCHAR(32) PRIMARY KEY,
    sc_track_id  VARCHAR(64),
    checked_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_spotify_links_sc ON spotify_links (sc_track_id);

ALTER TABLE spotify_links OWNER TO laxify;
