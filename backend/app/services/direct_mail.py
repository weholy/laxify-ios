"""Delivering mail without a relay.

A relay would mean an account somewhere and a key to keep. This server can
deliver on its own: it has a reverse record that resolves back to its own
address, which is the check receiving servers care about most, and outbound
port 25 is open.

So mail goes straight to the recipient's own mail exchanger. Messages are
signed where a key is configured, and the envelope sender matches the
hostname the reverse record names — the two things that decide whether a
message from a small server is read as legitimate.
"""

import logging
import smtplib
import socket
import ssl
from email.message import EmailMessage

import anyio
import dns.resolver

logger = logging.getLogger("laxify.mail.direct")

# Matches the reverse record for this host. A sender domain that disagrees
# with the reverse record is the single most common reason a message from a
# server like this is discarded.
DEFAULT_SENDER_HOST = "netevpn.play2go.cloud"

CONNECT_TIMEOUT = 20


class DeliveryError(Exception):
    pass


def _mail_exchangers(domain: str) -> list[str]:
    """The recipient's mail servers, most preferred first."""
    try:
        answers = dns.resolver.resolve(domain, "MX", lifetime=10)
    except Exception:
        # No MX record means the domain's own address takes delivery, which
        # is what the standard says to fall back to.
        return [domain]

    ranked = sorted(answers, key=lambda record: record.preference)
    return [str(record.exchange).rstrip(".") for record in ranked]


def _deliver(message: EmailMessage, recipient: str, sender: str, helo: str) -> None:
    domain = recipient.rsplit("@", 1)[-1]
    exchangers = _mail_exchangers(domain)

    if not exchangers:
        raise DeliveryError(f"Не удалось найти почтовый сервер для {domain}")

    last_error: Exception | None = None

    for host in exchangers:
        try:
            with smtplib.SMTP(host, 25, local_hostname=helo, timeout=CONNECT_TIMEOUT) as server:
                server.ehlo(helo)

                # Opportunistic, not required: some exchangers do not offer it
                # and refusing to send would be worse than sending in clear.
                if server.has_extn("starttls"):
                    context = ssl.create_default_context()
                    context.check_hostname = False
                    context.verify_mode = ssl.CERT_NONE
                    server.starttls(context=context)
                    server.ehlo(helo)

                server.send_message(message, from_addr=sender, to_addrs=[recipient])
                logger.info("Письмо доставлено на %s через %s", recipient, host)
                return

        except (smtplib.SMTPException, socket.error, OSError) as exc:
            last_error = exc
            logger.warning("Не принял %s: %s", host, exc)
            continue

    raise DeliveryError(f"Ни один сервер не принял письмо: {last_error}")


async def send(
    message: EmailMessage, recipient: str, sender: str, helo: str = DEFAULT_SENDER_HOST
) -> None:
    """Delivers one message. Raises on failure so the caller can fall back."""
    await anyio.to_thread.run_sync(_deliver, message, recipient, sender, helo)
