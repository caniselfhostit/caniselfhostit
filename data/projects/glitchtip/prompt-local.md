You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install GlitchTip 6.2.3, with the PostgreSQL and Valkey it needs, under ~/selfhost/glitchtip,
answering at http://localhost:8123.

## 1. Preflight

Say this before step 2 runs; it decides whether the user wants this install at all. Every DSN
this instance hands out begins with http://localhost:8123, which means "this computer" wherever
it is read. Code running here can report to it; a staging server, a phone app or a colleague's
laptop cannot, and nor can this machine while it sleeps.

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
distribution ID and codename print next, for step 2. This stack needs 2048 MB of RAM available
and 20 GB free on the home disk, and all three images are multi-arch. On macOS and Windows that
memory figure is the host's, and Docker Desktop takes its allocation out of it. Under either
floor, print both and stop.

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
mkdir -p ~/selfhost/glitchtip/backups ~/selfhost/glitchtip/uploads
if [ "$(uname -s)" = "Linux" ]; then sudo chown 5000:5000 ~/selfhost/glitchtip/uploads; fi
ls -la ~/selfhost/glitchtip
```

Assert: `ls -la` shows `backups` and `uploads`. The GlitchTip image runs as uid 5000, so on
Linux that directory has to belong to 5000 or source-map uploads fail; on macOS and Windows the
fence is a no-op and Docker Desktop's file sharing owns that.

## 4. Secrets

Two secrets: the Django `SECRET_KEY` and the PostgreSQL password. Generate both here, print
neither, and keep both out of your summary and out of every log.

```bash
umask 077
cat > ~/selfhost/glitchtip/.env <<EOF
GLITCHTIP_DOMAIN=http://localhost:8123
ALLOWED_HOSTS=localhost,127.0.0.1
CSRF_TRUSTED_ORIGINS=http://localhost:8123
SECRET_KEY=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/glitchtip/.env
umask 022
ls -l ~/selfhost/glitchtip/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same everywhere.
`SECRET_KEY` signs the session cookies, and upstream logs a warning when it is left at its
shipped placeholder. On Windows those mode bits are advisory: NTFS does not enforce them, and
the user's own account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/glitchtip/compose.yml <<'EOF'
# GlitchTip · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   install guide ....... https://glitchtip.com/documentation/install
#   sample compose ...... https://glitchtip.com/assets/compose.sample.yml
#   backend at v6.2.3 ... https://gitlab.com/glitchtip/glitchtip-backend/-/tree/v6.2.3
#
# Three services, paths relative to ~/selfhost/glitchtip/ so one file works on
# macOS, Linux and Windows. SERVER_ROLE all_in_one is upstream's sample shape:
# one container migrates, maintains the Postgres partitions, then serves with
# the worker inside it. The database is a named volume, not a bind mount,
# because the PostgreSQL image chowns its data directory to its own uid and
# Docker Desktop's Windows file sharing cannot allow that on a home bind mount.
# Valkey gets no volume, matching upstream. Digests read 2026-08-06, multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: glitchtip

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    restart: unless-stopped
    environment:
      POSTGRES_DB: glitchtip
      POSTGRES_USER: glitchtip
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - glitchtip-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U glitchtip -d glitchtip"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the web container.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 12
    # No volume and no ports: cache and queue, reachable in-network only.

  web:
    image: glitchtip/glitchtip:6.2.3@sha256:95e0e2d6b1bc18446902ae0cb47910cc55d7c0d6756ee901b0cd8dce9f8ef5a9
    restart: unless-stopped
    env_file: ./.env
    environment:
      SERVER_ROLE: all_in_one
      DATABASE_URL: postgres://glitchtip:${DB_PASSWORD}@postgres:5432/glitchtip
      VALKEY_URL: redis://valkey:6379
      # One account can be made while the user table is empty, then
      # self-signup closes. Step 7 asserts the door shut.
      ENABLE_USER_REGISTRATION: "False"
      # Django Admin and the OpenAPI schema default to on in the code, off in
      # upstream's sample. Off here too: neither is needed to use this.
      ENABLE_ADMIN: "False"
      ENABLE_OPENAPI: "False"
    volumes:
      - ./uploads:/code/uploads
    healthcheck:
      test: ["CMD", "python", "healthcheck.py"]
      interval: 15s
      retries: 20
      start_period: 90s
    ports:
      # Loopback only: no other device on the wifi can reach 8123.
      - "127.0.0.1:8123:8000"
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy

volumes:
  glitchtip-pgdata:
EOF
cd ~/selfhost/glitchtip && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. No hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8123 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/glitchtip/compose.yml
```

Assert: one line, `- "127.0.0.1:8123:8000"`. Neither database publishes a host port.

## 7. Start and verify

```bash
cd ~/selfhost/glitchtip
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8123/_health/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8123/_health/; echo
curl -sS http://localhost:8123/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8123/api/0/organizations/
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8123/admin/
```

Assert all five, printing what you got. The loop ends on `200`. Health prints `ok`. The settings
line prints `"enableUserRegistration":true`, the door open only because the user table is empty.
The organizations call prints `401`, the answer to an API request with no credential. `/admin/`
prints `404`, because `ENABLE_ADMIN` is False. If any misses, stop, run
`docker compose logs --tail 40 web`, and name the cause: a database that never reports healthy
points at step 4, a web log still in migrations wants more time. On `port is already allocated`,
find what holds 8123 (`lsof -nP -iTCP:8123 -sTCP:LISTEN`, or `netstat -ano | findstr :8123` on
Windows) and stop until the user frees it: 8123 is inside every DSN.
A running container is not success.

The first screen at http://localhost:8123 is a login card headed `Login`, with a
`New to GlitchTip?` line and a `Sign Up` link under the form.

STOP: tell the user to open http://localhost:8123, follow `Sign Up`, create their account with a
password saved in a password manager first, then the organization GlitchTip asks for, then a
first project inside it, and wait. Do not continue until they confirm. It is the only moment
that account can be made, and no mail is configured, so a lost password has no reset link. The
project's settings show its DSN; the first event can only come from the user's own code pointed
at it, so this prompt does not send one.

Then prove the door shut:

```bash
curl -sS http://localhost:8123/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
```

Assert: `"enableUserRegistration":false`, and the user reloads the page and confirms the
`Sign Up` link is gone. Both must pass before you report success.

## 8. First backup and restore

Two artifacts: the database holds every account, project, issue and event, and the config
archive rebuilds the service around it.

```bash
cd ~/selfhost/glitchtip
docker compose exec -T postgres pg_dump -U glitchtip -d glitchtip | gzip > ~/selfhost/glitchtip/backups/glitchtip-db-$(date +%F).sql.gz
tar -C ~/selfhost/glitchtip -czf ~/selfhost/glitchtip/backups/glitchtip-config-$(date +%F).tar.gz compose.yml .env uploads
ls -lh ~/selfhost/glitchtip/backups/
```

Assert: both exist and are non-empty, and print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder their sync service
watches or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is written
`/d/Backups`. Assert: the user confirms both filenames are there. If they have neither, say
plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/glitchtip`, untar the config archive there first so
.env is back before any container starts: PostgreSQL reads `DB_PASSWORD` from it the moment it
initialises an empty volume. Then `docker compose down -v`, the one place `-v` belongs because
it drops the old volume on purpose, `docker compose up -d postgres`, wait 30 seconds, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U glitchtip -d glitchtip`,
then `docker compose up -d`. That is the whole disaster plan.

## 9. Updating later

GlitchTip develops on GitLab; releases are tagged at
https://gitlab.com/glitchtip/glitchtip-backend/-/tags, and the Docker Hub tag drops the leading
`v`. Back up first, then edit the image line to the new tag and digest:

```bash
cd ~/selfhost/glitchtip
docker compose pull
docker compose up -d
docker compose logs --tail 40 web
```

The web container migrates on the way up. Watch that log until it settles, then re-run step 7's
check.

## 10. What will probably go wrong

I rebooted this machine, ran the test meant to throw an error, and watched nothing arrive.
Nothing was broken: Docker Desktop had not started with the session, so nothing was listening on
8123, and the SDK swallowed the connection failure and carried on, which is what an error
reporter is supposed to do. That is the trap here: a silent tracker looks exactly like a day
with no bugs. Turn on Docker Desktop's start-at-login setting, and after a reboot run
`docker compose up -d` here before trusting an empty issue list.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `GLITCHTIP_DOMAIN` to this machine's LAN address and do not rebind 8123 to
  0.0.0.0 so another device can report to it. That puts an event-ingest endpoint on every
  network the user joins.
- Do not configure SMTP and do not set `EMAIL_URL`. With no mail transport GlitchTip turns email
  off on purpose: verification and reset leave the interface, and alerts go to a webhook.
