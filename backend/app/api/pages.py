"""Plain HTML pages served at the site root, outside the /api/v1 prefix.

Right now just the Telegram login bridge: the bot's domain (set with
/setdomain in @BotFather) points here, the app opens /tg-login in a web
sheet, and once Telegram signs the user in the page bounces the signed
payload back into the app over the laxify:// scheme.
"""
from fastapi import APIRouter
from fastapi.responses import HTMLResponse

from app.core.config import settings

router = APIRouter(tags=["pages"])


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
