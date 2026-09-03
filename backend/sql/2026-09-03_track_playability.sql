-- Which tracks actually play, and who found out.
--
-- The verdict used to live in memory on the server, which meant two things:
-- it was gone on every restart, and it was reached from Frankfurt. The second
-- is the real problem — SoundCloud answers by region, so a track the server
-- resolves happily comes back to a phone in another country as policy=BLOCK
-- with no stream variants at all. The server was certifying tracks it had no
-- way to judge.
--
-- So the phone's verdict is recorded too, and it wins: it is the only party
-- that has to actually make sound.

CREATE TABLE IF NOT EXISTS track_playability (
    track_id     VARCHAR(64)  NOT NULL,
    region       VARCHAR(8)   NOT NULL DEFAULT '??',
    playable     BOOLEAN      NOT NULL,
    -- 'client' beats 'server': see above.
    source       VARCHAR(16)  NOT NULL DEFAULT 'server',
    reason       VARCHAR(64),
    reports      INTEGER      NOT NULL DEFAULT 1,
    checked_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (track_id, region)
);

CREATE INDEX IF NOT EXISTS ix_track_playability_dead
    ON track_playability (playable, checked_at)
    WHERE playable = false;
