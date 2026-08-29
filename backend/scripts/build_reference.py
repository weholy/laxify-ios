"""Fill `reference_artists` from Deezer's public catalogue.

Deezer is the reference the authenticity filter checks names against — a
catalogue that only holds artists, no accounts, nothing anyone can add
themselves to. Yandex would be the ideal source but answers 451 to this
server (and to anywhere without a Russian IP); Deezer answers from
everywhere with no key.

Run it on the server, once, then again whenever the list needs refreshing:

    cd /opt/laxify && .venv/bin/python -m scripts.build_reference

It walks the chart + every genre's top artists, then follows the
"related artists" graph out from there — the same shape as the on-device
Yandex walk. Anything with at least MIN_FANS listeners is kept.
"""
import asyncio
import sys
import time
import unicodedata
import re

import httpx
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

sys.path.insert(0, "/opt/laxify")
sys.path.insert(0, ".")

from app.db.session import SessionLocal  # noqa: E402
from app.models import ReferenceArtist  # noqa: E402

DEEZER = "https://api.deezer.com"
MIN_FANS = 1_000
ARTIST_CAP = 20_000
REQUEST_CAP = 6_000
RELATED_PER_ARTIST = 20


def _normalise(name: str) -> str:
    text = unicodedata.normalize("NFKD", name)
    text = "".join(ch for ch in text if not unicodedata.combining(ch)).lower()
    text = re.sub(r"\b(official|music|records?|vevo|topic|archive|prod|beats)\b", " ", text)
    text = re.sub(r"[^a-zа-я0-9\s]", " ", text)
    return " ".join(text.split())


async def _get(client: httpx.AsyncClient, path: str, **params):
    for attempt in range(3):
        try:
            r = await client.get(f"{DEEZER}{path}", params=params, timeout=20)
            if r.status_code == 200:
                return r.json()
            if r.status_code == 429:
                await asyncio.sleep(2 + attempt * 2)
                continue
        except httpx.HTTPError:
            await asyncio.sleep(1)
    return {}


async def main() -> None:
    started = time.monotonic()
    collected: dict[int, dict] = {}   # deezer id -> {name, fans, tracks, albums}
    requests = 0

    async with httpx.AsyncClient(headers={"User-Agent": "Laxify/1.0"}) as client:
        # --- seeds: the chart + each genre's top artists ---
        seeds: set[int] = set()

        chart = await _get(client, "/chart/0/artists", limit=100)
        requests += 1
        for a in chart.get("data", []):
            seeds.add(a["id"])

        genres = await _get(client, "/genre")
        requests += 1
        for g in genres.get("data", []):
            if g.get("id", 0) <= 0:
                continue
            data = await _get(client, f"/genre/{g['id']}/artists", limit=100)
            requests += 1
            for a in data.get("data", []):
                seeds.add(a["id"])

        print(f"seeds: {len(seeds)} artists, {requests} requests")

        # --- graph walk: follow "related" out from the seeds ---
        queue = list(seeds)
        visited: set[int] = set()

        while queue and len(collected) < ARTIST_CAP and requests < REQUEST_CAP:
            batch = queue[:40]
            queue = queue[40:]

            async def fetch(aid: int):
                if aid in visited:
                    return aid, None
                visited.add(aid)
                return aid, await _get(client, f"/artist/{aid}/related", limit=RELATED_PER_ARTIST)

            results = await asyncio.gather(*(fetch(a) for a in batch))
            requests += sum(1 for _, r in results if r is not None)

            for _, payload in results:
                if not payload:
                    continue
                for a in payload.get("data", []):
                    fans = a.get("nb_fan") or 0
                    if fans < MIN_FANS or not a.get("name"):
                        continue
                    if a["id"] not in collected:
                        collected[a["id"]] = {
                            "name": a["name"],
                            "fans": fans,
                            "tracks": a.get("nb_album", 0),
                            "albums": a.get("nb_album", 0),
                        }
                        if a["id"] not in visited:
                            queue.append(a["id"])

            if requests % 200 < 40:
                print(f"  {len(collected)} artists · {requests} requests · "
                      f"{int(time.monotonic() - started)}s")

    print(f"collected {len(collected)} artists in {requests} requests")

    # --- write ---
    rows = []
    seen_keys: set[str] = set()
    for aid, info in collected.items():
        key = _normalise(info["name"])
        if not key or key in seen_keys:
            continue
        seen_keys.add(key)
        rows.append({
            "source_id": str(aid),
            "name": info["name"],
            "normalised": key,
            "tracks": info["tracks"],
            "albums": info["albums"],
        })

    async with SessionLocal() as session:
        before = await session.scalar(select(func.count()).select_from(ReferenceArtist)) or 0
        await session.execute(delete(ReferenceArtist))
        CHUNK = 2_000
        for i in range(0, len(rows), CHUNK):
            await session.execute(pg_insert(ReferenceArtist).values(rows[i:i + CHUNK]))
        await session.commit()
        after = await session.scalar(select(func.count()).select_from(ReferenceArtist)) or 0

    print(f"reference_artists: {before} -> {after}")


if __name__ == "__main__":
    asyncio.run(main())
