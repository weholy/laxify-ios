"""Lyrics from Genius.

Genius has by far the widest coverage of anything free, but its API returns
a link to a page rather than the words on it — so the page is read. That is
the only way to get lyrics from them, and it is what every client that uses
them does.

No timings, ever: Genius has none. So this runs after the sources that do,
and what it finds is shown as plain text rather than following the vocal.
"""

import asyncio
import logging
import re
import time
from html import unescape

import httpx

from app.core.config import settings

logger = logging.getLogger("laxify.genius")

API_BASE = "https://api.genius.com"
TIMEOUT = 15

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"
)

# Genius pages carry the words inside containers marked this way. The class
# names are generated and change, so the stable part is matched instead.
_LYRICS_BLOCK = re.compile(
    r'<div[^>]+data-lyrics-container="true"[^>]*>(.*?)</div>', re.DOTALL
)
_BREAK = re.compile(r"<br\s*/?>", re.IGNORECASE)
_TAG = re.compile(r"<[^>]+>")

# Section headers the page includes and a listener does not need.
_SECTION = re.compile(r"^\[[^\]]{0,60}\]$")

_token: tuple[str, float] | None = None
_token_lock = asyncio.Lock()

_client: httpx.AsyncClient | None = None


def _http() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            timeout=TIMEOUT,
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
            limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
        )
    return _client


def is_configured() -> bool:
    return bool(settings.genius_client_id and settings.genius_client_secret)


async def _access_token() -> str | None:
    """A token for the search endpoint.

    Client credentials, which Genius issues without expiry — but it is
    refreshed daily anyway, since a token that silently stops working is
    harder to notice than one that is simply asked for again.
    """
    global _token

    if _token is not None and time.monotonic() - _token[1] < 24 * 3600:
        return _token[0]

    if not is_configured():
        return None

    async with _token_lock:
        if _token is not None and time.monotonic() - _token[1] < 24 * 3600:
            return _token[0]

        try:
            response = await _http().post(
                f"{API_BASE}/oauth/token",
                data={
                    "client_id": settings.genius_client_id,
                    "client_secret": settings.genius_client_secret,
                    "grant_type": "client_credentials",
                },
            )
        except httpx.HTTPError as exc:
            logger.warning("Genius не выдал токен: %s", exc)
            return None

        if response.status_code != 200:
            logger.warning("Genius отказал в токене: %s", response.status_code)
            return None

        token = response.json().get("access_token")
        if not token:
            return None

        _token = (token, time.monotonic())
        return token


async def find(title: str, artist: str) -> str | None:
    """The words to a song, as plain text, or nothing."""
    token = await _access_token()
    if token is None:
        return None

    url = await _page_url(token, title, artist)
    if url is None:
        return None

    return await _read_page(url)


async def _page_url(token: str, title: str, artist: str) -> str | None:
    """Finds the page for a song, rejecting the ones that only look right.

    Two queries, because Genius ranks them differently: name and title
    together is the obvious one, but for anything outside the anglophone
    catalogue the title alone often finds what the pair does not. Both are
    filtered the same way, so a looser query does not mean a looser match.
    """
    for query in (f"{artist} {title}".strip(), title.strip()):
        if found := await _search(token, query, title, artist):
            return found

    return None


async def _search(token: str, query: str, title: str, artist: str) -> str | None:
    try:
        response = await _http().get(
            f"{API_BASE}/search",
            params={"q": query},
            headers={"Authorization": f"Bearer {token}"},
        )
    except httpx.HTTPError:
        return None

    if response.status_code != 200:
        return None

    hits = response.json().get("response", {}).get("hits", [])
    wanted_title = _plain(title)
    wanted_artist = _plain(artist)

    for hit in hits:
        result = hit.get("result") or {}

        # Translations are indexed alongside originals and rank highly for a
        # Russian query — "Lil Peep - Star Shopping (Русский перевод)". They
        # are somebody else's words about the song, not the song.
        primary = _plain((result.get("primary_artist") or {}).get("name") or "")
        if any(
            marker in primary
            for marker in ("genius", "перевод", "translation", "traducao", "ceviri")
        ):
            continue

        found_title = _plain(result.get("title") or "")
        if not found_title:
            continue

        # The title has to actually match. Genius returns ten results for
        # anything, and the tenth is unrelated.
        if wanted_title not in found_title and found_title not in wanted_title:
            continue

        # And the artist, when there is one to compare against — a title
        # alone matches covers and remixes by other people.
        if wanted_artist and wanted_artist not in primary and primary not in wanted_artist:
            continue

        if url := result.get("url"):
            return url

    return None


async def _read_page(url: str) -> str | None:
    """Pulls the words out of a Genius page."""
    try:
        response = await _http().get(url)
    except httpx.HTTPError:
        return None

    if response.status_code != 200:
        return None

    blocks = _LYRICS_BLOCK.findall(response.text)
    if not blocks:
        return None

    lines: list[str] = []

    for block in blocks:
        text = _BREAK.sub("\n", block)
        text = _TAG.sub("", text)
        text = unescape(text)

        for line in text.split("\n"):
            stripped = line.strip()
            if not stripped:
                # One blank line between verses, never several.
                if lines and lines[-1] != "":
                    lines.append("")
                continue

            # "[Chorus]", "[Куплет 2]" — structure, not words.
            if _SECTION.match(stripped):
                if lines and lines[-1] != "":
                    lines.append("")
                continue

            lines.append(stripped)

    result = "\n".join(lines).strip()

    # A handful of characters means the page had a stub rather than lyrics.
    return result if len(result) > 60 else None


def _plain(value: str) -> str:
    """Reduces a name to what two spellings of it share."""
    lowered = value.lower()
    lowered = re.sub(r"\((?:feat|ft|prod|with)\.?[^)]*\)", " ", lowered)
    lowered = re.sub(r"[^a-zа-я0-9\s]", " ", lowered)
    return " ".join(lowered.split())
