You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Shlink 5.1.5, with the PostgreSQL it stores links in, under ~/selfhost/shlink,
answering at http://localhost:8086.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Every short link this creates begins with http://localhost:8086, which means "this
computer" wherever it is read, so one sent to a colleague or opened on the user's own phone
resolves to nothing. They get a private index of their own links with visit counts, not a
shortener anyone else can use.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux
the distribution ID and codename print next, for step 2. Shlink plus PostgreSQL needs
1024 MB of RAM available and 5 GB free on the home disk, and both images publish amd64 and
arm64. Every branch prints free memory, so one floor covers all three; on macOS and Windows
it is the host's, and Docker Desktop's virtual machine takes its allocation out of it. If
available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope.

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
mkdir -p ~/selfhost/shlink/backups
ls -la ~/selfhost/shlink
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: links and
visits are rows in PostgreSQL, and step 5 keeps that database in a volume Docker manages,
so nothing here needs an ownership fix on any of the three systems.

## 4. Secrets

Two secrets: the PostgreSQL password and the initial API key. Generate both here, print
neither, and keep both out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/shlink/.env <<EOF
DEFAULT_DOMAIN=localhost:8086
TIMEZONE=UTC
DB_PASSWORD=$(openssl rand -hex 32)
INITIAL_API_KEY=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/shlink/.env
umask 022
ls -l ~/selfhost/shlink/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run
the same on all three. Upstream documents `INITIAL_API_KEY` as an admin key made once at
container start-up, so it is the credential the user's scripts use. Do not run the CLI
command that lists API keys: it prints their values to the terminal.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary
is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/shlink/compose.yml <<'EOF'
# Shlink · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://shlink.io/documentation/install-docker-image/
#   variable reference . https://shlink.io/documentation/environment-variables/
#   database engines ... https://shlink.io/documentation/supported-db-engines/
#   api health check ... https://shlink.io/documentation/api-docs/
#
# Two services on the computer you are sitting at. Every path in it is relative
# to ~/selfhost/shlink/, which lets one file work on macOS, Linux and Windows.
# SQLite is ignored: upstream says it is for testing only. The database is a
# named volume, not a bind mount, because PostgreSQL chowns its data directory
# to its own uid and a home-directory bind mount cannot allow that on Windows.
# Digests read on 2026-08-05; both images publish amd64 and arm64.
# DEFAULT_DOMAIN is localhost:8086, so links resolve on this computer only.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: shlink-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: shlink
      POSTGRES_USER: shlink
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - shlink-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U shlink -d shlink"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  shlink:
    image: shlinkio/shlink:5.1.5@sha256:77b8eb87bcb1a56bd0ecc590398d415545e5ba83414f28d37dc565a91c3c50b2
    container_name: shlink
    restart: unless-stopped
    env_file: ./.env
    environment:
      DB_DRIVER: postgres
      DB_HOST: postgres
      DB_NAME: shlink
      DB_USER: shlink
      # Nothing terminates TLS here, so the links this prints say http.
      IS_HTTPS_ENABLED: "false"
      # No IP tracking: no GeoLite2 download, no MaxMind account. Visits
      # are still counted, not placed on a map.
      DISABLE_IP_TRACKING: "true"
    ports:
      # Loopback only: no other device on the wifi can reach 8086.
      - "127.0.0.1:8086:8080"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  shlink-pgdata:
EOF
cd ~/selfhost/shlink && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8086 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a
laptop on the same wifi, nor anyone on the internet. For a shortener that is the shape of
the trade. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/shlink/compose.yml
```

Assert: one line, `- "127.0.0.1:8086:8080"`. PostgreSQL publishes no host port, so 5432
cannot appear.

## 7. Start and verify

Shlink migrates its own database on the way up and creates the key named in
`INITIAL_API_KEY` during that start-up.

```bash
cd ~/selfhost/shlink
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8086/rest/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8086/rest/health
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8086/rest/v3/short-urls
docker compose exec -T shlink shlink short-url:create https://example.com/ --custom-slug=selfhost-check
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8086/selfhost-check
```

Assert all five, and print what you received for each: the loop ends on `200`; the health
response contains `"status":"pass"`; the unauthenticated API call prints `401`,
upstream's answer to a missing or invalid key and the security assert here; the CLI
prints `http://localhost:8086/selfhost-check`; the last curl prints `302`, a slug that
went into the database and came back as a redirect. If any of the five misses, stop, run
`docker compose logs --tail 40 shlink` and `docker compose logs --tail 20 postgres`, and
name the likely cause: a database that never reports healthy points at step 4, where an
empty `DB_PASSWORD` leaves PostgreSQL refusing to start; a shlink log still moving through
migrations wants more time. If `port is already allocated` came back, find what holds 8086
(`lsof -nP -iTCP:8086 -sTCP:LISTEN`, `ss -ltnp | grep 8086` on Linux,
`netstat -ano | findstr :8086` on Windows) and stop until the user frees it: the port is
inside `DEFAULT_DOMAIN` and inside every link. A running container is not success.

There is no first screen: Shlink has no web interface and http://localhost:8086/ answers
`404`, which is correct, not broken. What a human looks at is
http://localhost:8086/rest/health, a small JSON object whose `status` reads `pass`.

STOP: tell the user to read their API key with
`grep INITIAL_API_KEY ~/selfhost/shlink/.env`, put it in their password manager, and wait.
Do not continue until they confirm. It is this install's only credential. The test link
goes whenever they like:
`docker compose exec -T shlink shlink short-url:delete selfhost-check`.

## 8. First backup and restore

Two artifacts: a database dump with the links, slugs and visit counts, and a config
archive with the two files that rebuild the service around it.

```bash
cd ~/selfhost/shlink
docker compose exec -T postgres pg_dump -U shlink -d shlink | gzip > ~/selfhost/shlink/backups/shlink-db-$(date +%F).sql.gz
tar -C ~/selfhost/shlink -czf ~/selfhost/shlink/backups/shlink-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/shlink/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the
disk and the machine fail together. Ask the user for a destination that leaves this
computer, a folder their sync service watches or a USB stick, and copy both there with
`cp`. In Git Bash a Windows drive is written `/d/Backups`, not `D:\Backups`; confirm the
destination exists before copying. Assert: the user confirms both filenames are listed
there. If they have neither, say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/shlink`, untar the config archive there first so
compose.yml and .env are back before any container starts: PostgreSQL takes `DB_PASSWORD`
from .env the moment it initialises an empty volume, and a missing .env means a blank
password and a database that will not start. Then `docker compose down -v`, the one place
`-v` belongs because it drops the old database volume on purpose,
`docker compose up -d postgres`, wait about 30 seconds for it to report healthy, then pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U shlink -d shlink`,
then `docker compose up -d`. Follow one link and check it answers `302`. That is the whole
disaster plan.

## 9. Updating later

New versions are listed at https://github.com/shlinkio/shlink/releases. Take both backups
first, then edit the image line in ~/selfhost/shlink/compose.yml to the new tag and
digest:

```bash
cd ~/selfhost/shlink
docker compose pull
docker compose up -d
docker compose logs --tail 30 shlink
```

Watch that log until it settles, then re-run step 7's health check before calling the
update done.

## 10. What will probably go wrong

I rebooted this machine, opened a link I had shortened the day before, and got a
connection error that reads like a lost database. It was not: Docker Desktop had not
started with the session, so nothing was listening on 8086 and every link was dead until
it did. `restart: unless-stopped` acts only once the Docker daemon is up. Turn on its
start-at-login setting, then after a reboot run `cd ~/selfhost/shlink && docker compose up -d`
before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `DEFAULT_DOMAIN` to this machine's LAN address and do not rebind 8086 to
  0.0.0.0 so a phone can reach it. That puts an unauthenticated redirector on every
  network the user joins.
- Do not install shlink-web-client. That dashboard is a separate container; this prompt
  installs the server it talks to.
- Do not set `GEOLITE_LICENSE_KEY` or enable IP tracking. That means a MaxMind account,
  which this install trades country charts to avoid.
- Do not set `DEFAULT_BASE_URL_REDIRECT`. Where the bare address sends a visitor is the
  user's call, not a fix for step 7's `404`.
