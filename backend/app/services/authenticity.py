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

logger = logging.getLogger("laxify.authenticity")

DEEZER_SEARCH = "https://api.deezer.com/search/artist"
TIMEOUT = 10

# Below this an account has no audience to speak of, and a name match alone
# is not enough — anyone can call themselves anything.
MIN_FOLLOWERS = 5_000

# What counts as a real artist on the reference side. Below this the entry is
# usually itself a re-upload or a mistake in their catalogue.
MIN_REFERENCE_FANS = 1_000

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


async def is_genuine(user: dict) -> bool:
    """Whether this account is the artist it appears to be.

    Verified accounts pass immediately. Otherwise the name has to match a
    real artist elsewhere *and* the account has to have an audience of its
    own — either alone is too easy to fake.
    """
    if not user:
        return False

    if str(user.get("id")) in ALWAYS_GENUINE:
        return True

    if user.get("verified"):
        return True

    username = user.get("username") or ""
    followers = user.get("followers_count") or 0

    if not username:
        return False

    # A tiny account claiming a famous name is the exact thing being filtered.
    if followers < MIN_FOLLOWERS:
        return False

    if looks_like_a_reupload(username):
        return False

    key = normalise(username)
    if not key:
        return False

    now = time.monotonic()
    cached = _cache.get(key)
    if cached is not None and now - cached[1] < _CACHE_TTL:
        return cached[0]

    references = await _reference_names(username)

    verdict = any(
        normalise(reference) == key and fans >= MIN_REFERENCE_FANS
        for reference, fans in references
    )

    _cache[key] = (verdict, now)
    if len(_cache) > 10_000:
        for stale, _ in sorted(_cache.items(), key=lambda item: item[1][1])[:2_000]:
            _cache.pop(stale, None)

    return verdict


async def filter_artists(users: list[dict], limit: int) -> list[dict]:
    """Keeps the accounts that are who they say they are, best first."""
    if not users:
        return []

    semaphore = asyncio.Semaphore(6)

    async def check(user: dict) -> tuple[dict, bool]:
        async with semaphore:
            return user, await is_genuine(user)

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
