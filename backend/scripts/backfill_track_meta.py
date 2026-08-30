"""Warm the `track_meta` cache for every track already in the catalogue.

After this runs, favourites / playlists / search render clean Spotify names
and covers from a cache hit — no per-request lookups, no first-load lag. Rows
that get no Spotify match are marked ``matched = false`` and hidden from
listings until a later re-check.

Run on the server (it needs the DB + outbound HTTPS to Spotify's embed API):

    cd /opt/laxify && .venv/bin/python -m scripts.backfill_track_meta

Safe to re-run — it skips ids already checked within the last 14 days.
"""

import asyncio
import sys
import time
from datetime import UTC, datetime, timedelta

sys.path.insert(0, "/opt/laxify")
sys.path.insert(0, ".")

from sqlalchemy import select                                  # noqa: E402
from sqlalchemy.dialects.postgresql import insert as pg_insert  # noqa: E402

from app.db.session import SessionLocal                        # noqa: E402
from app.models import TrackMeta, TrackSnapshot                # noqa: E402
from app.services import spotify_meta                          # noqa: E402

RECHECK_AFTER = timedelta(days=14)
PAUSE_SECONDS = 0.4        # be gentle on the embed API
COMMIT_EVERY = 25


async def main() -> None:
    if not await spotify_meta.available():
        print("spotify_meta unavailable — aborting")
        return

    started = time.monotonic()
    cutoff = datetime.now(UTC) - RECHECK_AFTER

    async with SessionLocal() as session:
        snaps = (
            await session.scalars(
                select(TrackSnapshot).order_by(TrackSnapshot.created_at.desc())
            )
        ).all()
        done = {
            row.sc_track_id
            for row in (
                await session.scalars(
                    select(TrackMeta).where(TrackMeta.checked_at >= cutoff)
                )
            ).all()
        }

    todo = [s for s in snaps if s.track_id not in done]
    print(f"{len(snaps)} tracks, {len(todo)} to check")

    batch: list[dict] = []
    matched = 0

    async def flush():
        nonlocal batch
        if not batch:
            return
        async with SessionLocal() as session:
            stmt = pg_insert(TrackMeta).values(batch)
            stmt = stmt.on_conflict_do_update(
                index_elements=["sc_track_id"],
                set_={
                    c: stmt.excluded[c]
                    for c in (
                        "matched", "checked_at", "spotify_id", "title",
                        "artist_name", "artist_id", "album", "album_id", "cover_url",
                    )
                },
            )
            await session.execute(stmt)
            await session.commit()
        batch = []

    for i, snap in enumerate(todo, 1):
        try:
            match = await spotify_meta.match_track(
                snap.artist_name or "", snap.title or "", snap.duration_seconds or 0
            )
        except Exception as exc:  # noqa: BLE001
            print(f"  ! {snap.track_id}: {exc}")
            match = None

        row = {
            "sc_track_id": snap.track_id,
            "checked_at": datetime.now(UTC),
            "matched": bool(match),
        }
        if match:
            matched += 1
            row.update(
                spotify_id=match["spotify_id"],
                title=match["title"],
                artist_name=match["artist_name"],
                artist_id=match.get("artist_id"),
                album=match.get("album"),
                album_id=match.get("album_id"),
                cover_url=match.get("cover_url"),
            )
        batch.append(row)

        if i % COMMIT_EVERY == 0:
            await flush()
            print(f"  {i}/{len(todo)} · matched {matched} · "
                  f"{int(time.monotonic() - started)}s")
        await asyncio.sleep(PAUSE_SECONDS)

    await flush()
    print(f"done: {matched}/{len(todo)} matched in {int(time.monotonic() - started)}s")


if __name__ == "__main__":
    asyncio.run(main())
