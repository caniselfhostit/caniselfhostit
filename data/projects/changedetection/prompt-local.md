You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install changedetection.io 0.55.8 under ~/selfhost/changedetection, answering at
http://localhost:8205.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Checks only run while this computer is awake. A price drop at 3am is invisible until the
laptop opens again. What they get is a private watcher over pages they care about that works
while they are at this desk. Also: this install uses the plain HTTP fetcher only, with no
Playwright or sockpuppetbrowser sidecar, so JavaScript-only storefronts may snapshot as empty
shells until they add that path later.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
command -v python3 && python3 --version
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. changedetection.io needs 1024 MB of RAM
available and 5 GB free on the home disk, and the image publishes amd64 and arm64. Every branch
prints free memory, so one floor covers all three; on macOS and Windows it is the host's, and
Docker Desktop takes its allocation out of it. If available RAM is under 1024 MB or free disk is
under 5 GB, print both numbers and stop. Do not install and hope. Python 3 is required in step 4
to build `SALTED_PASS` the way upstream does; if it is missing, install it (Xcode CLT / brew /
the distro package / the python.org installer) or stop and say why.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/changedetection/data ~/selfhost/changedetection/backups
ls -la ~/selfhost/changedetection
```

Assert: `data` and `backups` exist under `~/selfhost/changedetection`. `data` is the host side of
the `/datastore` mount.

## 4. Secrets

One secret: the UI login password. Upstream does not read a `PASSWORD` environment variable. It
checks `SALTED_PASS` (base64 of salt plus pbkdf2-hmac-sha256), matching `SaltyPasswordField` at
tag 0.55.8. Generate on this machine and never print the values into the chat.

```bash
umask 077
LOGIN_PASSWORD="$(openssl rand -base64 24)"
export LOGIN_PASSWORD
SALTED_PASS="$(python3 - <<'PY'
import base64, hashlib, os, secrets
plain = os.environ.get("LOGIN_PASSWORD", "").encode("utf-8")
salt = secrets.token_bytes(32)
key = hashlib.pbkdf2_hmac("sha256", plain, salt, 100000)
print(base64.b64encode(salt + key).decode("ascii"))
PY
)"
cat > ~/selfhost/changedetection/.env <<EOF
BASE_URL=http://localhost:8205
LOGIN_PASSWORD=${LOGIN_PASSWORD}
SALTED_PASS=${SALTED_PASS}
EOF
chmod 600 ~/selfhost/changedetection/.env
umask 022
unset LOGIN_PASSWORD SALTED_PASS
ls -l ~/selfhost/changedetection/.env
```

Assert: the file exists with mode `-rw-------` (on Windows mode bits are advisory). Do not print
the password. Tell the user to read it with `grep LOGIN_PASSWORD ~/selfhost/changedetection/.env`
when they sign in.

## 5. compose.yml

```bash
cat > ~/selfhost/changedetection/compose.yml <<'EOF'
# changedetection.io · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker ............. https://github.com/dgtlmoon/changedetection.io/blob/0.55.8/README.md#docker
#   compose example .... https://github.com/dgtlmoon/changedetection.io/blob/0.55.8/docker-compose.yml
#   password ........... https://github.com/dgtlmoon/changedetection.io/wiki/Password-protection
#
# One service on the computer you are sitting at. Paths are relative to
# ~/selfhost/changedetection/. SALTED_PASS and BASE_URL come from ./.env.
# No Playwright sidecar on this path either. Digest read from Docker Hub on
# 2026-08-07 for tag 0.55.8.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  changedetection:
    image: dgtlmoon/changedetection.io:0.55.8@sha256:5438423d5e906eff4e8f7886823482ad23f472bf7b8530ccaca89fb48c337882
    container_name: changedetection
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/datastore
    ports:
      # Loopback only: no other device on the wifi can reach 8205.
      - "127.0.0.1:8205:5000"
EOF
cd ~/selfhost/changedetection && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount for state.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers treat
http://localhost as a secure context anyway. Nothing is published beyond loopback, so no port
needs closing.

8205 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop on
the same wifi, nor anyone on the internet. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/changedetection/compose.yml
```

Assert: that count is exactly `1`. The fetcher still reaches the internet normally: a loopback
binding governs what can arrive, not what the container can call.

## 7. Start and verify

```bash
cd ~/selfhost/changedetection
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8205/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sS -o /dev/null -w 'unauth_status=%{http_code}\n' http://localhost:8205/
curl -sSL http://localhost:8205/ | grep -ci 'password'
docker compose ps
```

Assert all of the following, and print what you received for each. The unauthenticated status is
`302` (or `401`/`403`): with `SALTED_PASS` set, unauthenticated callers hit the login view, not
the dashboard. The password-field count after following redirects is greater than `0`. If the
status is a bare dashboard `200` with no password field, stop and check `.env` and
`docker compose config`. If `port is already allocated` came back, find what holds 8205
(`lsof -nP -iTCP:8205 -sTCP:LISTEN`, `ss -ltnp | grep 8205` on Linux,
`netstat -ano | findstr :8205` on Windows) and stop until the user frees it. A running container
is not success.

STOP: tell the user to read `grep LOGIN_PASSWORD ~/selfhost/changedetection/.env`, open
http://localhost:8205/, sign in, and confirm they see the watches dashboard (empty is fine). Do not continue until they confirm.

Then re-check refusal:

```bash
curl -sS -o /dev/null -w 'still_unauth=%{http_code}\n' http://localhost:8205/
```

Assert: still not an open dashboard.

## 8. First backup and restore

One archive: the datastore, the compose file, and `.env`. No Caddyfile on this path.

```bash
cd ~/selfhost/changedetection
docker compose stop
tar -C ~/selfhost/changedetection -czf ~/selfhost/changedetection/backups/changedetection-$(date +%F).tar.gz data compose.yml .env
docker compose start
ls -lh ~/selfhost/changedetection/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped on purpose
so files under `data/` are not half-written. Never append `|| true` to this tar.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`; confirm it exists before copying. Assert: the
user confirms the filename is listed there. If they have nowhere, say plainly that this install
has no backup.

To restore: `cd ~/selfhost/changedetection`, `docker compose down`, move aside `data` and `.env`,
untar the archive there, then `docker compose up -d`. `data/` is every watch; `.env` is how they
log in.

## 9. Updating later

New versions are listed at https://github.com/dgtlmoon/changedetection.io/releases. Take a backup
first, then edit the image line in ~/selfhost/changedetection/compose.yml to the new tag and
digest:

```bash
cd ~/selfhost/changedetection
docker compose pull
docker compose up -d
docker compose logs --tail 30 changedetection
```

Re-run step 7's unauthenticated-refusal check after every upgrade. JavaScript-heavy pages need
the Playwright/sockpuppetbrowser sidecar documented at
https://github.com/dgtlmoon/changedetection.io/wiki/Playwright-content-fetcher; this local install
does not add it unless the user explicitly asks after reading the memory cost.

## 10. What will probably go wrong

I closed the lid on a Friday, opened the dashboard on Monday, and three watches had last run
Thursday night. The machine was asleep, so no check ran, and a check that never ran leaves no
diff behind. That is the honest shape of a watcher on a laptop. Turn on Docker Desktop's
start-at-login setting, and after any reboot run
`cd ~/selfhost/changedetection && docker compose up -d` before believing a "no change" figure.
The second failure mode is the empty JavaScript snapshot named in step 1: more frequent checks
will not fill it.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8205 to 0.0.0.0 so a phone on the wifi can load the UI. That puts an
  authenticated app on every network this machine joins, and the password is only as strong as
  the one in `.env`.
- Do not invent a `PASSWORD` environment variable.
- Do not add Playwright or sockpuppetbrowser unless the user explicitly asks after the
  limitation is clear.
