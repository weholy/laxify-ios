"""Finding the words to a song.

No single source has everything. LRCLIB has the best timed lyrics but only
for what its contributors have added; the others have broader coverage and no
timings at all. So several are tried in turn, best first, and the first
usable answer wins.

Doing this on the server rather than on each phone means one lookup serves
everyone who ever plays that track, a source can be added without shipping an
app, and a track nobody has words for is only ever searched for once.
"""

import asyncio
import logging
import re
from dataclasses import dataclass, field
from urllib.parse import quote

import httpx

logger = logging.getLogger("laxify.lyrics")

TIMEOUT = 12
USER_AGENT = "Laxify/1.0 (music app)"

# Timestamps look like [mm:ss.xx] or [mm:ss]; anything else on the line is
# the words.
_TIMESTAMP = re.compile(r"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]")

# Things uploaders add to a title that are not part of the song's name and
# only ever make a search miss.
_NOISE = re.compile(
    r"""\s*(?:
        [\(\[]\s*(?:prod\.?|produced|feat\.?|ft\.?|with|remix|edit|version|
                    official|video|audio|lyrics?|visualizer|hq|hd|free|
                    dl|download|bonus|explicit|clean)\b[^)\]]*[\)\]]
      | \s[-–—]\s*(?:official|lyrics?|audio|video|prod\.?)\b.*$
      | \bfeat\.?\s.*$
      | \bft\.?\s.*$
    )""",
    re.IGNORECASE | re.VERBOSE,
)


@dataclass
class LyricLine:
    timestamp: float
    text: str


@dataclass
class Lyrics:
    source: str
    plain: str | None = None
    synced: list[LyricLine] = field(default_factory=list)

    @property
    def is_synced(self) -> bool:
        return len(self.synced) > 1

    @property
    def is_usable(self) -> bool:
        return self.is_synced or bool(self.plain and self.plain.strip())


def clean_title(title: str) -> str:
    """Strips what uploaders decorate a title with.

    Titles here are whatever someone typed when uploading — "save that shit
    (prod. smokeasac x iivi)" — and searching for that verbatim finds
    nothing. What remains is usually the song's actual name.
    """
    cleaned = _NOISE.sub("", title)
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip(" -–—_|")
    return cleaned or title.strip()


def clean_artist(name: str) -> str:
    """Removes the decoration accounts put around their names."""
    kept = [ch for ch in name if ch.isalnum() or ch.isspace() or ch in "-_&'."]
    cleaned = " ".join("".join(kept).split())
    # "Lil Peep Official", "xxx Music" — the suffix is not part of the name.
    cleaned = re.sub(
        r"\s+(?:official|music|records?|vevo|topic|archive|vids?)$", "", cleaned, flags=re.I
    )
    return cleaned or name.strip()


def split_artists(name: str) -> list[str]:
    """A credit line often names several people; any of them may be the one
    a lyrics database filed the song under."""
    parts = re.split(r"\s*(?:,|&|feat\.?|ft\.?|x|vs\.?|and)\s+", name, flags=re.IGNORECASE)
    return [part for part in (p.strip() for p in parts) if len(part) > 1]


def parse_lrc(raw: str) -> list[LyricLine]:
    """Turns an LRC body into timed lines.

    One line can carry several timestamps when a chorus repeats, so each is
    emitted separately rather than only the first.
    """
    lines: list[LyricLine] = []

    for row in raw.splitlines():
        stamps = list(_TIMESTAMP.finditer(row))
        if not stamps:
            continue

        text = _TIMESTAMP.sub("", row).strip()

        for stamp in stamps:
            minutes = int(stamp.group(1))
            seconds = int(stamp.group(2))
            fraction = stamp.group(3) or "0"
            # Two digits mean hundredths, three mean thousandths.
            divisor = 100 if len(fraction) <= 2 else 1000
            at = minutes * 60 + seconds + int(fraction) / divisor

            lines.append(LyricLine(timestamp=at, text=text))

    lines.sort(key=lambda line: line.timestamp)
    return lines


class LyricsFinder:
    """Tries each source in turn and returns the first usable answer."""

    async def find(
        self, title: str, artist: str, duration: float | None = None
    ) -> Lyrics | None:
        song = clean_title(title)
        performer = clean_artist(artist)

        async with httpx.AsyncClient(
            timeout=TIMEOUT, headers={"User-Agent": USER_AGENT}, follow_redirects=True
        ) as client:
            # Timed lyrics are worth trying hardest for: they are what makes
            # the words follow the vocal rather than sit there.
            for candidate_artist in [performer, *split_artists(performer)]:
                found = await self._lrclib(client, song, candidate_artist, duration)
                if found and found.is_synced:
                    return found

            # Then anything at all, from whichever source has it.
            attempts = [
                self._lrclib(client, song, performer, None),
                self._lyrics_ovh(client, song, performer),
                self._textyl(client, song, performer),
            ]

            for coro in attempts:
                try:
                    found = await coro
                except Exception:
                    continue
                if found and found.is_usable:
                    return found

        return None

    # MARK: - Sources

    async def _lrclib(
        self, client: httpx.AsyncClient, title: str, artist: str, duration: float | None
    ) -> Lyrics | None:
        """The best source for timed lyrics, and the only free one."""
        params = {"track_name": title, "artist_name": artist}
        if duration:
            params["duration"] = int(duration)

        try:
            response = await client.get("https://lrclib.net/api/get", params=params)
            if response.status_code == 404:
                # An exact match failed; search is looser about spelling and
                # about which of several artists is credited.
                response = await client.get(
                    "https://lrclib.net/api/search",
                    params={"track_name": title, "artist_name": artist},
                )
                if response.status_code != 200:
                    return None
                results = response.json()
                if not results:
                    return None
                payload = results[0]
            elif response.status_code == 200:
                payload = response.json()
            else:
                return None
        except httpx.HTTPError:
            return None

        synced = parse_lrc(payload.get("syncedLyrics") or "")
        plain = payload.get("plainLyrics")

        result = Lyrics(source="lrclib", plain=plain, synced=synced)
        return result if result.is_usable else None

    async def _lyrics_ovh(
        self, client: httpx.AsyncClient, title: str, artist: str
    ) -> Lyrics | None:
        """Plain words, wide coverage, no timings."""
        url = f"https://api.lyrics.ovh/v1/{quote(artist)}/{quote(title)}"

        try:
            response = await client.get(url)
        except httpx.HTTPError:
            return None

        if response.status_code != 200:
            return None

        text = (response.json() or {}).get("lyrics")
        if not text:
            return None

        # This source pads with a header line and doubles every break.
        cleaned = re.sub(r"^.*?Paroles de la chanson.*?\n", "", text, flags=re.S)
        cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()

        result = Lyrics(source="lyrics.ovh", plain=cleaned)
        return result if result.is_usable else None

    async def _textyl(
        self, client: httpx.AsyncClient, title: str, artist: str
    ) -> Lyrics | None:
        """Timed lyrics for a smaller catalogue, in its own shape."""
        try:
            response = await client.get(
                "https://api.textyl.co/api/lyrics", params={"q": f"{artist} {title}"}
            )
        except httpx.HTTPError:
            return None

        if response.status_code != 200:
            return None

        try:
            rows = response.json()
        except ValueError:
            return None

        if not isinstance(rows, list) or not rows:
            return None

        synced = [
            LyricLine(timestamp=float(row.get("seconds") or 0), text=(row.get("lyrics") or "").strip())
            for row in rows
            if isinstance(row, dict)
        ]
        synced = [line for line in synced if line.text]

        if not synced:
            return None

        return Lyrics(
            source="textyl",
            plain="\n".join(line.text for line in synced),
            synced=synced,
        )


finder = LyricsFinder()
