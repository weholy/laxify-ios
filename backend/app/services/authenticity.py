"""Telling real artists from the accounts that borrow their names.

The source is open to anyone, so a search for a well-known artist returns
their account alongside a dozen others reusing the name: fan uploads,
reposters, and accounts that exist only to collect plays. Showing those
beside the real thing makes the whole catalogue look untrustworthy.

Two signals decide it. The source marks some accounts as verified, which is
conclusive when present but missing for a great many genuine artists —
much of Russian rap among them. So the second check is whether the name
matches a real artist in an independent catalogue that has no accounts at
all, only artists. An account passing either check is treated as real.

The reference catalogue is Deezer's public search: no key, no quota worth
worrying about, and it answers from this server, which the obvious choice
for this — Yandex — does not.
"""

import asyncio
import logging
import re
import time
import unicodedata

import httpx
from sqlalchemy import func, select

from app.models import ReferenceArtist

logger = logging.getLogger("laxify.authenticity")

DEEZER_SEARCH = "https://api.deezer.com/search/artist"
TIMEOUT = 10

# Below this an account has no audience to speak of, and a name match alone
# is not enough — anyone can call themselves anything.
MIN_FOLLOWERS = 5_000

# What counts as a real artist on the reference side. Below this the entry is
# usually itself a re-upload or a mistake in their catalogue.
MIN_REFERENCE_FANS = 1_000

# For an account vouched for only by an outside name search — no badge, and
# not in the catalogue we trust — this is the audience that makes a borrowed
# name implausible. Someone impersonating an artist does not have fifty
# thousand listeners.
STRONG_FOLLOWERS = 50_000

# Accounts that are always let through, whatever the rules say. Kept short
# and by id, so it stays a list of decisions rather than a second rulebook.
ALWAYS_GENUINE = {
    "257920946",  # FACE
    "922199617",  # FACE
}

_cache: dict[str, tuple[bool, float]] = {}
_CACHE_TTL = 24 * 60 * 60
_lock = asyncio.Lock()

_client: httpx.AsyncClient | None = None


def _http() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            timeout=TIMEOUT,
            headers={"User-Agent": "Laxify/1.0"},
            limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
        )
    return _client


def normalise(name: str) -> str:
    """Reduces a name to what two spellings of it have in common.

    Accounts decorate names heavily — stars, emoji, "Official", doubled
    letters — and none of that is part of who the artist is.
    """
    text = unicodedata.normalize("NFKD", name)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.lower()

    text = re.sub(r"\b(official|music|records?|vevo|topic|archive|prod|beats)\b", " ", text)
    text = re.sub(r"[^a-zа-я0-9\s]", " ", text)
    return " ".join(text.split())


def looks_like_a_reupload(username: str) -> bool:
    """Names that announce themselves as somebody else's uploads.

    Not proof, but strong enough to matter when nothing else vouches for the
    account.
    """
    lowered = username.lower()
    markers = (
        "rare", "unreleased", "leak", "leaks", "archive", "vault", "snippets",
        "fan", "tribute", "type beat", "unofficial", "reupload", "re-upload",
        "best of", "hits", "mix", "radio", "playlist", "topic",
    )
    return any(marker in lowered for marker in markers)


async def _reference_names(name: str) -> list[tuple[str, int]]:
    """Artists the reference catalogue knows by roughly this name."""
    try:
        response = await _http().get(DEEZER_SEARCH, params={"q": name, "limit": 8})
    except httpx.HTTPError:
        return []

    if response.status_code != 200:
        return []

    try:
        entries = response.json().get("data", [])
    except ValueError:
        return []

    return [
        (entry.get("name") or "", entry.get("nb_fan") or 0)
        for entry in entries
        if entry.get("name")
    ]


async def reference_match(session, name: str) -> str | None:
    """The catalogue's own spelling of this name, if it knows it.

    Matching against a catalogue that contains only artists is the strongest
    signal available short of the source's own badge: nobody can add
    themselves to it.
    """
    key = normalise(name)
    if not key:
        return None

    row = await session.scalar(
        select(ReferenceArtist.name).where(ReferenceArtist.normalised == key).limit(1)
    )
    return row


async def is_genuine(user: dict, session=None) -> bool:
    """Whether this account belongs in the catalogue at all.

    One test: does a proper music catalogue know this name? That catalogue
    contains artists and nothing else — no accounts, no uploads, nothing
    anyone can add themselves to — so a match there means the name belongs to
    a real artist, and an account carrying it is the one worth showing.

    Everything else is hidden rather than deleted. The tracks stay: plenty of
    good music is posted by people who never claimed to be the artist, and
    hiding a song because of who uploaded it would empty the catalogue. What
    disappears is the impersonation.
    """
    if not user:
        return False

    if str(user.get("id")) in ALWAYS_GENUINE:
        return True

    username = user.get("username") or ""
    if not username:
        return False

    if looks_like_a_reupload(username):
        return False

    if session is None:
        # Nothing to check against. Falling back to the source's own badge is
        # the closest thing to the same question.
        return bool(user.get("verified"))

    return await reference_match(session, username) is not None


async def filter_artists(users: list[dict], limit: int, session=None) -> list[dict]:
    """Keeps the accounts that are who they say they are, best first."""
    if not users:
        return []

    semaphore = asyncio.Semaphore(6)

    async def check(user: dict) -> tuple[dict, bool]:
        async with semaphore:
            return user, await is_genuine(user, session=session)

    results = await asyncio.gather(*(check(user) for user in users), return_exceptions=True)

    kept = [
        user
        for result in results
        if not isinstance(result, BaseException)
        for user, genuine in [result]
        if genuine
    ]

    # Verified first, then by audience: when several accounts survive, the
    # one people actually follow is the one they meant.
    kept.sort(
        key=lambda user: (bool(user.get("verified")), user.get("followers_count") or 0),
        reverse=True,
    )

    return kept[:limit]


def genuine_marks(user: dict) -> dict:
    """The bits the app shows next to a name."""
    return {
        "is_verified": bool(user.get("verified")),
        "followers": user.get("followers_count") or 0,
    }


# MARK: - Hiding what the catalogue does not know

# Below this, the reference list is too thin to filter tracks with — it would
# hide the catalogue rather than clean it. The graph walk that fills the list
# produces several times this.
MIN_REFERENCE_SIZE = 6_000

# And even with a full list, a listing that loses almost everything means the
# list has gone stale or the match is wrong. Better to show music than to show
# an empty screen because of a rule.
MIN_SURVIVING_SHARE = 0.25

_reference_size: tuple[int, float] | None = None


async def reference_size(session) -> int:
    """How many artists the reference list holds, cached briefly."""
    global _reference_size

    now = time.monotonic()
    if _reference_size is not None and now - _reference_size[1] < 300:
        return _reference_size[0]

    count = await session.scalar(select(func.count()).select_from(ReferenceArtist)) or 0
    _reference_size = (count, now)
    return count


def credited_name(raw: dict) -> str:
    """Who a track credits, before who uploaded it."""
    metadata = raw.get("publisher_metadata") or {}
    name = (metadata.get("artist") or "").strip()
    if name and len(name) <= 60:
        return name
    return (raw.get("user") or {}).get("username") or ""


async def known_names(session, names: set[str]) -> set[str]:
    """Of `names`, the normalised forms the reference catalogue recognises."""
    keys = {normalise(n) for n in names if n}
    if not keys:
        return set()
    rows = await session.scalars(
        select(ReferenceArtist.normalised).where(ReferenceArtist.normalised.in_(keys))
    )
    return set(rows.all())


async def filter_by_reference(session, items: list, name_of, *, guard: bool = True) -> list:
    """Generic version of `filter_tracks` for the library.

    `name_of(item)` returns the credited artist name. Keeps only items whose
    artist the reference catalogue knows. `guard=True` keeps the two
    safety nets (list too small, filter too aggressive); the library
    listings pass `guard=False` — a favourite by an unknown uploader is
    exactly what the user asked to hide, even if it hides most of them.
    """
    if not items or session is None:
        return items
    if await reference_size(session) < MIN_REFERENCE_SIZE:
        return items

    known = await known_names(session, {name_of(i) for i in items})
    kept = [i for i in items if normalise(name_of(i)) in known]

    if guard and len(kept) < len(items) * MIN_SURVIVING_SHARE:
        logger.warning("Справочный фильтр оставил %s из %s — пропускаю", len(kept), len(items))
        return items
    return kept


async def filter_tracks(session, tracks: list[dict]) -> list[dict]:
    """Hides tracks by artists the reference catalogue does not know.

    Two guards, because this rule can do far more harm than good when the
    list behind it is incomplete: it does nothing until the list is large
    enough to be trusted, and nothing when applying it would empty the
    listing. A screen with no music is worse than a screen with an uploader's
    name on it.
    """
    if not tracks or session is None:
        return tracks

    if await reference_size(session) < MIN_REFERENCE_SIZE:
        return tracks

    known = set(
        (
            await session.scalars(
                select(ReferenceArtist.normalised).where(
                    ReferenceArtist.normalised.in_(
                        {normalise(credited_name(track)) for track in tracks if credited_name(track)}
                    )
                )
            )
        ).all()
    )

    kept = [track for track in tracks if normalise(credited_name(track)) in known]

    if len(kept) < len(tracks) * MIN_SURVIVING_SHARE:
        logger.warning(
            "Фильтр по справочнику оставил %s из %s — пропускаю",
            len(kept),
            len(tracks),
        )
        return tracks

    return kept
