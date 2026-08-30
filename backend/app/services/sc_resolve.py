"""Find the SoundCloud track that plays the audio for a Spotify track.

Search now returns Spotify entities; every Spotify track needs a SoundCloud
stream behind it or it can't be played. This resolves that, keyed on the
Spotify id, and caches the answer (including "no match" — cached shorter, so
uploads that appear later get picked up).
"""

from __future__ import annotations

import asyncio
import logging
import re
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.api.v1.catalog import normalise_track
from app.models import SpotifyLink
from app.services.soundcloud import SoundCloudError, soundcloud
from app.services.spotify_meta import _norm, _pair, _tokens

logger = logging.getLogger("laxify.sc_resolve")

MISS_RECHECK = timedelta(days=7)
_MATCH_THRESHOLD = 0.5
_sem = asyncio.Semaphore(12)

# A whole search must not wait on the slowest lookup. Anything unresolved when
# this expires is simply left out of the results.
RESOLVE_BUDGET = 3.5

# How many to resolve while the caller waits. The rest are done after the
# response goes out, so the second search of the same thing is instant.
RESOLVE_INLINE = 14

_deferred_task: asyncio.Task | None = None


def _schedule_background(items: list[dict]) -> None:
    """Resolve the tail after the response has gone out.

    Nobody is waiting on these, and having them cached is what makes a repeat
    search — or scrolling past the first screenful — cost nothing.
    """
    global _deferred_task
    if _deferred_task is not None and not _deferred_task.done():
        return

    async def run() -> None:
        from app.db.session import SessionLocal

        try:
            results = await asyncio.gather(
                *(_resolve_one(sp) for sp in items), return_exceptions=True
            )
            now = datetime.now(UTC)
            rows = [
                {"spotify_id": sid, "sc_track_id": sc_id, "checked_at": now}
                for res in results
                if not isinstance(res, BaseException)
                for sid, sc_id in [res]
            ]
            if rows:
                async with SessionLocal() as session:
                    stmt = pg_insert(SpotifyLink).values(rows)
                    stmt = stmt.on_conflict_do_update(
                        index_elements=["spotify_id"],
                        set_={
                            "sc_track_id": stmt.excluded.sc_track_id,
                            "checked_at": stmt.excluded.checked_at,
                        },
                    )
                    await session.execute(stmt)
                    await session.commit()
        except Exception:  # noqa: BLE001
            logger.warning("sc_resolve: background pass failed", exc_info=True)

    _deferred_task = asyncio.create_task(run())


def _score(cand, artist: str, title: str, duration_s: float) -> float:
    # Cross-script aware: a SoundCloud upload titled in Cyrillic has no words
    # in common with Spotify's Latin spelling, and vice versa.
    if not _norm(cand.title) or not _norm(title):
        return 0.0
    title_overlap = _pair(cand.title, title)
    artist_overlap = _pair(cand.artist_name, artist, subset=True)
    score = title_overlap * 0.6 + artist_overlap * 0.3
    if duration_s and cand.duration_seconds:
        gap = abs(cand.duration_seconds - duration_s)
        if gap <= 4:
            score += 0.12
        elif gap <= 12:
            score += 0.05
        elif gap > 35:
            score -= 0.2
    lowered = cand.title.lower()
    if any(w in lowered for w in ("remix", "sped up", "slowed", "nightcore", "8d", "mashup")):
        if not any(w in title.lower() for w in ("remix", "sped up", "slowed")):
            score -= 0.3
    return score


_FEAT = re.compile(r"\s*[\(\[]?\s*(feat|ft|with)\.?\s+[^\)\]]+[\)\]]?", re.IGNORECASE)
_PRIMARY_ARTIST = re.compile(r"\s*,\s*|\s*&\s*|\s+x\s+", re.IGNORECASE)


async def _resolve_one(sp: dict) -> tuple[str, str | None]:
    artist = sp.get("artist_name") or ""
    title = sp.get("title") or ""
    dur = (sp.get("duration_ms") or 0) / 1000
    if not title:
        return sp["spotify_id"], None

    primary = _PRIMARY_ARTIST.split(artist)[0].strip() or artist
    bare_title = _FEAT.sub("", title).strip() or title

    # Two phrasings, tried in order and stopped early on a confident hit. It
    # used to try four, which quadrupled the wait on a search for no
    # measurable gain in matches.
    queries = [
        f"{primary} {bare_title}",
        f"{artist} {title}",
    ]

    best_overall = None
    best_score = 0.0
    for q in dict.fromkeys(q for q in queries if q.strip()):
        async with _sem:
            try:
                raw = await soundcloud.search_tracks(q, limit=6)
            except SoundCloudError:
                continue
        cands = [t for t in (normalise_track(r) for r in raw) if t]
        if not cands:
            continue
        best = max(cands, key=lambda c: _score(c, artist, title, dur))
        s = _score(best, artist, title, dur)
        if s > best_score:
            best_score, best_overall = s, best
        if s >= 0.75:
            break

    if best_overall is not None and best_score >= _MATCH_THRESHOLD:
        return sp["spotify_id"], best_overall.id
    return sp["spotify_id"], None


async def resolve(session, spotify_tracks: list[dict]) -> dict[str, str | None]:
    """`{spotify_id: sc_track_id or None}` for the given Spotify track dicts."""
    ids = [t["spotify_id"] for t in spotify_tracks if t.get("spotify_id")]
    if not ids:
        return {}

    out: dict[str, str | None] = {}
    stale_cutoff = datetime.now(UTC) - MISS_RECHECK
    try:
        rows = (
            await session.scalars(select(SpotifyLink).where(SpotifyLink.spotify_id.in_(ids)))
        ).all()
    except Exception:  # noqa: BLE001
        rows = []

    cached = {r.spotify_id: r for r in rows}
    todo: list[dict] = []
    for sp in spotify_tracks:
        row = cached.get(sp.get("spotify_id"))
        if row is None:
            todo.append(sp)
        elif row.sc_track_id is None and row.checked_at < stale_cutoff:
            todo.append(sp)
        else:
            out[sp["spotify_id"]] = row.sc_track_id

    if todo:
        # Only the first screenful is resolved inline. Someone searching does
        # not scroll thirty rows before the results appear, and each lookup is
        # a round trip to SoundCloud.
        inline, deferred = todo[:RESOLVE_INLINE], todo[RESOLVE_INLINE:]

        tasks = [asyncio.create_task(_resolve_one(sp)) for sp in inline]
        done, pending = await asyncio.wait(tasks, timeout=RESOLVE_BUDGET)
        for task in pending:
            task.cancel()
        if pending:
            logger.info(
                "sc_resolve: %d of %d resolved within budget", len(done), len(inline)
            )

        now = datetime.now(UTC)
        to_store: list[dict] = []
        # Whatever finished is kept, even when the batch as a whole ran out of
        # time — throwing away completed work meant the next search redid it.
        for task in done:
            if task.cancelled() or task.exception() is not None:
                continue
            sid, sc_id = task.result()
            out[sid] = sc_id
            to_store.append({"spotify_id": sid, "sc_track_id": sc_id, "checked_at": now})

        if deferred:
            _schedule_background(deferred)

        if to_store:
            try:
                stmt = pg_insert(SpotifyLink).values(to_store)
                stmt = stmt.on_conflict_do_update(
                    index_elements=["spotify_id"],
                    set_={"sc_track_id": stmt.excluded.sc_track_id, "checked_at": stmt.excluded.checked_at},
                )
                await session.execute(stmt)
                await session.commit()
            except Exception:  # noqa: BLE001
                logger.warning("sc_resolve: cache write failed", exc_info=True)
                await session.rollback()

    return out
