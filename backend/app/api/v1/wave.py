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
import logging
import random
import re
import time
from datetime import UTC, date, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import delete, desc, func, or_, select

from app.api.deps import CurrentUser, SessionDep
from app.api.v1.catalog import CatalogTrack, normalise_track
from app.models import (
    DislikedTrack,
    Favorite,
    ListeningEvent,
    TrackMeta,
    TrackSnapshot,
    WaveSession,
)
from app.services import catalog_meta, tagging
from app.services.playability import filter_playable, report_unplayable
from app.services.soundcloud import SoundCloudError, soundcloud

logger = logging.getLogger("laxify.wave")

router = APIRouter(prefix="/wave", tags=["wave"])

# How many tracks a full buffer holds, and when to refill it.
BUFFER_TARGET = 45
BUFFER_REFILL_BELOW = 22

# How many recently-served ids to remember for de-duping. Past this the
# oldest are forgotten, so a long session can eventually replay something
# rather than run the buffer dry once the station pool is exhausted.
SERVED_CAP = 600

SEED_LIMIT = 8
RECENT_EXCLUSION_DAYS = 7

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
    """A few strong track ids to grow stations from.

    Fewer than before and better chosen: a track the listener actually
    *finished* recently is a far stronger "more like this" signal than a like
    from a year ago, so those come first, then recent likes, then any recent
    play. Session finishes / likes (``extra``) lead.
    """
    seeds: list[str] = list(dict.fromkeys(extra or []))
    month_ago = datetime.now(UTC) - timedelta(days=30)

    finished = (
        await session.scalars(
            select(ListeningEvent.track_id)
            .where(
                ListeningEvent.user_id == user_id,
                ListeningEvent.played_at >= month_ago,
                or_(ListeningEvent.completed.is_(True), ListeningEvent.seconds_played >= 60),
            )
            .order_by(desc(ListeningEvent.played_at))
            .limit(40)
        )
    ).all()

    liked = (
        await session.scalars(
            select(Favorite.track_id)
            .where(Favorite.user_id == user_id)
            .order_by(desc(Favorite.added_at))
            .limit(20)
        )
    ).all()

    played = (
        await session.scalars(
            select(ListeningEvent.track_id)
            .where(ListeningEvent.user_id == user_id, ListeningEvent.seconds_played >= 30)
            .order_by(desc(ListeningEvent.played_at))
            .limit(40)
        )
    ).all()

    for track_id in [*finished, *liked, *played]:
        if track_id and track_id not in seeds:
            seeds.append(track_id)
        if len(seeds) >= SEED_LIMIT:
            break

    return seeds[:SEED_LIMIT]


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


async def _taste_genres(session, user_id) -> list[str]:
    """The genres the listener plays most — used to keep the discovery
    fallback in their world instead of dropping to the global chart."""
    rows = (
        await session.execute(
            select(TrackSnapshot.genre, func.count().label("n"))
            .join(ListeningEvent, ListeningEvent.track_id == TrackSnapshot.track_id)
            .where(
                ListeningEvent.user_id == user_id,
                TrackSnapshot.genre.is_not(None),
                TrackSnapshot.genre != "",
            )
            .group_by(TrackSnapshot.genre)
            .order_by(desc("n"))
            .limit(5)
        )
    ).all()
    return [row[0] for row in rows if row[0]]



async def _taste_tags(session, user_id) -> list[str]:
    """The listener's taste as a handful of canonical tags, strongest first.

    Built from what they saved and what they finished, not from everything
    that ever played: a track skipped after ten seconds says nothing about
    taste, and letting it vote is how the wave drifts.

    A favourite counts three times, a completed play twice, an ordinary play
    once. The result is what the wave goes looking for — which is the whole
    point of tags: "more emo-rap, more of the quiet ones, in Russian" reaches
    a hundred artists, where "more of this artist" reaches one.
    """
    weights: dict[str, float] = {}

    def add(text: str, weight: float) -> None:
        for tag in tagging.derive({"title": text}):
            weights[tag] = weights.get(tag, 0) + weight

    favourites = (
        await session.execute(
            select(TrackSnapshot.title, TrackSnapshot.artist_name, TrackSnapshot.genre)
            .join(Favorite, Favorite.track_id == TrackSnapshot.track_id)
            .where(Favorite.user_id == user_id)
            .limit(200)
        )
    ).all()
    for title, artist, genre in favourites:
        add(f"{title} {artist} {genre or ''}", 3)

    cutoff = datetime.now(UTC) - timedelta(days=60)
    played = (
        await session.execute(
            select(
                TrackSnapshot.title,
                TrackSnapshot.artist_name,
                TrackSnapshot.genre,
                ListeningEvent.completed,
            )
            .join(ListeningEvent, ListeningEvent.track_id == TrackSnapshot.track_id)
            .where(ListeningEvent.user_id == user_id, ListeningEvent.played_at >= cutoff)
            .limit(500)
        )
    ).all()
    for title, artist, genre, completed in played:
        add(f"{title} {artist} {genre or ''}", 2 if completed else 1)

    # Language is derived for every single track, so it always wins on count
    # and would crowd out everything that actually describes the music. It is
    # useful, but as a hint rather than as the headline.
    ordered = sorted(weights.items(), key=lambda pair: pair[1], reverse=True)
    styles = [tag for tag, _ in ordered if tag not in ("ru", "en")]
    languages = [tag for tag, _ in ordered if tag in ("ru", "en")]

    return styles[:8] + languages[:1]

async def _excluded_track_ids(session, user_id) -> set[str]:
    """Disliked tracks always; tracks played in the last couple of days for
    freshness — but not the listener's own favourites, which a wave is allowed
    to bring back round now and then the way Yandex's does."""
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
    liked = set(
        (
            await session.scalars(
                select(Favorite.track_id).where(Favorite.user_id == user_id)
            )
        ).all()
    )
    return disliked | (recent - liked)


# ─────────────────────────────────────────────────────────────────────────────
# Sourcing tracks
# ─────────────────────────────────────────────────────────────────────────────


def _rotating_genres(count: int) -> list[str]:
    """Genres for the current 15-minute window, so back-to-back requests reuse
    warm results instead of each paying to verify a fresh batch."""
    window = int(time.time() // 900)
    start = window % len(DISCOVERY_GENRES)
    return [DISCOVERY_GENRES[(start + offset) % len(DISCOVERY_GENRES)] for offset in range(count)]


async def _discovery_tracks(limit: int, genres: list[str] | None = None) -> list[dict]:
    """Top-up when the stations come back thin.

    The listener's own top genres first, so a short history still keeps the
    wave in their lane; the rotating spread next; the global chart only as a
    last resort — dropping straight to the chart was most of why the wave
    drifted generic after a few refills.
    """
    collected: list[dict] = []
    seen: set[str] = set()

    def take(items: list[dict]) -> None:
        for raw in items:
            track_id = str(raw.get("id"))
            if track_id and track_id not in seen:
                seen.add(track_id)
                collected.append(raw)

    async def safe(coro) -> list[dict]:
        # The source throttles, and when it does every one of these raises.
        # A thin wave beats a wave that fails outright.
        try:
            return await coro
        except SoundCloudError:
            return []

    for genre in (genres or [])[:3]:
        take(await safe(soundcloud.genre_tracks(genre, limit=limit)))
        if len(collected) >= limit:
            return collected[:limit]

    for genre in _rotating_genres(3):
        take(await safe(soundcloud.genre_tracks(genre, limit=limit)))
        if len(collected) >= limit:
            return collected[:limit]

    if len(collected) < limit:
        take(await safe(soundcloud.charts(limit=limit * 2)))
    return collected[:limit]


async def _related_pool(taste_artists: set[str], want: int, *, budget: float = 2.5) -> list[dict]:
    """Tracks by artists adjacent to the ones the listener plays.

    A track station tends to answer with more of the same artist, so a wave
    built only from stations circles the library. This reaches one step out —
    the artists the source associates with theirs — which is where the
    unfamiliar half of the run comes from.
    """
    if not taste_artists:
        return []

    sem = asyncio.Semaphore(6)

    async def neighbours(artist_id: str) -> list[dict]:
        async with sem:
            try:
                related = await soundcloud.related_artists(artist_id, limit=6)
            except SoundCloudError:
                return []
        picks = [str(a["id"]) for a in related if a.get("id")][:3]
        out: list[dict] = []
        for other in picks:
            try:
                out += await soundcloud.user_tracks(other, limit=5)
            except SoundCloudError:
                continue
        return out

    seeds = list(taste_artists)[:5]
    tasks = [asyncio.create_task(neighbours(a)) for a in seeds]
    done, pending = await asyncio.wait(tasks, timeout=budget)
    for task in pending:
        task.cancel()

    pool: list[dict] = []
    seen: set[str] = set()
    for task in done:
        if task.cancelled() or task.exception() is not None:
            continue
        for raw in task.result():
            track_id = str(raw.get("id"))
            if track_id and track_id not in seen:
                seen.add(track_id)
                pool.append(raw)
    return pool[:want]


async def _known_pool(session, user_id, want: int, exclude: set[str]) -> list[dict]:
    """A pool built from tracks we already hold, for when the source is out.

    SoundCloud throttles, and when it does every station, chart and genre
    listing fails at once — which used to mean the wave simply refused to
    build. These are tracks already in the catalogue, so their ids still
    play; the ones the proper catalogue recognises come first.
    """
    rows = (
        await session.scalars(
            select(TrackSnapshot)
            .outerjoin(TrackMeta, TrackMeta.sc_track_id == TrackSnapshot.track_id)
            .where(TrackSnapshot.track_id.not_in(exclude) if exclude else True)
            .order_by(desc(TrackMeta.matched), desc(TrackSnapshot.created_at))
            .limit(want * 3)
        )
    ).all()

    # Shaped like a raw SoundCloud track, since that is what the pipeline
    # downstream expects.
    return [
        {
            "kind": "track",
            "id": row.track_id,
            "title": row.title,
            "genre": row.genre,
            "tag_list": "",
            "duration": (row.duration_seconds or 0) * 1000,
            "full_duration": (row.duration_seconds or 0) * 1000,
            "artwork_url": row.cover_url,
            "playback_count": None,
            "user": {"id": row.artist_id or "", "username": row.artist_name or ""},
            "publisher_metadata": {"artist": row.artist_name or ""},
        }
        for row in rows
    ]


async def _station_pool(seeds: list[str], want: int, *, budget: float = 3.0) -> list[dict]:
    """Raw SoundCloud tracks from the stations of several seeds at once.

    Pulls deep from each station and then *interleaves* the results, so the
    front of the pool is a round-robin across every seed rather than the top
    few of the first station — which on SoundCloud are usually the same
    artist several times over.

    Bounded: a seed whose station has gone quiet used to hold the whole home
    screen for six seconds and then contribute nothing. Whatever has arrived
    when the budget runs out is what the pool is built from.
    """
    if not seeds:
        return []

    per_seed = max(16, (want * 3) // max(len(seeds), 1))
    sem = asyncio.Semaphore(8)

    async def one(seed: str) -> list[dict]:
        async with sem:
            try:
                return await soundcloud.station_tracks(seed, limit=50)
            except SoundCloudError:
                return []

    tasks = [asyncio.create_task(one(seed)) for seed in seeds]
    done, pending = await asyncio.wait(tasks, timeout=budget)
    for task in pending:
        task.cancel()

    batches = [t.result() for t in done if not t.cancelled() and t.exception() is None]
    trimmed = [batch[:per_seed] for batch in batches]

    pool: list[dict] = []
    seen: set[str] = set()
    for rank in range(per_seed):
        for batch in trimmed:
            if rank >= len(batch):
                continue
            raw = batch[rank]
            track_id = str(raw.get("id"))
            if not track_id or track_id in seen:
                continue
            seen.add(track_id)
            pool.append(raw)
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


_TOKEN_SPLIT = re.compile(r"[\s,/|_\-]+")


def _bias_to_front(items: list[dict], wanted: list[str]) -> list[dict]:
    """Stable partition: tracks whose genre/tags contain one of `wanted` as a
    whole word keep their order but move ahead of the ones that don't.

    Whole word, not substring — "sad" was matching "sadie", "casa", "usada"…
    which is how the mood dials ended up meaning almost nothing.
    """
    if not wanted:
        return items
    wanted_set = {w.replace("-", "").lower() for w in wanted}

    def matches(raw: dict) -> bool:
        tokens = {t.replace("-", "") for t in _TOKEN_SPLIT.split(_text_of(raw)) if t}
        return bool(wanted_set & tokens)

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


# What share of a default run may be artists the listener already plays. A
# wave made only of those is a library on shuffle; one made only of strangers
# is a radio station. Yandex sits around here, and it is what makes theirs
# feel like a wave rather than a playlist.
FAMILIAR_SHARE = {
    "default": 0.4,
    "favorite": 0.75,
    "popular": 0.5,
    "discover": 0.15,
}


def _blend_familiar(
    items: list[dict], taste_artists: set[str], share: float
) -> list[dict]:
    """Interleave known and unknown artists to roughly the given share.

    Both sides keep the order they arrived in, so the closest-sounding track
    still leads its own group; only the alternation is imposed. Whichever side
    runs out, the other simply continues — a listener with no history gets all
    discovery, and one whose pool is entirely familiar still gets a full run.
    """
    known = [r for r in items if str((r.get("user") or {}).get("id") or "") in taste_artists]
    fresh = [r for r in items if str((r.get("user") or {}).get("id") or "") not in taste_artists]
    if not known or not fresh:
        return items

    out: list[dict] = []
    known_i = fresh_i = 0
    while known_i < len(known) or fresh_i < len(fresh):
        placed = len(out)
        want_known = (
            known_i < len(known)
            and (fresh_i >= len(fresh) or (placed * share) >= known_i)
        )
        if want_known:
            out.append(known[known_i])
            known_i += 1
        elif fresh_i < len(fresh):
            out.append(fresh[fresh_i])
            fresh_i += 1
        else:
            out.append(known[known_i])
            known_i += 1
    return out


def _apply_diversity(
    items: list[dict], diversity: str, taste_artists: set[str], rng: random.Random
) -> list[dict]:
    plays = lambda raw: raw.get("playback_count") or 0

    if diversity == "popular":
        items = sorted(items, key=plays, reverse=True)
    elif diversity == "discover":
        # Least played first, so the run leads with things unlikely to be
        # already known.
        items = sorted(items, key=plays)
    # "favorite" and "default" keep the order the stations returned — ranked
    # by how close a track sounds to the seeds. Shuffling that away was most
    # of why the wave felt random rather than "like what I was listening to".

    return _blend_familiar(items, taste_artists, FAMILIAR_SHARE.get(diversity, 0.4))


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


def _bias_by_tags(items: list[dict], taste: list[str]) -> list[dict]:
    """Move tracks that share tags with the listener to the front.

    Scored rather than partitioned: a track matching three of someone's tags
    should come before one matching a single tag, and both before one that
    matches none. Sorting is stable, so within a score the pool keeps whatever
    order the sources gave it.

    This is what makes the wave wide. An artist-based wave asks "who else is
    like this artist" and gets a handful of names; a tag-based one asks "what
    else is quiet, Russian and emo-rap" and reaches everybody who ever made
    something quiet, Russian and emo-rap.
    """
    if not taste:
        return items

    wanted = set(taste)

    def score(raw: dict) -> int:
        return len(wanted & set(tagging.derive(raw)))

    return sorted(items, key=score, reverse=True)


async def _shape(
    pool: list[dict],
    *,
    settings: dict,
    taste_artists: set[str],
    exclude_ids: set[str],
    suppressed_artists: set[str],
    want: int,
    rng: random.Random,
    taste_tags: list[str] | None = None,
) -> list[CatalogTrack]:
    """The full pipeline from raw pool to a finished run of CatalogTracks.

    Note there is deliberately no reference-artist filter here. That test — is
    this the real artist and not an account borrowing the name — is for search
    and the library, where the wrong "Lil Peep" is a real problem. A discovery
    wave is the opposite case: hiding good music because Deezer has never heard
    of whoever uploaded it is how the wave ends up thin and generic.
    """
    fresh = [
        raw
        for raw in pool
        if str(raw.get("id")) not in exclude_ids
        and str((raw.get("user") or {}).get("id") or "") not in suppressed_artists
    ]

    fresh = _apply_language(fresh, settings.get("language", "any"))
    fresh = _bias_by_tags(fresh, taste_tags or [])
    fresh = _bias_to_front(fresh, ACTIVITY_GENRES.get(settings.get("activity", "none"), []))
    fresh = _bias_to_front(fresh, MOOD_GENRES.get(settings.get("mood_energy", "all"), []))
    fresh = _apply_diversity(fresh, settings.get("diversity", "default"), taste_artists, rng)
    fresh = _spread_artists(fresh)
    fresh = await filter_playable(fresh, want)

    tracks = [t for t in (normalise_track(raw) for raw in fresh) if t][:want]

    # Only what the proper catalogue knows: the app should never surface a
    # random upload. `want` is asked for generously upstream, so dropping the
    # unknown ones still leaves a full run.
    known = await catalog_meta.spotify_only(tracks)

    # And one last spread, by the name the listener will actually read.
    # `_spread_artists` above keys on the uploader's account id, but three
    # different accounts can all resolve to "Lil Peep" once the catalogue has
    # named them — which is how the same artist appeared three times in a run
    # that was supposed to cap at two.
    return _spread_by_name(known)


def _spread_by_name(tracks: list[CatalogTrack], max_per_artist: int = 2) -> list[CatalogTrack]:
    counts: dict[str, int] = {}
    kept: list[CatalogTrack] = []
    overflow: list[CatalogTrack] = []

    for track in tracks:
        name = (track.artist_name or "").strip().lower()
        if not name:
            kept.append(track)
            continue

        if counts.get(name, 0) < max_per_artist:
            counts[name] = counts.get(name, 0) + 1
            kept.append(track)
        else:
            # Held back rather than dropped: a run that is short because one
            # artist was popular is worse than one that repeats them at the end.
            overflow.append(track)

    return kept + overflow


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

    stations, related = await asyncio.gather(
        _station_pool(seeds, want * 3),
        _related_pool(taste_artists, want * 2),
    )
    pool = stations + related
    if len({str(r.get("id")) for r in pool} - exclude) < want:
        pool += await _discovery_tracks(want * 2, genres=await _taste_genres(db, user_id))
    if len({str(r.get("id")) for r in pool} - exclude) < want:
        pool += await _known_pool(db, user_id, want, exclude)

    rng = random.Random(f"{user_id}:{len(sess.served or [])}:{int(time.time() // 900)}")
    tracks = await _shape(
        pool,
        settings=settings,
        taste_artists=taste_artists,
        exclude_ids=exclude,
        suppressed_artists=suppressed,
        want=want,
        rng=rng,
        taste_tags=await _taste_tags(db, user_id),
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
    sess.served = _extend_served([], [t["id"] for t in sess.queue])
    await db.flush()
    return sess


def _extend_served(existing: list[str] | None, new_ids: list[str]) -> list[str]:
    """Append ids, drop duplicates keeping the most recent, cap the length."""
    seen: set[str] = set()
    ordered: list[str] = []
    for tid in [*(existing or []), *new_ids]:
        if tid and tid not in seen:
            seen.add(tid)
            ordered.append(tid)
    return ordered[-SERVED_CAP:]


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
        sess.served = _extend_served(sess.served, [t["id"] for t in queue])
        added = await _fill(session, user.id, sess, want=BUFFER_TARGET - len(queue))
        queue = queue + added

    sess.queue = queue
    sess.served = _extend_served(sess.served, [t["id"] for t in queue])
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
    sess.served = _extend_served(sess.served, [t["id"] for t in head])
    tail = await _fill(session, user.id, sess, want=BUFFER_TARGET - len(head))
    sess.queue = head + tail
    sess.served = _extend_served(sess.served, [t["id"] for t in sess.queue])
    await session.commit()

    return _response(sess, sess.queue, personalised=True)


class UnplayableIn(BaseModel):
    track_ids: list[str] = Field(default_factory=list, max_length=50)
    reason: str | None = None


class UnplayableOut(BaseModel):
    recorded: int


@router.post("/unplayable", response_model=UnplayableOut)
async def report_unplayable_tracks(
    user: CurrentUser,
    session: SessionDep,
    payload: UnplayableIn,
) -> UnplayableOut:
    """The phone telling us a track it was handed does not play.

    This is the only trustworthy source for the question. The server checks
    playability from Frankfurt, and SoundCloud answers by region: a track that
    streams perfectly well from here can arrive in another country with
    ``policy: BLOCK`` and nothing to play at all. Whoever had to make the sound
    is the one who knows, so their verdict is taken over ours and the track
    stops being offered.
    """
    recorded = await report_unplayable(
        session, payload.track_ids, reason=payload.reason
    )
    if recorded:
        logger.info(
            "Телефон сообщил о неиграбельных треках: %s (%s)",
            recorded,
            payload.reason or "без причины",
        )
    return UnplayableOut(recorded=recorded)


# ─────────────────────────────────────────────────────────────────────────────
# Endpoints — stateless wave (kept for older clients) and "similar"
# ─────────────────────────────────────────────────────────────────────────────


async def build_wave(
    session,
    user_id,
    *,
    limit: int = 40,
    exclude_recent: bool = True,
    mood: str = "all",
    diversity: str = "default",
    language: str = "any",
    activity: str = "none",
    seed: str | None = None,
) -> WaveResponse:
    """A one-shot wave, as a plain function.

    Kept separate from the route: calling the route from inside the module
    passes FastAPI's `Query(...)` markers through as values, and `Query(None)`
    is truthy — so the feed's fallback wave was seeding its stations with a
    `Query` object instead of a track id.
    """
    seeds = [seed] if seed else await _seed_track_ids(session, user_id)
    exclude = await _excluded_track_ids(session, user_id) if exclude_recent else set()
    taste_artists = await _taste_artist_ids(session, user_id)

    # Stations for what sounds like the seeds, neighbours for what does not —
    # gathered together, since the run needs both halves.
    stations, related = await asyncio.gather(
        _station_pool(seeds, limit * 3),
        _related_pool(taste_artists, limit * 2),
    )
    pool = stations + related
    if len({str(r.get("id")) for r in pool} - exclude) < limit:
        pool += await _discovery_tracks(limit * 2, genres=await _taste_genres(session, user_id))

    if len({str(r.get("id")) for r in pool} - exclude) < limit:
        # The source is throttling or down. Build from what is already in the
        # catalogue rather than refusing — the ids still play.
        pool += await _known_pool(session, user_id, limit, exclude)

    if not pool:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Не удалось собрать волну, попробуйте позже",
        )

    rng = random.Random(f"{user_id}:{int(time.time() // 900)}")
    tracks = await _shape(
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
        taste_tags=await _taste_tags(session, user_id),
    )

    return WaveResponse(
        tracks=tracks,
        seed_track_ids=seeds,
        is_personalised=bool(seeds),
    )


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
    return await build_wave(
        session,
        user.id,
        limit=limit,
        exclude_recent=exclude_recent,
        mood=mood,
        diversity=diversity,
        language=language,
        activity=activity,
        seed=seed,
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


# The assembled feed, per listener. Short enough that a day's blocks still
# turn over, long enough that opening the app twice in a minute costs one
# assembly rather than two.
FEED_TTL = 10 * 60

# How long the whole assembly gets before the feed is served with whatever
# rows are ready.
BUILD_BUDGET = 4.0

# Past the TTL a cached feed is still served — immediately — and rebuilt
# behind the request. Nobody waits for a refresh of something they can
# already see.
FEED_STALE_TTL = 60 * 60

_feed_cache: dict[str, tuple["FeedResponse", float]] = {}
_feed_refreshing: set[str] = set()


def _feed_cache_get(user_id) -> "FeedResponse | None":
    hit = _feed_cache.get(str(user_id))
    if hit and time.monotonic() - hit[1] < FEED_TTL:
        return hit[0]
    return None


def _feed_cache_stale(user_id) -> "FeedResponse | None":
    hit = _feed_cache.get(str(user_id))
    if hit and time.monotonic() - hit[1] < FEED_STALE_TTL:
        return hit[0]
    return None


def _feed_cache_put(user_id, response: "FeedResponse") -> None:
    _feed_cache[str(user_id)] = (response, time.monotonic())
    # Cheap eviction: this is a handful of users, and the entries are small.
    if len(_feed_cache) > 500:
        oldest = sorted(_feed_cache.items(), key=lambda kv: kv[1][1])[:100]
        for key, _ in oldest:
            _feed_cache.pop(key, None)


async def warm_feeds(limit: int = 25) -> int:
    """Build the feed for everyone who has listened recently.

    The first open of a session is the only one that ever waits, and this
    removes even that: by the time anyone opens the app, their rows are
    already assembled. Runs at startup and on a slow loop.
    """
    from app.db.session import SessionLocal
    from app.models import User

    warmed = 0
    try:
        async with SessionLocal() as session:
            recent = (
                await session.scalars(
                    select(User)
                    .join(ListeningEvent, ListeningEvent.user_id == User.id)
                    .where(
                        ListeningEvent.played_at
                        >= datetime.now(UTC) - timedelta(days=14)
                    )
                    .distinct()
                    .limit(limit)
                )
            ).all()

        for user in recent:
            if _feed_cache_get(user.id):
                continue
            try:
                async with SessionLocal() as session:
                    await home_feed(user=user, session=session)
                warmed += 1
            except Exception:  # noqa: BLE001 — one bad account must not stop the rest
                logger.warning("feed warm failed for %s", user.id, exc_info=True)
            # Gentle: this competes with real requests for the same upstreams.
            await asyncio.sleep(1.0)
    except Exception:  # noqa: BLE001
        logger.warning("feed warm pass failed", exc_info=True)
    return warmed


async def feed_warm_loop() -> None:
    """Keeps every recent listener's feed inside its TTL, forever."""
    while True:
        try:
            warmed = await warm_feeds()
            if warmed:
                logger.info("Прогрето лент: %s", warmed)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.warning("feed warm loop error", exc_info=True)
        await asyncio.sleep(FEED_TTL // 2)


async def _rebuild_feed(user, key: str) -> None:
    """Refresh a stale feed on its own connection, after the response went out."""
    from app.db.session import SessionLocal

    try:
        _feed_cache.pop(key, None)
        async with SessionLocal() as session:
            await home_feed(user=user, session=session)
    except Exception:  # noqa: BLE001 — nobody is waiting on this
        pass
    finally:
        _feed_refreshing.discard(key)


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
    """A personal set that is the same all day and different tomorrow.

    Excludes what the listener already has, like every other block does. It
    did not, and that is why "Плейлист дня" kept handing back their own
    rotation — a set assembled for discovery is worthless if it is allowed to
    return the tracks they have been playing all week.
    """
    tracks = await _shape(
        pool,
        settings=dict(DEFAULT_SETTINGS),
        taste_artists=await _taste_artist_ids(session, user_id),
        exclude_ids=await _excluded_track_ids(session, user_id),
        suppressed_artists=set(),
        want=40,
        rng=rng,
        taste_tags=await _taste_tags(session, user_id),
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
    your artists, quiet finds, the chart.

    Assembled once per window and cached. It is a dozen upstream calls, and
    the screen is opened on every launch and every tab switch back — paying
    for it each time is what made the app feel slow.
    """
    if cached := _feed_cache_get(user.id):
        return cached

    # Past the TTL but still recent: serve it now and rebuild behind the
    # request, so only the very first open of a session ever waits.
    if stale := _feed_cache_stale(user.id):
        key = str(user.id)
        if key not in _feed_refreshing:
            _feed_refreshing.add(key)
            asyncio.create_task(_rebuild_feed(user, key))
        return stale

    # The rows that need the station pool and the ones that don't are started
    # together: the pool is the slowest part, and waiting for it before even
    # asking for the chart doubled the wait for no reason.
    async def personal_rows() -> list[FeedBlock | None]:
        seeds = await _seed_track_ids(session, user.id)
        pool = await _station_pool(seeds, 120)
        if len(pool) < 40:
            pool += await _discovery_tracks(80, genres=await _taste_genres(session, user.id))

        day_rng = random.Random(f"{user.id}:{date.today().isoformat()}")
        results = await asyncio.gather(
            _block_playlist_of_the_day(session, user.id, list(pool), day_rng),
            _block_hidden_gem(session, user.id, list(pool)),
            return_exceptions=True,
        )
        return [r for r in results if isinstance(r, FeedBlock)]

    # A hard deadline on the whole assembly. Whatever is ready by then is the
    # feed; the rest lands in the cache for the next open. A home screen that
    # appears in four seconds with four rows beats one that appears in ten
    # with five.
    tasks = [
        asyncio.create_task(personal_rows()),
        asyncio.create_task(_block_dejavu(session, user.id)),
        asyncio.create_task(_block_premiere(session, user.id)),
        asyncio.create_task(_block_charts()),
        asyncio.create_task(_block_genre_mix()),
    ]
    done, pending = await asyncio.wait(tasks, timeout=BUILD_BUDGET)
    for task in pending:
        task.cancel()

    personal: list[FeedBlock] = []
    rest: list[FeedBlock] = []
    for task in done:
        if task.cancelled() or task.exception() is not None:
            continue
        value = task.result()
        if isinstance(value, list):
            personal = value
        elif isinstance(value, FeedBlock):
            rest.append(value)

    # Order is the point of the feed, so it is imposed here rather than
    # falling out of which upstream answered first.
    order = ["playlist-of-the-day", "dejavu", "premiere", "hidden-gem", "chart"]
    by_id = {b.id: b for b in [*personal, *rest]}
    ordered = [by_id[key] for key in order if key in by_id]
    ordered += [b for b in by_id.values() if b.id not in order]

    # The feed must never come back empty — the home screen has no other
    # content now. If every block above missed (a fresh account, a slow
    # source), fall back to the chart, then to a plain wave.
    if not ordered:
        if chart := await _block_charts():
            ordered.append(chart)
    if not ordered:
        try:
            one_shot = await build_wave(session, user.id, limit=40)
        except HTTPException:
            one_shot = None
        if one_shot and one_shot.tracks:
            ordered.append(
                FeedBlock(
                    id="wave", type="playlist", title="Волна",
                    subtitle="Подобрано под ваш вкус", tracks=one_shot.tracks,
                )
            )

    # Every row shows Spotify names and covers, and no row repeats a song.
    # In parallel: each row's enrichment has its own budget, and running them
    # one after another meant the budgets added up.
    enriched = await asyncio.gather(
        *(catalog_meta.spotify_only(b.tracks) for b in ordered),
        return_exceptions=True,
    )
    for block, tracks in zip(ordered, enriched):
        if isinstance(tracks, list):
            block.tracks = tracks
    ordered = [b for b in ordered if len(b.tracks) >= 3]

    response = FeedResponse(blocks=ordered, generated_at=datetime.now(UTC))
    if ordered:
        _feed_cache_put(user.id, response)
    return response


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
        one_shot = await build_wave(session, user.id, limit=limit)
        wave = one_shot.tracks

    return HomeResponse(wave=wave, for_you=for_you, charts=charts)
