"""Warm the catalogue: resolve every track anyone has actually touched.

Two things stop the app looking complete:

* a track nobody has looked up yet has no Spotify twin recorded, so a listing
  either shows the uploader's spelling or hides the track entirely;
* an artist's page is assembled from Spotify, and each album is a request, so
  the first person to open a busy artist waits for all of them.

This does both ahead of time. Run it on the server after a deploy, and again
whenever it feels thin:

    cd /opt/laxify && .venv/bin/python -m scripts.warm_catalogue

Idempotent, resumable, and safe to run while the API is serving: everything it
writes is a cache row, and it never deletes anything.
"""

import asyncio
import sys
import time
from datetime import UTC, datetime, timedelta

sys.path.insert(0, "/opt/laxify")
sys.path.insert(0, ".")

from sqlalchemy import distinct, func, select                   # noqa: E402

from app.db.session import SessionLocal                         # noqa: E402
from app.models import (                                        # noqa: E402
    Favorite,
    ListeningEvent,
    PlaylistItem,
    TrackMeta,
    TrackSnapshot,
)
from app.services import spotify_meta                           # noqa: E402
from app.services.catalog_meta import _META_COLS, _meta_row     # noqa: E402

from sqlalchemy.dialects.postgresql import insert as pg_insert  # noqa: E402

RECHECK_AFTER = timedelta(days=14)
# The scraper rate-limits itself; more than a few at once just produces
# timeouts, and this competes with the API for the same client.
CONCURRENCY = 3
CHUNK = 24


async def _tracks_to_check() -> list[TrackSnapshot]:
    """Everything in someone's library, playlists or history, least-known
    first — those are the rows a screen is most likely to show next."""
    cutoff = datetime.now(UTC) - RECHECK_AFTER
    async with SessionLocal() as session:
        wanted = set(
            (await session.scalars(select(distinct(Favorite.track_id)))).all()
        ) | set(
            (await session.scalars(select(distinct(PlaylistItem.track_id)))).all()
        ) | set(
            (await session.scalars(select(distinct(ListeningEvent.track_id)))).all()
        )

        known = set(
            (
                await session.scalars(
                    select(TrackMeta.sc_track_id).where(TrackMeta.checked_at >= cutoff)
                )
            ).all()
        )

        todo = wanted - known
        if not todo:
            return []

        # Anything else in the snapshot table too — it is what listings draw
        # from — but the touched ones lead.
        everything = (
            await session.scalars(
                select(TrackSnapshot).where(TrackSnapshot.track_id.in_(todo))
            )
        ).all()
        return list(everything)


async def _resolve(snapshots: list[TrackSnapshot]) -> int:
    sem = asyncio.Semaphore(CONCURRENCY)
    matched = 0

    async def one(snap: TrackSnapshot) -> dict | None:
        async with sem:
            try:
                match = await spotify_meta.match_track(
                    snap.artist_name or "", snap.title or "", snap.duration_seconds or 0
                )
            except spotify_meta.LookupUnavailable:
                # Never write a miss for a lookup that never ran — it would
                # hide the track for a fortnight over one slow minute.
                return None
            except Exception:  # noqa: BLE001
                return None
        return _meta_row(snap.track_id, datetime.now(UTC), match)

    for index in range(0, len(snapshots), CHUNK):
        chunk = snapshots[index : index + CHUNK]
        rows = [r for r in await asyncio.gather(*(one(s) for s in chunk)) if r]
        matched += sum(1 for r in rows if r["matched"])

        if rows:
            async with SessionLocal() as session:
                stmt = pg_insert(TrackMeta).values(rows)
                stmt = stmt.on_conflict_do_update(
                    index_elements=["sc_track_id"],
                    set_={c: stmt.excluded[c] for c in ("matched", "checked_at", *_META_COLS)},
                )
                await session.execute(stmt)
                await session.commit()

        print(f"  tracks {min(index + CHUNK, len(snapshots))}/{len(snapshots)} · matched {matched}", flush=True)

    return matched


async def _warm_artists() -> int:
    """Build the full Spotify catalogue for the artists people listen to, so
    nobody is the one who pays for assembling it."""
    from app.api.v1.catalog import _spotify_artist_catalogue

    async with SessionLocal() as session:
        rows = (
            await session.execute(
                select(TrackMeta.artist_id, func.count().label("n"))
                .where(TrackMeta.matched.is_(True), TrackMeta.artist_id.is_not(None))
                .group_by(TrackMeta.artist_id)
                .order_by(func.count().desc())
                .limit(60)
            )
        ).all()

    artist_ids = [row[0] for row in rows if row[0]]
    for position, artist_id in enumerate(artist_ids, 1):
        try:
            pool = await _spotify_artist_catalogue(artist_id)
            print(f"  artist {position}/{len(artist_ids)} {artist_id}: {len(pool)} tracks", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"  artist {position}/{len(artist_ids)} {artist_id}: {exc}")
    return len(artist_ids)


async def main() -> None:
    started = time.monotonic()

    if not await spotify_meta.available():
        print("spotify_meta unavailable — aborting")
        return

    snapshots = await _tracks_to_check()
    print(f"tracks to resolve: {len(snapshots)}", flush=True)
    matched = await _resolve(snapshots) if snapshots else 0

    print("warming artist catalogues…", flush=True)
    artists = await _warm_artists()

    print(
        f"done in {int(time.monotonic() - started)}s: "
        f"{matched}/{len(snapshots)} tracks matched, {artists} artists warmed"
    )


if __name__ == "__main__":
    asyncio.run(main())
