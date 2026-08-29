"""Deploy the comments / notifications / profile-likes / account-linking
backend to the Laxify server.

Run it yourself — Claude's shell is blocked from touching the server:

    cd "C:/Users/amond/Desktop/действующие проекты/агент тг"
    .venv/Scripts/python.exe "../Laxify/backend/scripts/deploy_social.py"

It reuses the SSH host/password from `агент тг/.env`, uploads the changed
`app/` files (backing each up to `<file>.pre-social.bak`), makes sure
`requirements.txt` is satisfied, runs the idempotent SQL from
`backend/sql/2026-08-30_social.sql`, records the alembic revision,
restarts `laxify-api` and prints the health check.

Set these in `/opt/laxify/.env` afterwards for the optional bits:
    TENOR_API_KEY=...        # GIF search (tenor.com, free)
    CATBOX_USERHASH=...      # ties comment uploads to a Catbox account (optional)
"""
import os
import posixpath
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                          # .../Laxify/backend
AGENT = os.path.abspath(os.path.join(REPO, "..", "..", "агент тг"))
REMOTE = "/opt/laxify"

sys.path.insert(0, AGENT)
from dotenv import dotenv_values          # noqa: E402
import paramiko                           # noqa: E402

_env = dotenv_values(os.path.join(AGENT, ".env"))
HOST = _env["SERVER_HOST"]
USER = _env.get("SERVER_SSH_USER", "root")
PW = _env["SERVER_SSH_PASSWORD"]

FILES = [
    "app/core/config.py",
    "app/models/user.py",
    "app/models/social.py",
    "app/models/__init__.py",
    "app/schemas/social.py",
    "app/services/media.py",
    "app/services/gif.py",
    "app/api/v1/comments.py",
    "app/api/v1/notifications.py",
    "app/api/v1/social.py",
    "app/api/v1/auth.py",
    "app/api/v1/router.py",
]

SQL_FILE = os.path.join(REPO, "sql", "2026-08-30_social.sql")

MIG = '''"""social: comments, reactions, profile likes, notifications
Revision ID: 20260830_social
Revises: {head}
"""
from alembic import op

revision = "20260830_social"
down_revision = "{head}"
branch_labels = None
depends_on = None


def upgrade():
    pass  # applied out of band via sql/2026-08-30_social.sql (idempotent)


def downgrade():
    pass
'''


def sh(client, cmd):
    _, out, err = client.exec_command(cmd, timeout=180)
    text = out.read().decode(errors="replace") + err.read().decode(errors="replace")
    print(f"$ {cmd}\n{text.rstrip()}\n{'-' * 56}")
    return text


def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PW, timeout=20)
    sftp = client.open_sftp()
    try:
        versions = sh(client, f"ls -1 {REMOTE}/alembic/versions/*.py | sort | tail -1")
        head_path = versions.strip().splitlines()[-1] if versions.strip() else ""
        head = "20260822_0747_client_reports"
        if head_path:
            out = sh(client, f"grep -E '^revision = ' {head_path}")
            m = re.search(r'revision\s*=\s*["\']([^"\']+)["\']', out)
            if m:
                head = m.group(1)
        print(f"alembic head: {head}\n{'-' * 56}")

        for rel in FILES:
            remote = posixpath.join(REMOTE, rel)
            local = os.path.join(REPO, rel.replace("/", os.sep))
            sh(client, f"test -f {remote} && cp -n {remote} {remote}.pre-social.bak || true")
            sftp.put(local, remote)
            print(f"uploaded {rel}\n{'-' * 56}")

        # requirements (python-multipart / httpx are already pinned; safe re-run)
        sh(client, f"{REMOTE}/.venv/bin/pip install -q -r {REMOTE}/requirements.txt 2>&1 | tail -3")

        with open(SQL_FILE, encoding="utf-8") as fh:
            sql = fh.read()
        sftp_sql = f"{REMOTE}/sql_social_tmp.sql"
        with sftp.open(sftp_sql, "w") as fh:
            fh.write(sql)
        sh(client, f"sudo -u postgres psql laxify -v ON_ERROR_STOP=1 -f {sftp_sql} && rm {sftp_sql}")

        with sftp.open(f"{REMOTE}/alembic/versions/20260830_social.py", "w") as fh:
            fh.write(MIG.format(head=head))
        sh(client, f"cd {REMOTE} && .venv/bin/alembic stamp 20260830_social 2>&1 | tail -3")

        sh(client, "systemctl restart laxify-api && sleep 5 && systemctl is-active laxify-api")
        sh(client, "curl -s http://127.0.0.1:8100/health")
        sh(client, "curl -s -o /dev/null -w 'comments list HTTP %{http_code}\\n' "
                   "'http://127.0.0.1:8100/api/v1/tracks/test123/comments'")
        sh(client, "curl -s -o /dev/null -w 'notifications HTTP %{http_code}\\n' "
                   "http://127.0.0.1:8100/api/v1/notifications")
        sh(client, "journalctl -u laxify-api -n 20 --no-pager | tail -20")
        print("\n==> health ok + comments list HTTP 200 + notifications HTTP 401 means it's live.")
    finally:
        sftp.close()
        client.close()


if __name__ == "__main__":
    main()
