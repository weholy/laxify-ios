"""Overlay Spotify metadata onto the catalogue the app already serves.

The rule everywhere: a request never waits on Spotify. `enrich` reads the
`track_meta` cache and applies whatever is there; ids it has never seen are
scheduled for a background lookup and this time round keep their SoundCloud
metadata. A track is only *hidden* when a completed lookup found no Spotify
match — never because the lookup hasn't run yet or failed.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.db.session import SessionLocal
from app.models import TrackMeta
from app.services import spotify_meta

logger = logging.getLogger("laxify.catalog_meta")

# Re-check a "not on Spotify" verdict after this long, in case the match
# improves (Spotify adds the track, or our matching gets better).
RECHECK_AFTER = timedelta(days=14)

# Never resolve more than this many new ids from one request's tail.
_MAX_SCHEDULED = 40

_inflight: set[str] = set()

_META_COLS = (
    "spotify_id", "title", "artist_name", "artist_id", "album", "album_id", "cover_url",
)


def _meta_row(tid: str, when, match: dict | None) -> dict:
    """A row for `track_meta` with the full column set every time — a
    multi-row upsert needs every dict to carry the same keys."""
    row = {"sc_track_id": tid, "checked_at": when, "matched": bool(match)}
    row.update({c: None for c in _META_COLS})
    if match:
        row.update(
            spotify_id=match["spotify_id"],
            title=match["title"],
            artist_name=match["artist_name"],
            artist_id=match.get("artist_id"),
            album=match.get("album"),
            album_id=match.get("album_id"),
            cover_url=match.get("cover_url"),
        )
    return row


def _cover(meta: TrackMeta, fallback: str | None) -> str | None:
    return meta.cover_url or fallback


async def enrich(rows: list, *, name_of, id_of, apply, hide_unmatched: bool) -> list:
    """Generic enrichment over a list of anything track-shaped.

    - ``id_of(row)``   -> the SoundCloud track id
    - ``name_of(row)`` -> (artist_name, title, duration_seconds)
    - ``apply(row, meta)`` -> mutate/replace the row with Spotify fields

    Returns the list with unmatched rows dropped when ``hide_unmatched``.
    """
    if not rows or not await spotify_meta.available():
        return rows

    ids = [id_of(r) for r in rows if id_of(r)]
    if not ids:
        return rows

    try:
        async with SessionLocal() as session:
            found = {
                m.sc_track_id: m
                for m in (
                    await session.scalars(
                        select(TrackMeta).where(TrackMeta.sc_track_id.in_(ids))
                    )
                ).all()
            }
    except Exception:  # noqa: BLE001
        logger.warning("catalog_meta.enrich: cache read failed", exc_info=True)
        return rows

    missing: list[tuple[str, str, str, float]] = []
    out: list = []
    # Two different SoundCloud uploads of the same song both resolve to one
    # Spotify track, and after enrichment they render as identical rows. Keep
    # the first and drop the rest.
    seen_spotify: set[str] = set()

    for row in rows:
        tid = id_of(row)
        meta = found.get(tid)

        if meta is None:
            artist, title, dur = name_of(row)
            if tid and len(missing) < _MAX_SCHEDULED:
                missing.append((tid, artist, title, dur))
            out.append(row)  # unchecked — leave it as-is, show it
            continue

        if meta.matched:
            if meta.spotify_id:
                if meta.spotify_id in seen_spotify:
                    continue
                seen_spotify.add(meta.spotify_id)
            apply(row, meta)
            out.append(row)
        elif not hide_unmatched:
            out.append(row)
        # else: matched is False and we hide it

    if missing:
        _schedule(missing)

    return out


def _schedule(items: list[tuple[str, str, str, float]]) -> None:
    fresh = [i for i in items if i[0] not in _inflight]
    if not fresh:
        return
    for tid, *_ in fresh:
        _inflight.add(tid)
    asyncio.create_task(_resolve_batch(fresh))


async def _resolve_batch(items: list[tuple[str, str, str, float]]) -> None:
    now = datetime.now(UTC)
    resolved: list[dict] = []
    try:
        for tid, artist, title, dur in items:
            try:
                match = await spotify_meta.match_track(artist, title, dur)
            except Exception:  # noqa: BLE001
                match = None
            resolved.append(_meta_row(tid, now, match))

        if resolved:
            async with SessionLocal() as session:
                stmt = pg_insert(TrackMeta).values(resolved)
                stmt = stmt.on_conflict_do_update(
                    index_elements=["sc_track_id"],
                    set_={
                        c: stmt.excluded[c]
                        for c in ("matched", "checked_at", *_META_COLS)
                    },
                )
                await session.execute(stmt)
                await session.commit()
    except Exception:  # noqa: BLE001
        logger.warning("catalog_meta._resolve_batch failed", exc_info=True)
    finally:
        for tid, *_ in items:
            _inflight.discard(tid)


# ─────────────────────────────────────────────────────────────────────────────
# Convenience wrappers for the two shapes the app uses
# ─────────────────────────────────────────────────────────────────────────────


def apply_catalog_track(t, m: TrackMeta) -> None:
    """Overlay Spotify fields onto a `CatalogTrack` (search / wave / feed)."""
    if m.title:
        t.title = m.title
    if m.artist_name:
        t.artist_name = m.artist_name
    if m.artist_id:
        t.artist_id = m.artist_id
    cover = _cover(m, t.artwork_url)
    if cover:
        t.artwork_url = cover


def apply_track_out(t, m: TrackMeta) -> None:
    """Overlay Spotify fields onto a `TrackOut` (favourites / playlist items)."""
    if m.title:
        t.title = m.title
    if m.artist_name:
        t.artist_name = m.artist_name
    if m.artist_id:
        t.artist_id = m.artist_id
    if m.album:
        t.album_title = m.album
    if m.album_id:
        t.album_id = m.album_id
    cover = _cover(m, t.cover_url)
    if cover:
        t.cover_url = cover


async def enrich_catalog_tracks(tracks: list, *, hide_unmatched: bool = True) -> list:
    """For `CatalogTrack` pydantic models (search, wave, feed)."""
    return await enrich(
        tracks,
        id_of=lambda t: t.id,
        name_of=lambda t: (t.artist_name or "", t.title or "", t.duration_seconds or 0),
        apply=apply_catalog_track,
        hide_unmatched=hide_unmatched,
    )


async def enrich_playlist_detail(detail, *, hide_unmatched: bool = True):
    """For `PlaylistDetailOut` — enriches `.items[].track` in place."""
    detail.items = await enrich(
        detail.items,
        id_of=lambda it: it.track.track_id if it.track else "",
        name_of=lambda it: (
            (it.track.artist_name, it.track.title, it.track.duration_seconds)
            if it.track else ("", "", 0)
        ),
        apply=lambda it, m: apply_track_out(it.track, m),
        hide_unmatched=hide_unmatched,
    )
    detail.track_count = len(detail.items)
    return detail
