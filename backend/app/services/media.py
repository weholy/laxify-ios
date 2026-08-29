"""Upload a comment's photo or clip to Catbox and hand back the URL.

The app never talks to Catbox directly — the file comes here, we forward it,
and only the resulting URL is stored. If Catbox is unreachable the caller
lets the comment post without the attachment.
"""
import httpx

from app.core.config import settings

_CATBOX = "https://catbox.moe/user/api.php"
_LITTERBOX = "https://litterbox.catbox.moe/resources/internals/api.php"


class MediaUploadError(Exception):
    pass


async def upload_media(data: bytes, filename: str) -> str:
    files = {"fileToUpload": (filename, data)}

    # Catbox first (permanent). Falls back to Litterbox (expiring) so a
    # comment attachment still works if the permanent host is down.
    for url, form in (
        (_CATBOX, {"reqtype": "fileupload"} | _userhash()),
        (_LITTERBOX, {"reqtype": "fileupload", "time": "72h"}),
    ):
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(url, data=form, files=files)
            resp.raise_for_status()
            link = resp.text.strip()
            if link.startswith("http"):
                return link
        except httpx.HTTPError:
            continue

    raise MediaUploadError("Не удалось загрузить файл")


def _userhash() -> dict[str, str]:
    return {"userhash": settings.catbox_userhash} if settings.catbox_userhash else {}
