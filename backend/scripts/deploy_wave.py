"""Deploy the rotor-style personal wave + Yandex-style home feed (Batch 48).

Run it yourself — Claude's shell is blocked from touching the server:

    cd "C:/Users/amond/Desktop/действующие проекты/агент тг"
    .venv/Scripts/python.exe "../Laxify/backend/scripts/deploy_wave.py"

Uploads the changed app files (backing each up to `<file>.pre-wave.bak`),
runs the idempotent `sql/2026-08-29_wave_sessions.sql`, restarts
`laxify-api` and checks the new endpoints answer.
"""
import os
import posixpath
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
    "app/models/activity.py",
    "app/models/__init__.py",
    "app/api/v1/wave.py",
]

SQL_FILE = os.path.join(REPO, "sql", "2026-08-29_wave_sessions.sql")


def sh(client, cmd, timeout=180):
    _, out, err = client.exec_command(cmd, timeout=timeout)
    text = out.read().decode(errors="replace") + err.read().decode(errors="replace")
    print(f"$ {cmd}\n{text.rstrip()}\n{'-' * 56}")
    return text


def main():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PW, timeout=20)
    sftp = client.open_sftp()
    try:
        for rel in FILES:
            remote = posixpath.join(REMOTE, rel)
            local = os.path.join(REPO, rel.replace("/", os.sep))
            sh(client, f"test -f {remote} && cp -n {remote} {remote}.pre-wave.bak || true")
            sftp.put(local, remote)
            print(f"uploaded {rel}\n{'-' * 56}")

        with open(SQL_FILE, encoding="utf-8") as fh:
            sql = fh.read()
        sftp_sql = f"{REMOTE}/sql_wave_tmp.sql"
        with sftp.open(sftp_sql, "w") as fh:
            fh.write(sql)
        sh(client, f"sudo -u postgres psql laxify -v ON_ERROR_STOP=1 -f {sftp_sql} && rm {sftp_sql}")

        sh(client, "systemctl restart laxify-api && sleep 5 && systemctl is-active laxify-api")
        sh(client, "curl -s http://127.0.0.1:8100/health")
        sh(client, "sudo -u postgres psql laxify -tc "
                   "\"select count(*) from wave_sessions;\"")
        for path in ("/api/v1/wave/start", "/api/v1/wave/feed"):
            sh(client, f"curl -s -o /dev/null -w '{path} HTTP %{{http_code}}\\n' "
                       f"-X POST http://127.0.0.1:8100{path}")
        sh(client, "journalctl -u laxify-api -n 20 --no-pager | tail -20")
        print("\n==> health ok + wave_sessions table present + endpoints HTTP 401 "
              "(auth required) means it's live.")
    finally:
        sftp.close()
        client.close()


if __name__ == "__main__":
    main()
