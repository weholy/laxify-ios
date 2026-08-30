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

# How many of a listing's *first* rows to resolve before answering, and how
# long to spend doing it. Without this the first time a wave or feed row is
# built it renders the uploader's spelling and only looks right on a later
# refresh; with it, the part of the list a person actually sees is already
# correct. The rest is filled in the background as before.
_EAGER_ROWS = 12
_EAGER_BUDGET = 3.5

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

    found = await _cached(ids)
    if found is None:
        return rows

    # Resolve the first few unknowns before answering, so the top of the list
    # — the part actually on screen — carries clean names straight away.
    eager = [
        r for r in rows[: _EAGER_ROWS * 2]
        if id_of(r) and id_of(r) not in found
    ][:_EAGER_ROWS]
    if eager:
        await _resolve_now([(id_of(r), *name_of(r)) for r in eager])
        refreshed = await _cached([id_of(r) for r in eager])
        if refreshed:
            found.update(refreshed)

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


async def _cached(ids: list[str]) -> dict[str, TrackMeta] | None:
    """The `track_meta` rows for these ids, or None if the read failed."""
    if not ids:
        return {}
    try:
        async with SessionLocal() as session:
            return {
                m.sc_track_id: m
                for m in (
                    await session.scalars(
                        select(TrackMeta).where(TrackMeta.sc_track_id.in_(ids))
                    )
                ).all()
            }
    except Exception:  # noqa: BLE001
        logger.warning("catalog_meta: cache read failed", exc_info=True)
        return None


async def _resolve_now(items: list[tuple[str, str, str, float]]) -> None:
    """Resolve and persist, but never for longer than the eager budget."""
    fresh = [i for i in items if i[0] and i[0] not in _inflight]
    if not fresh:
        return
    for tid, *_ in fresh:
        _inflight.add(tid)
    try:
        await asyncio.wait_for(_resolve_batch(fresh), timeout=_EAGER_BUDGET)
    except TimeoutError:
        logger.info("catalog_meta: eager resolve budget hit (%d rows)", len(fresh))
    except Exception:  # noqa: BLE001
        logger.warning("catalog_meta: eager resolve failed", exc_info=True)


def _schedule(items: list[tuple[str, str, str, float]]) -> None:
    fresh = [i for i in items if i[0] not in _inflight]
    if not fresh:
        return
    for tid, *_ in fresh:
        _inflight.add(tid)
    asyncio.create_task(_resolve_batch(fresh))


async def _resolve_batch(items: list[tuple[str, str, str, float]]) -> None:
    now = datetime.now(UTC)
    # In parallel: each lookup is about a second, and doing a dozen in series
    # blew any budget a request could give it.
    sem = asyncio.Semaphore(8)

    async def one(entry: tuple[str, str, str, float]) -> dict | None:
        tid, artist, title, dur = entry
        async with sem:
            try:
                return _meta_row(tid, now, await spotify_meta.match_track(artist, title, dur))
            except Exception:  # noqa: BLE001
                return None

    try:
        results = await asyncio.gather(*(one(i) for i in items), return_exceptions=True)
        resolved = [r for r in results if isinstance(r, dict)]

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


async def spotify_only(tracks: list) -> list:
    """The single gate every SoundCloud-sourced listing passes through.

    A track the proper catalogue has never heard of does not reach the app at
    all; everything else is shown with Spotify's spelling and cover. This is
    what makes the catalogue look like one service rather than two.
    """
    return await enrich_catalog_tracks(tracks, hide_unmatched=True)


async def enrich_snapshot_rows(rows: list, *, id_of, apply, hide_unmatched: bool = False) -> list:
    """For anything built from `TrackSnapshot` — statistics, history.

    `apply(row, meta)` receives the row and its Spotify twin. Nothing is
    hidden by default: a play really happened, and dropping it would make the
    figures disagree with the history that produced them.
    """
    return await enrich(
        rows,
        id_of=id_of,
        name_of=lambda r: (
            getattr(r, "artist_name", "") or "",
            getattr(r, "title", "") or "",
            0,
        ),
        apply=apply,
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
