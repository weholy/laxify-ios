-- A notification can carry its own image instead of falling back to the
-- app's mark or the actor's avatar. All nullable, so existing rows are
-- untouched. Idempotent: safe to run more than once.

ALTER TABLE notifications ADD COLUMN IF NOT EXISTS icon_url TEXT;
