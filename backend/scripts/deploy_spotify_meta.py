"""Deploy the Spotify metadata overlay (Batch 59).

    cd "C:/Users/amond/Desktop/действующие проекты/агент тг"
    .venv/Scripts/python.exe "../Laxify/backend/scripts/deploy_spotify_meta.py"

Installs `spotifyscraper`, uploads the changed app files, runs the idempotent
`sql/2026-08-30_track_meta.sql`, restarts, checks health, and (optionally)
kicks off the one-off backfill in the background.
"""
import os
import posixpath
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
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
    "requirements.txt",
    "app/models/library.py",
    "app/models/__init__.py",
    "app/services/spotify_meta.py",
    "app/services/catalog_meta.py",
    "app/services/sc_resolve.py",
    "app/api/v1/library.py",
    "app/api/v1/catalog.py",
    "app/api/v1/playlists.py",
    "scripts/backfill_track_meta.py",
]

SQL_FILES = [
    os.path.join(REPO, "sql", "2026-08-30_track_meta.sql"),
    os.path.join(REPO, "sql", "2026-08-31_spotify_links.sql"),
]
RUN_BACKFILL = False  # already ran; flip on for a fresh box


def sh(client, cmd, timeout=600):
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
        sh(client, f"mkdir -p {REMOTE}/scripts")
        for rel in FILES:
            remote = posixpath.join(REMOTE, rel)
            local = os.path.join(REPO, rel.replace("/", os.sep))
            sh(client, f"test -f {remote} && cp -n {remote} {remote}.pre-spotify.bak || true")
            sftp.put(local, remote)
            print(f"uploaded {rel}\n{'-' * 56}")

        sh(client, f"{REMOTE}/.venv/bin/pip install -q spotifyscraper==3.9.2 2>&1 | tail -3")

        for i, sql_path in enumerate(SQL_FILES):
            with open(sql_path, encoding="utf-8") as fh:
                sql = fh.read()
            sftp_sql = f"{REMOTE}/sql_meta_tmp_{i}.sql"
            with sftp.open(sftp_sql, "w") as fh:
                fh.write(sql)
            sh(client, f"sudo -u postgres psql laxify -v ON_ERROR_STOP=1 -f {sftp_sql} && rm {sftp_sql}")

        sh(client, "systemctl restart laxify-api && sleep 5 && systemctl is-active laxify-api")
        sh(client, "curl -s http://127.0.0.1:8100/health")

        # Does the embed-API bootstrap work from the server's IP?
        sh(client, f"cd {REMOTE} && .venv/bin/python -c "
                   "\"import asyncio; from app.services import spotify_meta as s; "
                   "print('search tracks:', len(asyncio.run(s.search('drake', 3))['tracks']))\"")

        if RUN_BACKFILL:
            sh(client, f"cd {REMOTE} && nohup .venv/bin/python -m scripts.backfill_track_meta "
                       f"> {REMOTE}/backfill_track_meta.log 2>&1 & echo started pid $!")
            sh(client, f"sleep 8 && tail -5 {REMOTE}/backfill_track_meta.log")

        sh(client, "sudo -u postgres psql laxify -tc "
                   "\"select count(*), count(*) filter (where matched) from track_meta;\"")
        print("\n==> health ok + 'search tracks: N' (N>0) means the scraper works from "
              "the server. Backfill runs in the background; watch "
              f"{REMOTE}/backfill_track_meta.log")
    finally:
        sftp.close()
        client.close()


if __name__ == "__main__":
    main()
