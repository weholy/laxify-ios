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


# Same copy TermsView.swift's built-in fallback already shows in-app — this
# is that text made into a real page, not new wording, so the two never
# quietly disagree with each other.
_LEGAL_TEMPLATE = """<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>Laxify — {title}</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; background: #000; }}
  body {{
    color: rgba(255,255,255,0.92);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    line-height: 1.55;
    padding: 32px 20px 64px;
    max-width: 640px;
    margin: 0 auto;
  }}
  h1 {{ font-size: 26px; margin: 0 0 28px; }}
  h2 {{ font-size: 17px; margin: 28px 0 8px; }}
  p {{ font-size: 15px; color: rgba(255,255,255,0.72); margin: 0; }}
  nav {{ margin-bottom: 22px; }}
  nav a {{
    color: rgba(255,255,255,0.55); text-decoration: none; font-size: 14px;
    margin-right: 18px; border-bottom: 1px solid transparent;
  }}
  nav a.current {{ color: #fff; border-bottom-color: rgba(255,255,255,0.4); }}
  footer {{ margin-top: 40px; font-size: 13px; color: rgba(255,255,255,0.4); }}
  footer a {{ color: inherit; }}
</style>
</head>
<body>
  <nav>
    <a class="{terms_class}" href="/terms">Условия</a>
    <a class="{privacy_class}" href="/privacy">Данные</a>
  </nav>
  <h1>{title}</h1>
  {body}
  <footer>Laxify · вопросы — <a href="https://t.me/skyredy">t.me/skyredy</a></footer>
</body>
</html>
"""


def _section(heading: str, body: str) -> str:
    return f"<h2>{escape(heading)}</h2><p>{escape(body)}</p>"


_TERMS_SECTIONS = [
    ("Что такое Laxify",
     "Laxify — приложение для прослушивания музыки. Мы не размещаем музыку сами: приложение показывает "
     "и воспроизводит то, что опубликовано на открытых музыкальных платформах, и права на неё принадлежат "
     "их авторам и правообладателям."),
    ("Ваш аккаунт",
     "Аккаунт нужен, чтобы избранное, плейлисты и статистика были одинаковыми на всех ваших устройствах. "
     "Отвечайте за сохранность пароля: любой, кто его знает, получит доступ к вашей библиотеке."),
    ("Как пользоваться",
     "Слушайте сколько угодно и для себя. Не используйте приложение для перепродажи музыки, массового "
     "скачивания или обхода ограничений правообладателей."),
    ("Если что-то не работает",
     "Приложение зависит от внешних источников музыки. Иногда трек становится недоступен не по нашей вине — "
     "мы стараемся такие случаи замечать и обходить, но гарантировать доступность каждой записи не можем."),
    ("Изменения",
     "Условия могут меняться. О существенных изменениях мы сообщим в приложении до того, как они вступят в силу."),
]

_PRIVACY_SECTIONS = [
    ("Что мы храним",
     "Почту, имя и то, что вы сами добавили в профиль. Избранное, плейлисты и историю прослушиваний — "
     "чтобы они были на всех ваших устройствах и чтобы работала «Моя волна»."),
    ("Статистика",
     "Мы записываем, что и сколько вы слушали. Это нужно для экрана статистики и для подбора музыки. "
     "По умолчанию её видите только вы — открыть её другим можно в настройках."),
    ("Диагностика",
     "Приложение отправляет технические записи о своей работе: сколько занял запуск трека, какие ошибки "
     "произошли. Это нужно, чтобы находить и чинить проблемы. Содержимое вашей библиотеки в них не попадает."),
    ("Чего мы не делаем",
     "Не продаём ваши данные, не передаём их рекламным сетям и не читаем вашу переписку — приложение "
     "к ней и не имеет доступа."),
    ("Удаление",
     "Вы можете выйти из аккаунта в любой момент. Чтобы удалить аккаунт вместе со всеми данными, "
     "напишите нам — сделаем это без вопросов."),
]


def _legal_page(*, title: str, sections: list[tuple[str, str]], active: str) -> HTMLResponse:
    body = "".join(_section(heading, text) for heading, text in sections)
    html = _LEGAL_TEMPLATE.format(
        title=title,
        body=body,
        terms_class="current" if active == "terms" else "",
        privacy_class="current" if active == "privacy" else "",
    )
    return HTMLResponse(html, headers={"Cache-Control": "public, max-age=3600"})


@router.get("/terms", response_class=HTMLResponse)
async def terms_page() -> HTMLResponse:
    return _legal_page(title="Условия использования", sections=_TERMS_SECTIONS, active="terms")


@router.get("/privacy", response_class=HTMLResponse)
async def privacy_page() -> HTMLResponse:
    return _legal_page(title="Обработка данных", sections=_PRIVACY_SECTIONS, active="privacy")
