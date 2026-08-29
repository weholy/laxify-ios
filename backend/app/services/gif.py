"""GIF search, proxied so the API key stays on the server.

Tenor by default (Google, generous free tier). Returns an empty list until
`tenor_api_key` is set — the picker degrades to "nothing found".
"""
import httpx

from app.core.config import settings
from app.schemas.social import GifItemOut

_TENOR = "https://tenor.googleapis.com/v2"


async def search_gifs(query: str, limit: int = 24) -> list[GifItemOut]:
    key = settings.tenor_api_key
    if not key:
        return []

    endpoint = f"{_TENOR}/search" if query.strip() else f"{_TENOR}/featured"
    params = {
        "key": key,
        "limit": str(limit),
        "media_filter": "tinygif,gif",
        "client_key": "laxify",
    }
    if query.strip():
        params["q"] = query.strip()

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(endpoint, params=params)
        resp.raise_for_status()
        results = resp.json().get("results", [])
    except (httpx.HTTPError, ValueError):
        return []

    items: list[GifItemOut] = []
    for entry in results:
        media = entry.get("media_formats", {})
        full = media.get("gif") or media.get("tinygif")
        preview = media.get("tinygif") or full
        if not full or not preview:
            continue
        items.append(
            GifItemOut(id=str(entry.get("id")), url=full["url"], preview_url=preview["url"])
        )
    return items
