"""Clean track / artist / album / playlist metadata, from Spotify.

Spotify's official Web API now needs the app owner to hold Premium, and the
`sp_dc` token route is behind an hourly-rotating TOTP that datacentre IPs get
WAF-blocked from anyway. What still works is `SpotifyScraper`, which bootstraps
an anonymous token from Spotify's *embed* API (a different, un-fortified path)
and reads their internal GraphQL. No key, no cookie, no Premium.

It is a scraper, so it can break when Spotify changes their web player. Every
function here is therefore fail-open: on any error it returns nothing, and the
caller falls back to the SoundCloud metadata it already had. Nothing is ever
hidden because of a *failed* lookup — only because of a lookup that succeeded
and found no match.
"""

from __future__ import annotations

import logging
import re
import unicodedata

from starlette.concurrency import run_in_threadpool

logger = logging.getLogger("laxify.spotify_meta")

_client = None
_client_broken = False


def _get_client():
    """One shared client. The library refreshes its own token."""
    global _client, _client_broken
    if _client is not None or _client_broken:
        return _client
    try:
        from spotify_scraper import SpotifyClient

        _client = SpotifyClient(
            timeout=12.0,
            user_agent=(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            ),
        )
    except Exception:  # noqa: BLE001
        logger.exception("spotify_meta: client init failed — disabling")
        _client_broken = True
    return _client


# ─────────────────────────────────────────────────────────────────────────────
# Normalising the library's objects into plain JSON-safe dicts
# ─────────────────────────────────────────────────────────────────────────────


def _biggest(images) -> str | None:
    if not images:
        return None
    best = max(images, key=lambda im: (im.width or 0) * (im.height or 0) or 0)
    return best.url or (images[0].url if images else None)


def _spotify_id(uri: str | None, fallback: str = "") -> str:
    if uri and ":" in uri:
        return uri.rsplit(":", 1)[-1]
    return fallback or ""


def _artist_ref_names(artists) -> str:
    return ", ".join(a.name for a in (artists or []) if getattr(a, "name", None))


def _track_dict(tr) -> dict:
    primary = (tr.artists or [None])[0]
    return {
        "spotify_id": tr.id or _spotify_id(tr.uri),
        "title": tr.name or "",
        "artist_name": _artist_ref_names(tr.artists) or "",
        "artist_id": _spotify_id(getattr(primary, "uri", None), getattr(primary, "id", "") or ""),
        "album": (tr.album.name if getattr(tr, "album", None) else None),
        "album_id": _spotify_id(getattr(getattr(tr, "album", None), "uri", None)),
        "cover_url": _biggest(tr.images) or _biggest(getattr(getattr(tr, "album", None), "images", None)),
        "duration_ms": tr.duration_ms or 0,
        "explicit": bool(getattr(tr, "explicit", False)),
    }


def _artist_dict(a) -> dict:
    return {
        "id": a.id or _spotify_id(a.uri),
        "name": a.name or "",
        "image_url": _biggest(a.images),
        "followers": getattr(a, "followers", None),
        "genres": list(getattr(a, "genres", None) or []),
    }


def _album_dict(al) -> dict:
    return {
        "id": al.id or _spotify_id(al.uri),
        "title": al.name or "",
        "artist_name": _artist_ref_names(getattr(al, "artists", None)),
        "cover_url": _biggest(al.images),
        "year": (str(getattr(al, "release_date", "") or "")[:4] or None),
        "total_tracks": getattr(al, "total_tracks", None),
        "kind": getattr(al, "album_type", None),
    }


def _playlist_dict(p) -> dict:
    owner = getattr(p, "owner", None)
    return {
        "id": p.id or _spotify_id(p.uri),
        "title": p.name or "",
        "description": getattr(p, "description", None),
        "owner_name": getattr(owner, "name", None),
        "cover_url": _biggest(getattr(p, "images", None)),
        "track_count": getattr(p, "total_tracks", None) or 0,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Matching a SoundCloud track to its Spotify twin
# ─────────────────────────────────────────────────────────────────────────────

_JUNK = re.compile(
    r"\b(official|video|audio|lyrics?|lyric|hd|hq|remaster(ed)?|prod\.?\s*\w+|"
    r"visuali[sz]er|explicit|clean)\b",
    re.IGNORECASE,
)
_BRACKETS = re.compile(r"[\(\[\{].*?[\)\]\}]")


def _norm(text: str) -> str:
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch)).lower()
    text = _BRACKETS.sub(" ", text)
    text = _JUNK.sub(" ", text)
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return " ".join(text.split())


def _tokens(text: str) -> set[str]:
    return set(_norm(text).split())


def _score(cand: dict, artist: str, title: str, duration_s: float) -> float:
    ct, ca = _tokens(cand["title"]), _tokens(cand["artist_name"])
    wt, wa = _tokens(title), _tokens(artist)
    if not ct or not wt:
        return 0.0

    title_overlap = len(ct & wt) / len(ct | wt)
    artist_overlap = len(ca & wa) / max(len(wa or ca), 1) if (ca and wa) else 0.0

    score = title_overlap * 0.6 + artist_overlap * 0.3
    if duration_s and cand.get("duration_ms"):
        gap = abs(cand["duration_ms"] / 1000 - duration_s)
        if gap <= 4:
            score += 0.1
        elif gap <= 10:
            score += 0.05
        elif gap > 30:
            score -= 0.15
    # A "remix" / "cover" / "sped up" version is not the track the user saved.
    lowered = cand["title"].lower()
    if any(w in lowered for w in ("remix", "cover", "sped up", "slowed", "8d", "nightcore")) and not (
        "remix" in title.lower() or "cover" in title.lower()
    ):
        score -= 0.25
    return score


# ─────────────────────────────────────────────────────────────────────────────
# Public API — all async, all fail-open
# ─────────────────────────────────────────────────────────────────────────────


async def available() -> bool:
    return _get_client() is not None


async def search(query: str, limit: int = 12) -> dict:
    """Aggregate search: tracks / artists / albums / playlists as plain dicts."""
    client = _get_client()
    if client is None or not query.strip():
        return {"tracks": [], "artists": [], "albums": [], "playlists": []}

    def _run():
        res = client.search(
            query, types=("track", "artist", "album", "playlist"), limit=limit
        )
        return {
            "tracks": [_track_dict(t) for t in (res.tracks or [])],
            "artists": [_artist_dict(a) for a in (res.artists or [])],
            "albums": [_album_dict(a) for a in (res.albums or [])],
            "playlists": [_playlist_dict(p) for p in (res.playlists or [])],
        }

    try:
        return await run_in_threadpool(_run)
    except Exception:  # noqa: BLE001
        logger.warning("spotify_meta.search failed for %r", query, exc_info=True)
        return {"tracks": [], "artists": [], "albums": [], "playlists": []}


async def match_track(artist: str, title: str, duration_s: float = 0) -> dict | None:
    """The Spotify track that best matches this SoundCloud one, or None."""
    client = _get_client()
    if client is None or not title.strip():
        return None

    query = f"{artist} {title}".strip()

    def _run():
        res = client.search(query, types=("track",), limit=8)
        return [_track_dict(t) for t in (res.tracks or [])]

    try:
        cands = await run_in_threadpool(_run)
    except Exception:  # noqa: BLE001
        logger.warning("spotify_meta.match_track failed for %r", query, exc_info=True)
        return None

    if not cands:
        return None
    best = max(cands, key=lambda c: _score(c, artist, title, duration_s))
    return best if _score(best, artist, title, duration_s) >= 0.55 else None


async def artist(spotify_id: str) -> dict | None:
    client = _get_client()
    if client is None or not spotify_id:
        return None

    def _run():
        return _artist_dict(client.get_artist(f"https://open.spotify.com/artist/{spotify_id}"))

    try:
        return await run_in_threadpool(_run)
    except Exception:  # noqa: BLE001
        logger.warning("spotify_meta.artist failed for %s", spotify_id, exc_info=True)
        return None


async def artist_top_tracks(spotify_id: str) -> list[dict]:
    client = _get_client()
    if client is None or not spotify_id:
        return []

    def _run():
        a = client.get_artist(f"https://open.spotify.com/artist/{spotify_id}")
        return [_track_dict(t) for t in (getattr(a, "top_tracks", None) or [])]

    try:
        return await run_in_threadpool(_run)
    except Exception:  # noqa: BLE001
        return []


async def discography(spotify_id: str, limit: int = 30) -> list[dict]:
    """The artist's albums / singles as album dicts."""
    client = _get_client()
    if client is None or not spotify_id:
        return []

    def _run():
        items = client.get_discography(
            f"https://open.spotify.com/artist/{spotify_id}"
        )
        out = []
        for al in (items or [])[:limit]:
            try:
                out.append(_album_dict(al))
            except Exception:  # noqa: BLE001
                continue
        return out

    try:
        return await run_in_threadpool(_run)
    except Exception:  # noqa: BLE001
        return []


async def album(spotify_id: str) -> dict | None:
    client = _get_client()
    if client is None or not spotify_id:
        return None

    def _run():
        al = client.get_album(f"https://open.spotify.com/album/{spotify_id}")
        out = _album_dict(al)
        out["tracks"] = [_track_dict(t) for t in (getattr(al, "tracks", None) or [])]
        return out

    try:
        return await run_in_threadpool(_run)
    except Exception:  # noqa: BLE001
        logger.warning("spotify_meta.album failed for %s", spotify_id, exc_info=True)
        return None


async def playlist(spotify_id: str) -> dict | None:
    client = _get_client()
    if client is None or not spotify_id:
        return None

    def _run():
        p = client.get_playlist(f"https://open.spotify.com/playlist/{spotify_id}")
        out = _playlist_dict(p)
        out["tracks"] = [_track_dict(t) for t in (getattr(p, "tracks", None) or [])]
        return out

    try:
        return await run_in_threadpool(_run)
    except Exception:  # noqa: BLE001
        logger.warning("spotify_meta.playlist failed for %s", spotify_id, exc_info=True)
        return None
