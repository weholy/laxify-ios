"""Plain HTML pages served at the site root, outside the /api/v1 prefix.

Right now just the Telegram login bridge: the bot's domain (set with
/setdomain in @BotFather) points here, the app opens /tg-login in a web
sheet, and once Telegram signs the user in the page bounces the signed
payload back into the app over the laxify:// scheme.
"""
from html import escape

from fastapi import APIRouter, HTTPException, status
from fastapi.responses import HTMLResponse

from app.core.config import settings

router = APIRouter(tags=["pages"])

# Matches DeepLink.swift's four cases exactly — this is not a second link
# format, it is an https front door onto the one the app already parses.


_TG_LOGIN_TEMPLATE = """<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>Laxify</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; height: 100%; overflow-x: hidden; }}
  body {{
    background: #000;
    display: flex; align-items: center; justify-content: center;
    padding: 20px;
  }}
  #tg {{ display: flex; justify-content: center; align-items: center; width: 100%; }}
  #tg iframe {{ max-width: 100% !important; }}
</style>
</head>
<body>
  <div id="tg"></div>

  <script async src="https://telegram.org/js/telegram-widget.js?22"
    data-telegram-login="{bot_username}"
    data-size="large"
    data-radius="12"
    data-request-access="write"
    data-onauth="onTelegramAuth(user)"></script>

  <script>
    function onTelegramAuth(user) {{
      var parts = [];
      for (var key in user) {{
        if (Object.prototype.hasOwnProperty.call(user, key) && user[key] != null) {{
          parts.push(encodeURIComponent(key) + "=" + encodeURIComponent(user[key]));
        }}
      }}
      window.location.href = "laxify://auth/telegram?" + parts.join("&");
    }}
  </script>
</body>
</html>
"""


@router.get("/tg-login", response_class=HTMLResponse)
async def telegram_login_page() -> HTMLResponse:
    html = _TG_LOGIN_TEMPLATE.format(bot_username=settings.telegram_bot_username)
    # No-store: the page is a throwaway bridge and must always pull a fresh widget.
    return HTMLResponse(html, headers={"Cache-Control": "no-store"})


_OPEN_KINDS = {"track", "artist", "album", "playlist"}

# Telegram (and most chat apps) will not turn an <a href> using an arbitrary
# custom scheme into a tappable link — verified live: a laxify:// href sent
# through the Bot API came back with no text_link entity at all, silently
# dropped. An ordinary https link to this page is what gets tapped; the
# page's only job is to hand the visit straight on to the real laxify://
# link the app already knows how to open (see DeepLink.swift), the same
# bounce /tg-login above already does for sign-in.
_OPEN_TEMPLATE = """<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>Laxify</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; height: 100%; }}
  body {{
    background: #000; color: #fff;
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    gap: 18px; padding: 24px; text-align: center;
  }}
  a {{
    color: #000; background: #fff; text-decoration: none;
    font-weight: 600; padding: 14px 28px; border-radius: 999px;
  }}
</style>
</head>
<body>
  <div>Открыть в Laxify</div>
  <a href="{deep_link}">Открыть</a>
  <script>window.location.href = "{deep_link}";</script>
</body>
</html>
"""


@router.get("/open/{kind}/{identifier}", response_class=HTMLResponse)
async def open_in_app(kind: str, identifier: str) -> HTMLResponse:
    if kind not in _OPEN_KINDS or not identifier:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Не найдено")

    deep_link = escape(f"laxify://{kind}/{identifier}", quote=True)
    html = _OPEN_TEMPLATE.format(deep_link=deep_link)
    return HTMLResponse(html, headers={"Cache-Control": "no-store"})
