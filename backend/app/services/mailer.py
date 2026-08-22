"""Outgoing mail.

Delivery goes through a configured SMTP relay. When none is configured the
message is logged instead of sent — that keeps local runs and the test suite
working without a mail account, and makes the code visible in the server log
while the relay is still being set up.
"""

import logging
import smtplib
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

import anyio

from app.core.config import settings
from app.services import direct_mail

logger = logging.getLogger("laxify.mail")

BRAND = "Laxify"


def _shell(title: str, body: str) -> str:
    """The frame every message shares.

    Colours are inlined and the layout is a table: mail clients strip
    stylesheets and disagree about flexbox, so neither can be relied on.
    """
    return f"""\
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#0B0B0F;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0B0B0F;padding:40px 16px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
             style="max-width:440px;background:#141419;border-radius:28px;overflow:hidden;
                    font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Segoe UI',Roboto,sans-serif;">
        <tr>
          <td style="padding:36px 36px 8px 36px;" align="center">
            <div style="width:56px;height:56px;border-radius:18px;
                        background:linear-gradient(135deg,#FF5FA2 0%,#A855F7 52%,#5B7CFA 100%);
                        line-height:56px;text-align:center;font-size:26px;">&#9834;</div>
            <div style="margin-top:14px;font-size:15px;font-weight:600;letter-spacing:.4px;color:#8E8E99;">{BRAND}</div>
          </td>
        </tr>
        <tr>
          <td style="padding:18px 36px 36px 36px;" align="center">
            <h1 style="margin:0 0 10px 0;font-size:22px;line-height:1.3;font-weight:700;color:#FFFFFF;">{title}</h1>
            {body}
          </td>
        </tr>
        <tr>
          <td style="padding:0 36px 32px 36px;" align="center">
            <div style="height:1px;background:#26262E;margin-bottom:18px;"></div>
            <p style="margin:0;font-size:12px;line-height:1.6;color:#61616B;">
              Если вы не запрашивали письмо, просто удалите его — ничего не произойдёт.
            </p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>"""


def code_email(code: str, purpose: str) -> tuple[str, str, str]:
    headline = {
        "bind": "Подтвердите почту",
        "change": "Подтвердите новую почту",
        "login": "Вход в аккаунт",
        "reset": "Восстановление пароля",
    }.get(purpose, "Код подтверждения")

    digits = "".join(
        f'<td style="padding:0 5px;"><div style="width:52px;height:64px;background:#1E1E26;'
        f'border-radius:16px;line-height:64px;text-align:center;font-size:28px;font-weight:700;'
        f'color:#FFFFFF;letter-spacing:1px;">{d}</div></td>'
        for d in code
    )

    body = f"""
      <p style="margin:0 0 26px 0;font-size:15px;line-height:1.6;color:#9A9AA5;">
        Введите этот код в приложении. Он действует 10 минут.
      </p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto;"><tr>{digits}</tr></table>
    """

    text = f"{headline}\n\nВаш код: {code}\nОн действует 10 минут.\n\n{BRAND}"
    return f"{code} — код подтверждения {BRAND}", _shell(headline, body), text


def notice_email(title: str, message: str) -> tuple[str, str, str]:
    body = f'<p style="margin:0;font-size:15px;line-height:1.6;color:#9A9AA5;">{message}</p>'
    return f"{BRAND} — {title}", _shell(title, body), f"{title}\n\n{message}\n\n{BRAND}"


def _compose(to: str, subject: str, html: str, text: str) -> tuple[EmailMessage, str]:
    sender = settings.smtp_from or f"no-reply@{direct_mail.DEFAULT_SENDER_HOST}"

    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = f"{BRAND} <{sender}>"
    message["To"] = to
    # Headers a small sender is judged on: a stable message id from its own
    # domain, a real date, and a marker saying nobody typed this by hand.
    message["Reply-To"] = sender
    message["Message-ID"] = make_msgid(domain=sender.rsplit("@", 1)[-1])
    message["Date"] = formatdate(localtime=True)
    message["Auto-Submitted"] = "auto-generated"

    message.set_content(text)
    message.add_alternative(html, subtype="html")

    return message, sender


def _send_via_relay(message: EmailMessage, to: str) -> None:
    if settings.smtp_use_ssl:
        server = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=20)
    else:
        server = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=20)
        if settings.smtp_use_tls:
            server.starttls()

    with server:
        if settings.smtp_user:
            server.login(settings.smtp_user, settings.smtp_password or "")
        server.send_message(message)


async def send(to: str, subject: str, html: str, text: str) -> bool:
    """Never raises: a failed send must not fail the request that caused it.

    The caller has already written its state; someone can ask for another
    code, which is a better outcome than an error they cannot act on.

    A configured relay wins when there is one — it is the more reliable
    route. Otherwise the message goes straight to the recipient's own mail
    server, which needs no account anywhere.
    """
    message, sender = _compose(to, subject, html, text)

    if settings.smtp_host:
        try:
            await anyio.to_thread.run_sync(_send_via_relay, message, to)
            return True
        except Exception:
            logger.exception("Реле не приняло письмо для %s, пробую напрямую", to)

    try:
        await direct_mail.send(message, recipient=to, sender=sender)
        return True
    except Exception:
        logger.exception("Не удалось доставить письмо на %s", to)
        # Logged in full so a code is still recoverable from the journal
        # while delivery is being sorted out.
        logger.warning("Недоставленное письмо для %s: %s", to, text)
        return False
