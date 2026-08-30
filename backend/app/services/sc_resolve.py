"""Find the SoundCloud track that plays the audio for a Spotify track.

Search now returns Spotify entities; every Spotify track needs a SoundCloud
stream behind it or it can't be played. This resolves that, keyed on the
Spotify id, and caches the answer (including "no match" — cached shorter, so
uploads that appear later get picked up).
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.api.v1.catalog import normalise_track
from app.models import SpotifyLink
from app.services.soundcloud import SoundCloudError, soundcloud
from app.services.spotify_meta import _norm, _tokens

logger = logging.getLogger("laxify.sc_resolve")

MISS_RECHECK = timedelta(days=7)
_MATCH_THRESHOLD = 0.5
_sem = asyncio.Semaphore(5)


def _score(cand, artist: str, title: str, duration_s: float) -> float:
    ct, ca = _tokens(cand.title), _tokens(cand.artist_name)
    wt, wa = _tokens(title), _tokens(artist)
    if not ct or not wt:
        return 0.0
    title_overlap = len(ct & wt) / len(ct | wt)
    artist_overlap = len(ca & wa) / max(len(wa or ca), 1) if (ca and wa) else 0.0
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

    # Several phrasings — SoundCloud uploads are titled every which way.
    queries = [
        f"{artist} {title}",
        f"{primary} {bare_title}",
        f"{primary} - {bare_title}",
        bare_title if len(bare_title) > 6 else "",
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
        results = await asyncio.gather(
            *(_resolve_one(sp) for sp in todo), return_exceptions=True
        )
        now = datetime.now(UTC)
        to_store: list[dict] = []
        for res in results:
            if isinstance(res, BaseException):
                continue
            sid, sc_id = res
            out[sid] = sc_id
            to_store.append({"spotify_id": sid, "sc_track_id": sc_id, "checked_at": now})

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
