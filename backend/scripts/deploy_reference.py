"""Deploy the reference-catalogue filter and build the Deezer artist list.

Run it yourself (Claude's shell is blocked from the server):

    cd "C:/Users/amond/Desktop/действующие проекты/агент тг"
    .venv/Scripts/python.exe "../Laxify/backend/scripts/deploy_reference.py"

Uploads the changed files, restarts the API, then runs the Deezer walk on
the server to fill `reference_artists` (a few minutes). Once the table
passes ~6000 rows the authenticity filter switches itself on for search,
favourites and playlists.
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
HOST, USER, PW = _env["SERVER_HOST"], _env.get("SERVER_SSH_USER", "root"), _env["SERVER_SSH_PASSWORD"]

FILES = [
    "app/services/authenticity.py",
    "app/api/v1/library.py",
    "app/api/v1/playlists.py",
    "scripts/build_reference.py",
]


def sh(c, cmd, timeout=900):
    _, out, err = c.exec_command(cmd, timeout=timeout)
    text = out.read().decode(errors="replace") + err.read().decode(errors="replace")
    print(f"$ {cmd}\n{text.rstrip()}\n{'-' * 56}")
    return text


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=20)
    sftp = c.open_sftp()
    try:
        sh(c, f"mkdir -p {REMOTE}/scripts")
        for rel in FILES:
            remote = posixpath.join(REMOTE, rel)
            local = os.path.join(REPO, rel.replace("/", os.sep))
            sh(c, f"test -f {remote} && cp -n {remote} {remote}.pre-ref.bak || true")
            sftp.put(local, remote)
            print(f"uploaded {rel}\n{'-' * 56}")

        sh(c, "systemctl restart laxify-api && sleep 4 && systemctl is-active laxify-api")
        sh(c, "curl -s http://127.0.0.1:8100/health")

        print("==> building the Deezer reference list (several minutes)...")
        sh(c, f"cd {REMOTE} && .venv/bin/python scripts/build_reference.py", timeout=1800)

        sh(c, 'sudo -u postgres psql laxify -tc "select count(*) from reference_artists;"')
        sh(c, "curl -s -o /dev/null -w 'favorites HTTP %{http_code}\\n' "
              "http://127.0.0.1:8100/api/v1/me/favorites")
        print("\n==> done. If the count is > 6000 the filter is now live.")
    finally:
        sftp.close()
        c.close()


if __name__ == "__main__":
    main()
