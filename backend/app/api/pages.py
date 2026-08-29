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
<title>Вход в Laxify</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; height: 100%; }}
  body {{
    background: #000; color: #fff;
    font: 400 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    display: flex; align-items: center; justify-content: center;
    padding: 24px; text-align: center;
  }}
  .card {{ width: 100%; max-width: 360px; }}
  .logo {{
    width: 64px; height: 64px; margin: 0 auto 22px;
    border-radius: 20px; background: #0A84FF;
    display: flex; align-items: center; justify-content: center;
    font: 800 34px/1 -apple-system, system-ui, sans-serif;
  }}
  h1 {{ font-size: 22px; font-weight: 700; margin: 0 0 10px; }}
  p {{ color: #98989F; margin: 0 0 26px; }}
  .err {{ color: #FF6B6B; margin-top: 18px; min-height: 1.2em; }}
  #tg {{ display: flex; justify-content: center; min-height: 46px; }}
</style>
</head>
<body>
  <div class="card">
    <div class="logo">L</div>
    <h1>Вход через Telegram</h1>
    <p>Telegram передаст приложению только имя, юзернейм и аватар.</p>
    <div id="tg"></div>
    <p class="err" id="err"></p>
  </div>

  <script async src="https://telegram.org/js/telegram-widget.js?22"
    data-telegram-login="{bot_username}"
    data-size="large"
    data-radius="12"
    data-request-access="write"
    data-onauth="onTelegramAuth(user)"></script>

  <script>
    function onTelegramAuth(user) {{
      try {{
        var parts = [];
        for (var key in user) {{
          if (Object.prototype.hasOwnProperty.call(user, key) && user[key] != null) {{
            parts.push(encodeURIComponent(key) + "=" + encodeURIComponent(user[key]));
          }}
        }}
        window.location.href = "laxify://auth/telegram?" + parts.join("&");
      }} catch (e) {{
        document.getElementById("err").textContent = "Ошибка: " + e;
      }}
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
