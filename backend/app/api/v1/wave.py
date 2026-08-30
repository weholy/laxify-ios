"""Personal wave and the home feed — modelled on how Yandex's rotor works.

Yandex's "Моя волна" is not a ranking that gets recomputed; it is a *session*.
The station hands out a short batch of tracks and a batch id, then listens for
feedback — track started, track finished with a play time, track skipped — and
reshapes what comes next from that feedback *within the same sitting*. Settings
(mood/energy, familiar vs. new, language) change the tail without interrupting
the current track. Skips are rate-limited.

We can't call that station: it answers 451 to every IP that isn't Russian, and
our server is in Frankfurt. So this module is our own implementation of the
same behaviour on top of SoundCloud's track-station engine:

* ``POST /wave/start``     opens a session, returns the first batch + its id
* ``POST /wave/next``      advances the chain, tops the buffer back up
* ``POST /wave/feedback``  trackStarted / trackFinished / skip / like / dislike
* ``POST /wave/settings``  changes mood/diversity/language/activity, reshapes tail
* ``GET  /wave/feed``      the home feed — Плейлист дня, Дежавю, Премьера, Тайник…

The session is a row (``wave_sessions``); its id is the ``batchId`` the client
already passes around. A skip or a dislike suppresses that artist for the rest
of the session and purges them from the queued tail; a finish in full becomes a
seed for the next top-up. That is what makes it feel like a wave that is
listening back, rather than a playlist that was decided in advance.
"""

import asyncio
import random
import re
import time
from datetime import UTC, date, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import delete, desc, func, select

from app.api.deps import CurrentUser, SessionDep
from app.api.v1.catalog import CatalogTrack, normalise_track
from app.models import (
    DislikedTrack,
    Favorite,
    ListeningEvent,
    TrackSnapshot,
    WaveSession,
)
from app.services import authenticity
from app.services.playability import filter_playable
from app.services.soundcloud import SoundCloudError, soundcloud

router = APIRouter(prefix="/wave", tags=["wave"])

# How many tracks a full buffer holds, and when to refill it.
BUFFER_TARGET = 45
BUFFER_REFILL_BELOW = 22

SEED_LIMIT = 12
RECENT_EXCLUSION_DAYS = 3

# Yandex limits free skips to a handful an hour. We aren't gating a
# subscription — the cap only exists so a burst of angry skips doesn't tear the
# mix apart. Over it, the skip still works; it just stops suppressing artists.
SKIPS_PER_HOUR = 30

# A finish only counts as a real "I liked this" seed past this share of the
# track — anything less is a sample, not a listen.
FINISH_SHARE = 0.75

DISCOVERY_GENRES = ["hiphoprap", "pop", "electronic", "rnb", "rock", "dance"]

# What each mood/energy setting biases the mix towards. SoundCloud has no mood
# of its own, so this is a genre and tag lean — matching tracks move to the
# front, nothing is filtered out.
MOOD_GENRES = {
    "fun": ["dance", "pop", "danceedm", "house", "funk", "disco"],
    "active": ["electronic", "dubstep", "drumbass", "trap", "phonk", "hardstyle"],
    "calm": ["ambient", "chill", "classical", "jazzblues", "acoustic", "lofi"],
    "sad": ["indie", "alternativerock", "rnb", "folksingersongwriter", "emo", "slowcore"],
}

# The "по занятию" axis Yandex runs as its own stations. Same idea: a lean,
# not a filter.
ACTIVITY_GENRES = {
    "sleep": ["ambient", "sleep", "piano", "lofi", "meditation", "calm", "drone", "chill"],
    "workout": ["workout", "gym", "phonk", "trap", "edm", "drumbass", "hardstyle", "running", "hype"],
    "commute": ["pop", "rock", "indie", "roadtrip", "hits", "throwback", "singalong"],
    "focus": ["instrumental", "lofi", "study", "focus", "ambient", "postrock", "classical", "beats"],
}

DEFAULT_SETTINGS = {
    "mood_energy": "all",
    "diversity": "default",
    "language": "any",
    "activity": "none",
}

_CYRILLIC = re.compile(r"[а-яё]", re.IGNORECASE)
_RU_GENRE_HINT = re.compile(r"\b(rus|russ|русск|рус|cis|снг)\b", re.IGNORECASE)


# ─────────────────────────────────────────────────────────────────────────────
# Request / response shapes
# ─────────────────────────────────────────────────────────────────────────────


class WaveSettingsIn(BaseModel):
    mood_energy: str | None = Field(None, pattern="^(all|fun|active|calm|sad)$")
    diversity: str | None = Field(None, pattern="^(default|favorite|popular|discover)$")
    language: str | None = Field(None, pattern="^(any|russian|not-russian)$")
    activity: str | None = Field(None, pattern="^(none|sleep|workout|commute|focus)$")


class WaveStartIn(BaseModel):
    settings: WaveSettingsIn | None = None


class WaveNextIn(BaseModel):
    session_id: str
    last_track_id: str | None = None


class WaveFeedbackIn(BaseModel):
    session_id: str
    type: str = Field(pattern="^(trackStarted|trackFinished|skip|like|dislike)$")
    track_id: str | None = None
    played_seconds: float | None = Field(None, ge=0)
    duration_seconds: float | None = Field(None, ge=0)


class WaveSettingsPatch(WaveSettingsIn):
    session_id: str


class WaveSessionResponse(BaseModel):
    session_id: str
    tracks: list[CatalogTrack]
    settings: dict
    skips_per_hour: int
    skips_available: int
    is_personalised: bool


class WaveFeedbackResponse(BaseModel):
    ok: bool = True
    skips_available: int


class WaveResponse(BaseModel):
    tracks: list[CatalogTrack]
    seed_track_ids: list[str]
    is_personalised: bool


class FeedBlock(BaseModel):
    id: str
    # "playlist" — one thing you press play on; "shelf" — a row you browse.
    type: str
    title: str
    subtitle: str | None = None
    tracks: list[CatalogTrack]


class FeedResponse(BaseModel):
    blocks: list[FeedBlock]
    generated_at: datetime


class HomeResponse(BaseModel):
    wave: list[CatalogTrack]
    for_you: list[CatalogTrack]
    charts: list[CatalogTrack]


# ─────────────────────────────────────────────────────────────────────────────
# Taste profile — the seeds a run is grown from
# ─────────────────────────────────────────────────────────────────────────────


async def _seed_track_ids(session, user_id, *, extra: list[str] | None = None) -> list[str]:
    """Track ids to seed stations from: this session's finishes first, then
    recent likes, then recent plays."""
    seeds: list[str] = list(extra or [])

    liked = (
        await session.scalars(
            select(Favorite.track_id)
            .where(Favorite.user_id == user_id)
            .order_by(desc(Favorite.added_at))
            .limit(SEED_LIMIT)
        )
    ).all()

    played = (
        await session.scalars(
            select(ListeningEvent.track_id)
            .where(ListeningEvent.user_id == user_id, ListeningEvent.seconds_played >= 30)
            .order_by(desc(ListeningEvent.played_at))
            .limit(SEED_LIMIT * 3)
        )
    ).all()

    for track_id in list(liked) + list(played):
        if track_id and track_id not in seeds:
            seeds.append(track_id)
        if len(seeds) >= SEED_LIMIT:
            break

    return seeds


async def _taste_artist_ids(session, user_id) -> set[str]:
    """Artists the listener actually returns to — used to tell familiar from
    new, and to seed the feed's "new from artists you follow" row."""
    fav_artists = (
        await session.scalars(
            select(TrackSnapshot.artist_id)
            .join(Favorite, Favorite.track_id == TrackSnapshot.track_id)
            .where(Favorite.user_id == user_id, TrackSnapshot.artist_id.is_not(None))
        )
    ).all()

    heard_artists = (
        await session.scalars(
            select(ListeningEvent.artist_id)
            .where(
                ListeningEvent.user_id == user_id,
                ListeningEvent.artist_id.is_not(None),
                ListeningEvent.seconds_played >= 45,
            )
            .order_by(desc(ListeningEvent.played_at))
            .limit(400)
        )
    ).all()

    return {a for a in list(fav_artists) + list(heard_artists) if a}


async def _excluded_track_ids(session, user_id) -> set[str]:
    disliked = set(
        (
            await session.scalars(
                select(DislikedTrack.track_id).where(DislikedTrack.user_id == user_id)
            )
        ).all()
    )
    cutoff = datetime.now(UTC) - timedelta(days=RECENT_EXCLUSION_DAYS)
    recent = set(
        (
            await session.scalars(
                select(ListeningEvent.track_id).where(
                    ListeningEvent.user_id == user_id,
                    ListeningEvent.played_at >= cutoff,
                )
            )
        ).all()
    )
    return disliked | recent


# ─────────────────────────────────────────────────────────────────────────────
# Sourcing tracks
# ─────────────────────────────────────────────────────────────────────────────


def _rotating_genres(count: int) -> list[str]:
    """Genres for the current 15-minute window, so back-to-back requests reuse
    warm results instead of each paying to verify a fresh batch."""
    window = int(time.time() // 900)
    start = window % len(DISCOVERY_GENRES)
    return [DISCOVERY_GENRES[(start + offset) % len(DISCOVERY_GENRES)] for offset in range(count)]


async def _discovery_tracks(limit: int) -> list[dict]:
    """Popular music, for when there is no history to build a station from."""
    collected: list[dict] = []
    seen: set[str] = set()

    def take(items: list[dict]) -> None:
        for raw in items:
            track_id = str(raw.get("id"))
            if track_id and track_id not in seen:
                seen.add(track_id)
                collected.append(raw)

    take(await soundcloud.charts(limit=limit * 2))
    if len(collected) < limit:
        for genre in _rotating_genres(3):
            take(await soundcloud.genre_tracks(genre, limit=limit))
            if len(collected) >= limit:
                break
    return collected[:limit]


async def _station_pool(seeds: list[str], want: int) -> list[dict]:
    """Raw SoundCloud tracks from the stations of several seeds at once."""
    if not seeds:
        return []

    per_seed = max(8, (want * 2) // max(len(seeds), 1))
    sem = asyncio.Semaphore(6)

    async def one(seed: str) -> list[dict]:
        async with sem:
            try:
                return await soundcloud.station_tracks(seed, limit=40)
            except SoundCloudError:
                return []

    batches = await asyncio.gather(*(one(seed) for seed in seeds))

    pool: list[dict] = []
    seen: set[str] = set()
    for batch in batches:
        taken = 0
        for raw in batch:
            track_id = str(raw.get("id"))
            if not track_id or track_id in seen:
                continue
            seen.add(track_id)
            pool.append(raw)
            taken += 1
            if taken >= per_seed:
                break
    return pool


# ─────────────────────────────────────────────────────────────────────────────
# Shaping — turning a raw pool into a run that honours the settings
# ─────────────────────────────────────────────────────────────────────────────


def _text_of(raw: dict) -> str:
    user = raw.get("user") or {}
    return " ".join(
        str(part).lower()
        for part in (
            raw.get("title"),
            raw.get("genre"),
            raw.get("tag_list"),
            user.get("username"),
        )
        if part
    )


def _is_russian(raw: dict) -> bool:
    user = raw.get("user") or {}
    name = f"{raw.get('title') or ''} {user.get('username') or ''}"
    if _CYRILLIC.search(name):
        return True
    return bool(_RU_GENRE_HINT.search(_text_of(raw)))


def _bias_to_front(items: list[dict], wanted: list[str]) -> list[dict]:
    """Stable partition: tracks matching any wanted genre/tag keep their order
    but move ahead of the ones that don't."""
    if not wanted:
        return items
    flat = [w.replace("-", "") for w in wanted]

    def matches(raw: dict) -> bool:
        text = _text_of(raw).replace(" ", "").replace("-", "")
        return any(w in text for w in flat)

    lead = [r for r in items if matches(r)]
    rest = [r for r in items if not matches(r)]
    return lead + rest


def _apply_language(items: list[dict], language: str) -> list[dict]:
    if language == "russian":
        keep = [r for r in items if _is_russian(r)]
        return keep or items
    if language == "not-russian":
        keep = [r for r in items if not _is_russian(r)]
        return keep or items
    return items


def _apply_diversity(
    items: list[dict], diversity: str, taste_artists: set[str], rng: random.Random
) -> list[dict]:
    plays = lambda raw: raw.get("playback_count") or 0
    known = lambda raw: str((raw.get("user") or {}).get("id") or "") in taste_artists

    if diversity == "popular":
        return sorted(items, key=plays, reverse=True)
    if diversity == "favorite":
        return sorted(items, key=lambda r: (known(r), -plays(r)), reverse=True)
    if diversity == "discover":
        # Least familiar and least played first.
        return sorted(items, key=lambda r: (known(r), plays(r)))
    rng.shuffle(items)
    return items


def _spread_artists(items: list[dict], max_per_artist: int = 2) -> list[dict]:
    """One artist can't take over the run — extras go to the back rather than
    being dropped, so a narrow library still fills a full buffer."""
    counts: dict[str, int] = {}
    lead: list[dict] = []
    trail: list[dict] = []
    for raw in items:
        artist = str((raw.get("user") or {}).get("id") or "")
        if counts.get(artist, 0) < max_per_artist:
            counts[artist] = counts.get(artist, 0) + 1
            lead.append(raw)
        else:
            trail.append(raw)
    return lead + trail


async def _shape(
    db_session,
    pool: list[dict],
    *,
    settings: dict,
    taste_artists: set[str],
    exclude_ids: set[str],
    suppressed_artists: set[str],
    want: int,
    rng: random.Random,
) -> list[CatalogTrack]:
    """The full pipeline from raw pool to a finished run of CatalogTracks."""
    fresh = [
        raw
        for raw in pool
        if str(raw.get("id")) not in exclude_ids
        and str((raw.get("user") or {}).get("id") or "") not in suppressed_artists
    ]

    # Hide accounts that only borrow a real artist's name — the same test the
    # rest of the catalogue uses. It no-ops until the reference list is big
    # enough, and backs off if it would empty the run.
    try:
        fresh = await authenticity.filter_tracks(db_session, fresh)
    except Exception:  # noqa: BLE001 — the reference pass is best-effort
        pass

    fresh = _apply_language(fresh, settings.get("language", "any"))
    fresh = _bias_to_front(fresh, ACTIVITY_GENRES.get(settings.get("activity", "none"), []))
    fresh = _bias_to_front(fresh, MOOD_GENRES.get(settings.get("mood_energy", "all"), []))
    fresh = _apply_diversity(fresh, settings.get("diversity", "default"), taste_artists, rng)
    fresh = _spread_artists(fresh)
    fresh = await filter_playable(fresh, want)

    return [t for t in (normalise_track(raw) for raw in fresh) if t][:want]


# ─────────────────────────────────────────────────────────────────────────────
# Session assembly
# ─────────────────────────────────────────────────────────────────────────────


def _merged_settings(base: dict | None, patch: WaveSettingsIn | None) -> dict:
    out = dict(DEFAULT_SETTINGS)
    out.update(base or {})
    if patch:
        for key, value in patch.model_dump().items():
            if value is not None:
                out[key] = value
    return out


def _skips_available(skips: list[str]) -> int:
    cutoff = datetime.now(UTC) - timedelta(hours=1)
    live = [s for s in skips if _parse(s) and _parse(s) > cutoff]
    return max(0, SKIPS_PER_HOUR - len(live))


def _parse(value: str) -> datetime | None:
    """Lenient datetime parse for our own ISO timestamps and SoundCloud's
    ``2024/01/15 12:00:00 +0000`` style, both of which turn up here."""
    if not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    for candidate in (text, text.replace("/", "-", 2).replace(" +", "+", 1).replace(" ", "T", 1)):
        try:
            dt = datetime.fromisoformat(candidate)
            return dt if dt.tzinfo else dt.replace(tzinfo=UTC)
        except (TypeError, ValueError):
            continue
    return None


async def _fill(
    db,
    user_id,
    sess: WaveSession,
    *,
    want: int,
) -> list[dict]:
    """Produce `want` fresh CatalogTrack dicts for the queue, honouring
    everything the session has learned so far."""
    settings = sess.settings or dict(DEFAULT_SETTINGS)
    served = set(sess.served or [])
    suppressed = set(sess.suppressed or [])
    boosted = list(sess.boosted or [])
    favored = list(sess.favored or [])

    seeds = await _seed_track_ids(db, user_id, extra=boosted + favored)
    exclude = served | await _excluded_track_ids(db, user_id)
    taste_artists = await _taste_artist_ids(db, user_id)

    pool = await _station_pool(seeds, want * 3)
    if len({str(r.get("id")) for r in pool} - exclude) < want:
        pool += await _discovery_tracks(want * 2)

    rng = random.Random(f"{user_id}:{len(sess.served or [])}:{int(time.time() // 900)}")
    tracks = await _shape(
        db,
        pool,
        settings=settings,
        taste_artists=taste_artists,
        exclude_ids=exclude,
        suppressed_artists=suppressed,
        want=want,
        rng=rng,
    )
    return [t.model_dump() for t in tracks]


async def _load(db, session_id: str, user_id) -> WaveSession | None:
    try:
        sid = UUID(session_id)
    except (ValueError, TypeError):
        return None
    sess = await db.get(WaveSession, sid)
    if sess is None or sess.user_id != user_id:
        return None
    return sess


async def _open_session(db, user_id, settings: dict) -> WaveSession:
    """Replace any running wave with a fresh one and fill its first buffer."""
    await db.execute(delete(WaveSession).where(WaveSession.user_id == user_id))
    sess = WaveSession(
        user_id=user_id,
        settings=settings,
        queue=[],
        history=[],
        suppressed=[],
        favored=[],
        boosted=[],
        served=[],
        skips=[],
    )
    db.add(sess)
    await db.flush()

    sess.queue = await _fill(db, user_id, sess, want=BUFFER_TARGET)
    sess.served = [t["id"] for t in sess.queue]
    await db.flush()
    return sess


def _response(sess: WaveSession, tracks: list[dict], *, personalised: bool) -> WaveSessionResponse:
    return WaveSessionResponse(
        session_id=str(sess.id),
        tracks=[CatalogTrack(**t) for t in tracks],
        settings=sess.settings or dict(DEFAULT_SETTINGS),
        skips_per_hour=SKIPS_PER_HOUR,
        skips_available=_skips_available(sess.skips or []),
        is_personalised=personalised,
    )


# ─────────────────────────────────────────────────────────────────────────────
# Endpoints — the rotor
# ─────────────────────────────────────────────────────────────────────────────


@router.post("/start", response_model=WaveSessionResponse)
async def start_wave(
    user: CurrentUser,
    session: SessionDep,
    payload: WaveStartIn | None = None,
) -> WaveSessionResponse:
    settings = _merged_settings(None, payload.settings if payload else None)
    sess = await _open_session(session, user.id, settings)
    await session.commit()

    had_seeds = bool(await _seed_track_ids(session, user.id))
    return _response(sess, sess.queue, personalised=had_seeds)


@router.post("/next", response_model=WaveSessionResponse)
async def next_batch(
    user: CurrentUser,
    session: SessionDep,
    payload: WaveNextIn,
) -> WaveSessionResponse:
    sess = await _load(session, payload.session_id, user.id)
    if sess is None:
        # The session lapsed (restart, eviction). Start a fresh one rather than
        # make the client handle it — from the listener's side the wave just
        # keeps going.
        sess = await _open_session(session, user.id, dict(DEFAULT_SETTINGS))
        await session.commit()
        return _response(sess, sess.queue, personalised=True)

    queue = list(sess.queue or [])
    if payload.last_track_id:
        # Everything up to and including the track the client just left is
        # consumed.
        idx = next(
            (i for i, t in enumerate(queue) if t.get("id") == payload.last_track_id), -1
        )
        if idx >= 0:
            queue = queue[idx + 1 :]

    if len(queue) < BUFFER_REFILL_BELOW:
        sess.queue = queue
        sess.served = list({*(sess.served or []), *[t["id"] for t in queue]})
        added = await _fill(session, user.id, sess, want=BUFFER_TARGET - len(queue))
        queue = queue + added

    sess.queue = queue
    sess.served = list({*(sess.served or []), *[t["id"] for t in queue]})
    await session.commit()

    return _response(sess, queue, personalised=True)


@router.post("/feedback", response_model=WaveFeedbackResponse)
async def wave_feedback(
    user: CurrentUser,
    session: SessionDep,
    payload: WaveFeedbackIn,
) -> WaveFeedbackResponse:
    sess = await _load(session, payload.session_id, user.id)
    if sess is None:
        # Feedback for a wave that no longer exists is safe to drop.
        return WaveFeedbackResponse(skips_available=SKIPS_PER_HOUR)

    now = datetime.now(UTC)
    history = list(sess.history or [])
    history.append(
        {
            "trackId": payload.track_id,
            "event": payload.type,
            "seconds": payload.played_seconds,
            "at": now.isoformat(),
        }
    )
    sess.history = history[-80:]

    queue = list(sess.queue or [])
    artist_of = {t.get("id"): t.get("artist_id") for t in queue}
    target_artist = artist_of.get(payload.track_id)

    if payload.type in ("skip", "dislike"):
        skips = [s for s in (sess.skips or []) if _parse(s) and _parse(s) > now - timedelta(hours=1)]
        if payload.type == "skip":
            skips.append(now.isoformat())
        sess.skips = skips

        # Under the hourly limit, a skip/dislike pushes that artist out of the
        # rest of the session and clears them from the queued tail. Over it, the
        # skip still works but stops reshaping — so a burst of frustrated taps
        # doesn't hollow out the mix.
        within_limit = len(skips) <= SKIPS_PER_HOUR or payload.type == "dislike"
        if target_artist and within_limit:
            sess.suppressed = list({*(sess.suppressed or []), target_artist})
            sess.queue = [t for t in queue if t.get("artist_id") != target_artist]

    elif payload.type == "trackFinished":
        dur = payload.duration_seconds or 0
        played = payload.played_seconds or 0
        if payload.track_id and (dur <= 0 or played >= dur * FINISH_SHARE):
            sess.boosted = list({*(sess.boosted or []), payload.track_id})[-12:]

    elif payload.type == "like":
        if target_artist:
            sess.favored = list({*(sess.favored or []), target_artist})[-12:]

    await session.commit()
    return WaveFeedbackResponse(skips_available=_skips_available(sess.skips or []))


@router.post("/settings", response_model=WaveSessionResponse)
async def change_settings(
    user: CurrentUser,
    session: SessionDep,
    payload: WaveSettingsPatch,
) -> WaveSessionResponse:
    sess = await _load(session, payload.session_id, user.id)
    patch = WaveSettingsIn(**payload.model_dump(exclude={"session_id"}))

    if sess is None:
        sess = await _open_session(session, user.id, _merged_settings(None, patch))
        await session.commit()
        return _response(sess, sess.queue, personalised=True)

    sess.settings = _merged_settings(sess.settings, patch)

    # Keep whatever is playing (the head of the queue), reshape the rest — the
    # way Yandex's settings take effect without a gap.
    queue = list(sess.queue or [])
    head = queue[:1]
    sess.queue = head
    sess.served = list({*(sess.served or []), *[t["id"] for t in head]})
    tail = await _fill(session, user.id, sess, want=BUFFER_TARGET - len(head))
    sess.queue = head + tail
    sess.served = list({*(sess.served or []), *[t["id"] for t in sess.queue]})
    await session.commit()

    return _response(sess, sess.queue, personalised=True)


# ─────────────────────────────────────────────────────────────────────────────
# Endpoints — stateless wave (kept for older clients) and "similar"
# ─────────────────────────────────────────────────────────────────────────────


@router.get("", response_model=WaveResponse)
async def personal_wave(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(40, ge=5, le=80),
    exclude_recent: bool = Query(True),
    mood: str = Query("all", pattern="^(all|fun|active|calm|sad)$"),
    diversity: str = Query("default", pattern="^(default|favorite|popular|discover)$"),
    language: str = Query("any", pattern="^(any|russian|not-russian)$"),
    activity: str = Query("none", pattern="^(none|sleep|workout|commute|focus)$"),
    seed: str | None = Query(None, max_length=64),
) -> WaveResponse:
    """A one-shot wave with no session behind it. The app uses the /start and
    /next pair now; this stays for the home-screen preview and old builds."""
    seeds = [seed] if seed else await _seed_track_ids(session, user.id)
    exclude = await _excluded_track_ids(session, user.id) if exclude_recent else set()
    taste_artists = await _taste_artist_ids(session, user.id)

    pool = await _station_pool(seeds, limit * 3)
    if len({str(r.get("id")) for r in pool} - exclude) < limit:
        pool += await _discovery_tracks(limit * 2)

    if not pool:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Не удалось собрать волну, попробуйте позже",
        )

    rng = random.Random(f"{user.id}:{int(time.time() // 900)}")
    tracks = await _shape(
        session,
        pool,
        settings={
            "mood_energy": mood,
            "diversity": diversity,
            "language": language,
            "activity": activity,
        },
        taste_artists=taste_artists,
        exclude_ids=exclude,
        suppressed_artists=set(),
        want=limit,
        rng=rng,
    )

    return WaveResponse(
        tracks=tracks,
        seed_track_ids=seeds,
        is_personalised=bool(seeds),
    )


@router.get("/similar/{track_id}", response_model=list[CatalogTrack])
async def similar(track_id: str, user: CurrentUser, limit: int = Query(30, ge=1, le=50)):
    """Tracks that sound like this one — used to keep playback going when a
    queue runs out."""
    try:
        raw = await soundcloud.station_tracks(track_id, limit=limit)
    except SoundCloudError as exc:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(exc)) from exc
    return [t for t in (normalise_track(item) for item in raw) if t]


# ─────────────────────────────────────────────────────────────────────────────
# The home feed — Плейлист дня, Дежавю, Премьера, Тайник, charts
# ─────────────────────────────────────────────────────────────────────────────


def _snapshot_track(snap: TrackSnapshot) -> CatalogTrack:
    return CatalogTrack(
        id=snap.track_id,
        title=snap.title,
        artist_id=snap.artist_id,
        artist_name=snap.artist_name,
        artwork_url=snap.cover_url,
        duration_seconds=snap.duration_seconds or 0,
        permalink=None,
        genre=snap.genre,
        playback_count=None,
    )


async def _block_playlist_of_the_day(
    session, user_id, pool: list[dict], rng: random.Random
) -> FeedBlock | None:
    """A personal set that is the same all day and different tomorrow."""
    tracks = await _shape(
        session,
        pool,
        settings=dict(DEFAULT_SETTINGS),
        taste_artists=await _taste_artist_ids(session, user_id),
        exclude_ids=set(),
        suppressed_artists=set(),
        want=40,
        rng=rng,
    )
    if len(tracks) < 8:
        return None
    return FeedBlock(
        id="playlist-of-the-day",
        type="playlist",
        title="Плейлист дня",
        subtitle="Собран сегодня под ваш вкус",
        tracks=tracks,
    )


async def _block_dejavu(session, user_id) -> FeedBlock | None:
    """Favourites that haven't been played in a month — the ones it's time to
    hear again."""
    month_ago = datetime.now(UTC) - timedelta(days=30)
    recent = select(ListeningEvent.track_id).where(
        ListeningEvent.user_id == user_id, ListeningEvent.played_at >= month_ago
    )
    snaps = (
        await session.scalars(
            select(TrackSnapshot)
            .join(Favorite, Favorite.track_id == TrackSnapshot.track_id)
            .where(Favorite.user_id == user_id, TrackSnapshot.track_id.not_in(recent))
            .order_by(desc(Favorite.added_at))
            .limit(24)
        )
    ).all()
    if len(snaps) < 5:
        return None
    return FeedBlock(
        id="dejavu",
        type="playlist",
        title="Дежавю",
        subtitle="Любимое, которое давно не звучало",
        tracks=[_snapshot_track(s) for s in snaps],
    )


async def _block_premiere(session, user_id) -> FeedBlock | None:
    """Recent uploads from the artists the listener keeps coming back to."""
    artist_ids = list(await _taste_artist_ids(session, user_id))[:6]
    if not artist_ids:
        return None

    sem = asyncio.Semaphore(4)
    cutoff = datetime.now(UTC) - timedelta(days=60)

    async def recent_for(aid: str) -> list[tuple[datetime, dict]]:
        async with sem:
            try:
                items = await soundcloud.user_tracks(aid, limit=8)
            except SoundCloudError:
                return []
        out = []
        for raw in items:
            created = _parse(raw.get("created_at") or raw.get("display_date") or "")
            if created and created >= cutoff:
                out.append((created, raw))
        return out

    groups = await asyncio.gather(*(recent_for(a) for a in artist_ids))
    dated = [pair for group in groups for pair in group]
    dated.sort(key=lambda pair: pair[0], reverse=True)
    flat = [raw for _, raw in dated]

    tracks = [t for t in (normalise_track(r) for r in flat) if t][:20]
    if len(tracks) < 4:
        return None
    return FeedBlock(
        id="premiere",
        type="shelf",
        title="Премьера",
        subtitle="Новое у ваших артистов",
        tracks=tracks,
    )


async def _block_hidden_gem(session, user_id, pool: list[dict]) -> FeedBlock | None:
    """Taste-matched tracks that almost nobody has played."""
    quiet = [
        raw
        for raw in pool
        if 300 <= (raw.get("playback_count") or 0) <= 40_000
    ]
    quiet.sort(key=lambda r: r.get("playback_count") or 0)
    tracks = [t for t in (normalise_track(r) for r in quiet) if t][:20]
    if len(tracks) < 5:
        return None
    return FeedBlock(
        id="hidden-gem",
        type="shelf",
        title="Тайник",
        subtitle="Редкое под ваш вкус",
        tracks=tracks,
    )


async def _block_charts() -> FeedBlock | None:
    raw = await soundcloud.charts(limit=40)
    tracks = [t for t in (normalise_track(r) for r in raw) if t]
    if not tracks:
        return None
    return FeedBlock(
        id="chart",
        type="playlist",
        title="Чарт",
        subtitle="Что слушают сейчас",
        tracks=tracks,
    )


async def _block_genre_mix() -> FeedBlock | None:
    genre = _rotating_genres(1)[0]
    raw = await soundcloud.genre_tracks(genre, limit=40)
    tracks = [t for t in (normalise_track(r) for r in raw) if t]
    if len(tracks) < 6:
        return None
    pretty = {
        "hiphoprap": "Хип-хоп и рэп",
        "pop": "Поп",
        "electronic": "Электроника",
        "rnb": "R&B",
        "rock": "Рок",
        "dance": "Танцевальное",
    }.get(genre, genre.title())
    return FeedBlock(
        id=f"genre:{genre}",
        type="shelf",
        title=pretty,
        subtitle="Подборка на сегодня",
        tracks=tracks,
    )


@router.get("/feed", response_model=FeedResponse)
async def home_feed(user: CurrentUser, session: SessionDep) -> FeedResponse:
    """The home screen, shaped like Yandex's: a personal playlist of the day up
    top, then rows that each mean something — forgotten favourites, new from
    your artists, quiet finds, the chart."""
    seeds = await _seed_track_ids(session, user.id)
    pool = await _station_pool(seeds, 120)
    if len(pool) < 40:
        pool += await _discovery_tracks(80)

    today = date.today().isoformat()
    day_rng = random.Random(f"{user.id}:{today}")

    blocks = await asyncio.gather(
        _block_playlist_of_the_day(session, user.id, list(pool), day_rng),
        _block_dejavu(session, user.id),
        _block_premiere(session, user.id),
        _block_hidden_gem(session, user.id, list(pool)),
        _block_charts(),
        _block_genre_mix(),
        return_exceptions=True,
    )

    ordered = [b for b in blocks if isinstance(b, FeedBlock)]
    return FeedResponse(blocks=ordered, generated_at=datetime.now(UTC))


@router.get("/home", response_model=HomeResponse)
async def home(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(30, ge=5, le=50),
) -> HomeResponse:
    """Older clients ask for three fixed rows. Serve them from the feed."""
    feed = await home_feed(user=user, session=session)
    by_id = {b.id: b.tracks for b in feed.blocks}

    wave = (by_id.get("playlist-of-the-day") or [])[:limit]
    for_you = (by_id.get("premiere") or by_id.get("dejavu") or by_id.get("hidden-gem") or [])[:limit]
    charts = (by_id.get("chart") or [])[:limit]

    if not wave:
        one_shot = await personal_wave(user=user, session=session, limit=limit)
        wave = one_shot.tracks

    return HomeResponse(wave=wave, for_you=for_you, charts=charts)
