"""One-shot deploy of the Telegram-login backend to the Laxify server.

Run it yourself (Claude's shell is blocked from touching the server):

    cd "C:/Users/amond/Desktop/действующие проекты/агент тг"
    .venv/Scripts/python.exe "../Laxify/backend/scripts/deploy_telegram.py"

It uses the SSH host/password already in `агент тг/.env`, uploads the seven
changed `app/` files (backing each up to `<file>.pre-tg.bak`), adds the
nullable `users.telegram_*` columns (idempotent), records the alembic
revision, writes the bot token from `агент тг/sessions/botfather_result.json`
into `/opt/laxify/.env`, restarts `laxify-api`, and prints the check.
Expect `tg-login HTTP 200` and `auth/telegram HTTP 401` at the end.
"""
import json
import os
import posixpath
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                      # .../Laxify/backend
AGENT = os.path.abspath(os.path.join(REPO, "..", "..", "агент тг"))
REMOTE = "/opt/laxify"

sys.path.insert(0, AGENT)
from dotenv import dotenv_values          # noqa: E402  (from агент тг/.venv)
import paramiko                           # noqa: E402

_env = dotenv_values(os.path.join(AGENT, ".env"))
HOST = _env["SERVER_HOST"]
USER = _env.get("SERVER_SSH_USER", "root")
PW = _env["SERVER_SSH_PASSWORD"]
TOKEN = json.load(open(os.path.join(AGENT, "sessions", "botfather_result.json"),
                       encoding="utf-8"))["token"]
assert TOKEN and ":" in TOKEN, "no bot token found"

FILES = [
    "app/core/config.py",
    "app/models/user.py",
    "app/services/telegram_auth.py",
    "app/schemas/auth.py",
    "app/api/v1/auth.py",
    "app/api/pages.py",
    "app/main.py",
]

SQL = (
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_id BIGINT; "
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_username VARCHAR(64); "
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_photo_url TEXT; "
    "CREATE UNIQUE INDEX IF NOT EXISTS ix_users_telegram_id ON users (telegram_id);"
)

MIG = '''"""telegram login columns
Revision ID: 20260829_tglogin
Revises: {head}
"""
from alembic import op

revision = "20260829_tglogin"
down_revision = "{head}"
branch_labels = None
depends_on = None


def upgrade():
    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_id BIGINT")
    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_username VARCHAR(64)")
    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS telegram_photo_url TEXT")
    op.execute("CREATE UNIQUE INDEX IF NOT EXISTS ix_users_telegram_id ON users (telegram_id)")


def downgrade():
    op.execute("DROP INDEX IF EXISTS ix_users_telegram_id")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS telegram_photo_url")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS telegram_username")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS telegram_id")
'''


def sh(client, cmd):
    _, out, err = client.exec_command(cmd, timeout=90)
    text = out.read().decode(errors="replace") + err.read().decode(errors="replace")
    print(f"$ {cmd}\n{text.rstrip()}\n{'-' * 56}")
    return text


def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PW, timeout=20)
    sftp = client.open_sftp()
    try:
        out = sh(client, f"grep -E '^revision = ' "
                         f"{REMOTE}/alembic/versions/20260822_0747_client_reports.py")
        m = re.search(r'revision\s*=\s*["\']([^"\']+)["\']', out)
        head = m.group(1) if m else "20260822_0747_client_reports"

        for rel in FILES:
            remote = posixpath.join(REMOTE, rel)
            local = os.path.join(REPO, rel.replace("/", os.sep))
            sh(client, f"test -f {remote} && cp -n {remote} {remote}.pre-tg.bak || true")
            sftp.put(local, remote)
            print(f"uploaded {rel}\n{'-' * 56}")

        sh(client, f'sudo -u postgres psql laxify -v ON_ERROR_STOP=1 -c "{SQL}"')

        with sftp.open(f"{REMOTE}/alembic/versions/20260829_tglogin.py", "w") as fh:
            fh.write(MIG.format(head=head))
        sh(client, f"cd {REMOTE} && .venv/bin/alembic stamp 20260829_tglogin 2>&1 | tail -3")

        sh(client, f"grep -q '^TELEGRAM_BOT_TOKEN=' {REMOTE}/.env || "
                   f"printf 'TELEGRAM_BOT_TOKEN=%s\\nTELEGRAM_BOT_USERNAME=LaxifyAppBot\\n' "
                   f"'{TOKEN}' >> {REMOTE}/.env")
        sh(client, f"grep -oE '^TELEGRAM_[A-Z_]+=' {REMOTE}/.env")

        sh(client, "systemctl restart laxify-api && sleep 4 && systemctl is-active laxify-api")
        sh(client, "curl -s -o /dev/null -w 'tg-login HTTP %{http_code}\\n' "
                   "http://127.0.0.1:8100/tg-login")
        sh(client, "curl -s http://127.0.0.1:8100/health")
        sh(client, "curl -s -o /dev/null -w 'auth/telegram HTTP %{http_code}\\n' -X POST "
                   "-H 'Content-Type: application/json' -d '{\"payload\":{}}' "
                   "http://127.0.0.1:8100/api/v1/auth/telegram")
        sh(client, "journalctl -u laxify-api -n 15 --no-pager | tail -15")
        print("\n==> if you see 'tg-login HTTP 200' above, the Telegram login is live.")
    finally:
        sftp.close()
        client.close()


if __name__ == "__main__":
    main()
