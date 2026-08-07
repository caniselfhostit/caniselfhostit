You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install PocketBase 0.39.10 under ~/selfhost/pocketbase, answering at http://localhost:8166.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
PocketBase is a backend, so its worth is that another program calls it, and it answers only at
http://localhost:8166. The app they build against it works in a browser here; the phone they
wanted to test from gets a connection error. What they keep is a real auth, database and file
API of their own.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. PocketBase needs 512 MB of RAM available
and 5 GB free on the home disk; the image publishes amd64, arm64 and armv7. On macOS and
Windows that figure is the host's, and Docker Desktop's VM takes its share of it. If RAM is
under 512 MB or free disk under 5 GB, print both and stop.

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
  terms, and wait for the whale icon to say it is running. Do not continue until they
  confirm.
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
mkdir -p ~/selfhost/pocketbase/data ~/selfhost/pocketbase/backups
ls -la ~/selfhost/pocketbase
```

`data` holds the SQLite database and every uploaded file, `backups` step 8's archives. On
Linux only, the container runs as uid 1000 against a real directory, so hand `data` over:

```bash
sudo chown -R 1000:1000 ~/selfhost/pocketbase/data
```

Do not run that on macOS or Windows, where Docker Desktop rewrites ownership across its file
share and the container already sees itself as the owner.

Assert: `ls -la` lists both directories, and on Linux `data` belongs to `1000`. Keep this off
any folder a sync service watches: SQLite needs real POSIX file locks.

## 4. Secrets

One secret: the password of the first superuser account. Generate it here, print it nowhere,
and keep it out of your summary and any log line. Hex rather than base64, because the user
retypes it into a login form.

```bash
umask 077
cat > ~/selfhost/pocketbase/.env <<EOF
PB_ADMIN_EMAIL=admin@example.com
PB_ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/pocketbase/.env
umask 022
ls -l ~/selfhost/pocketbase/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same everywhere. On Windows those mode bits are advisory: NTFS does not enforce them, and the
real boundary is the user's own Windows account.

`admin@example.com` is a login name, not a mailbox. Tell the user their password is in that
file, read with `grep PB_ADMIN_PASSWORD ~/selfhost/pocketbase/.env`, and belongs in a password
manager now. The file stays the source of truth: the entrypoint runs `superuser upsert` from
those two variables at every start, so a password changed in the dashboard is overwritten at
the next restart.

## 5. compose.yml

```bash
cat > ~/selfhost/pocketbase/compose.yml <<'EOF'
# PocketBase · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   production notes ... https://pocketbase.io/docs/going-to-production/
#   health endpoint .... https://pocketbase.io/docs/api-health/
#   image entrypoint ... https://github.com/muchobien/pocketbase-docker/blob/22f36a08837f26b22a3327cb8066ad63c3362c70/entrypoint.sh
#
# One container. Paths are relative to ~/selfhost/pocketbase/, so one file
# works on macOS, Linux and Windows, and nothing off this machine reaches 8166.
#
# The PocketBase project publishes no image: upstream's production page states
# that PocketBase doesn't have an official Docker image. This file therefore
# uses ghcr.io/muchobien/pocketbase, packaged outside that project at the
# revision above, the one this digest was built from. Its Dockerfile unpacks
# upstream's release zip without checking it against the checksums.txt
# published beside it, and neither does upstream's own example Dockerfile, so
# what fixes these bytes is the digest below: step 7 asserts the binary in it
# reports 0.39.10. Read from ghcr.io 2026-08-07; amd64, arm64 and armv7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  pocketbase:
    image: ghcr.io/muchobien/pocketbase:0.39.10@sha256:dfebd2550d6b5176d67afd3e859f9b642096e624c7f6ada1b5a5bc70a5d21be1
    container_name: pocketbase
    restart: unless-stopped
    # The image declares no USER, so without this it runs as root and what it
    # writes into ./data on Linux comes back owned by root.
    user: "1000:1000"
    env_file: ./.env
    environment:
      # It has to listen on every interface inside the container or the
      # published loopback port reaches nothing. 8090 is the entrypoint's own
      # default, named here so a change to it cannot move the port.
      PB_HOST: "0.0.0.0"
      PB_PORT: "8090"
    volumes:
      # The one mount: SQLite database, uploaded files, and PocketBase's own
      # backup archives. Keep off synced folders: SQLite wants POSIX locks.
      - ./data:/pb_data
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8090/api/health || exit 1"]
      start_period: 10s
      interval: 15s
      retries: 10
    ports:
      # Loopback only. No other device on this network reaches 8166, not even
      # your own phone.
      - "127.0.0.1:8166:8090"
EOF
cd ~/selfhost/pocketbase && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the dashboard's crypto works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8166 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/pocketbase/compose.yml
```

Assert: that prints `1`, the published port line. The pattern carries the opening quote so the
healthcheck's own `http://127.0.0.1:8090` is not counted.

## 7. Start and verify

The entrypoint creates the superuser from .env, then starts the server.

```bash
cd ~/selfhost/pocketbase
docker compose pull
docker compose up -d
docker compose exec -T pocketbase pocketbase --version
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8166/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8166/api/health
echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8166/api/collections
docker compose logs pocketbase | grep -c 'Successfully saved superuser'
```

Assert all five, and print what you received for each: the version line contains `0.39.10`, so
this image carries upstream's release binary; the loop ends on `200`; the health body contains
`"message":"API is healthy."`; `/api/collections` prints `401`, the security assert here,
because that route wants a superuser token; the last prints at least `1`, so the superuser
existed before the first request.

If any misses, stop, run `docker compose logs --tail 40 pocketbase`, and name the likely cause.
A restart loop complaining about `/pb_data` means step 3's chown did not run on Linux. If
`port is already allocated` came back, find what holds 8166
(`lsof -nP -iTCP:8166 -sTCP:LISTEN`, or `netstat -ano | findstr :8166`) and stop until the
user frees it. A running container is not success.

The first screen at http://localhost:8166/_/ is a login form headed `Superuser login`, with an
email field, a password field and no way to create an account.

STOP: tell the user to open http://localhost:8166/_/, read their password with
`grep PB_ADMIN_PASSWORD ~/selfhost/pocketbase/.env`, sign in as `admin@example.com`, and save
both in their password manager. Do not continue until they confirm.

## 8. First backup and restore

Take the backup now, before the user creates a collection. Stop the container first: upstream
says copying `pb_data` is the backup, and that the application must not be running for it.

```bash
cd ~/selfhost/pocketbase
docker compose stop
tar -czf backups/pocketbase-$(date +%F).tar.gz data compose.yml .env
docker compose start
ls -lh backups/
```

Assert: the archive exists and is non-empty, and `tar -tzf` on it lists `data/data.db`. Print
its size. On Linux, if `tar` prints `Cannot open: Permission denied`, the login user is not uid
1000: rerun with `sudo`, and say the archive now belongs to root. It is the whole install: the
database, the uploaded files, the compose file and the password.

A backup on the same disk is not a backup, and on one computer the disk and the machine fail
together. Get a copy off this machine now: ask which folder a sync service already watches
(iCloud Drive, OneDrive, Dropbox, Syncthing), or have them plug in a USB stick, under /Volumes
on macOS, usually /media on Linux, a drive letter such as /d in Git Bash. Confirm it with
`ls -d`, `cp` the archive there, print the result, and do not guess a path: `~/Dropbox` is
absent on most machines.

To restore, run `ls -lh backups/`, have the user name the archive, and put that filename in
both `ARCHIVE` slots. Nothing is deleted until `tar -tzf` has read it through:

```bash
cd ~/selfhost/pocketbase
tar -tzf backups/ARCHIVE >/dev/null && docker compose down && rm -rf data && tar -xzf backups/ARCHIVE && docker compose up -d
```

That one line is the whole disaster plan. On Linux, if the login user is not uid 1000, run the
`rm -rf` and the `tar` under `sudo`, then chown `data` back to 1000 before starting.

## 9. Updating later

New versions are at https://github.com/pocketbase/pocketbase/releases, and the image tags that
follow them at https://github.com/muchobien/pocketbase-docker/pkgs/container/pocketbase. Back
up first, then edit the image line in ~/selfhost/pocketbase/compose.yml to the new digest:

```bash
cd ~/selfhost/pocketbase
docker compose pull
docker compose up -d
docker compose logs --tail 30 pocketbase
```

PocketBase migrates its own database on the way up, so watch that log settle, then re-run
step 7's health and version checks. PocketBase is pre-1.0 and breaking changes land in
minor releases, so read the release notes first.

## 10. What will probably go wrong

I rebooted, opened the app I was building, and every API call came back as a connection error
that read exactly like a bug in my code. It was not: Docker Desktop had not started with
the session, so nothing was listening on 8166. `restart: unless-stopped` acts only once the
Docker daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/pocketbase && docker compose up -d` before suspecting your own code.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8166 to 0.0.0.0 so a phone on the same wifi can reach it. That puts an
  application server holding real accounts on every network the user joins.
- Do not configure SMTP or S3. PocketBase works without either.
- Do not add mounts for /pb_public or /pb_hooks. Serving a frontend and writing JavaScript
  hooks are compose edits for when the user has something to put in them.
- Do not build an application on top of this. Collections and API rules are the user's work.
