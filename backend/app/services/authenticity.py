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
from sqlalchemy import select

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
