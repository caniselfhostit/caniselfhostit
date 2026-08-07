You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Miniflux 2.3.3, with the PostgreSQL it stores every feed and entry in, under
~/selfhost/miniflux, answering at http://localhost:8180.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Miniflux polls feeds only while this computer is awake with Docker running, so a closed lid
collects nothing, and http://localhost:8180 means "this computer" wherever it is read, so no
phone reader app can reach this one.

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
distribution ID and codename print next, for step 2. Miniflux plus PostgreSQL needs 1024 MB of
RAM available and 5 GB free on the home disk, and both images publish amd64 and arm64. If
either floor is missed, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/miniflux/backups
ls -la ~/selfhost/miniflux
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: feeds, entries,
read state and the account are rows in PostgreSQL, and step 5 keeps that database in a volume
Docker manages, so there is no ownership fix to run.

## 4. Secrets

Two secrets: the PostgreSQL password and the password for the user's own Miniflux account.
Generate both here, print neither, and keep both out of your summary and out of any log line.
Git Bash ships openssl, so these run the same on all three.

```bash
umask 077
cat > ~/selfhost/miniflux/.env <<EOF
BASE_URL=http://localhost:8180
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$(openssl rand -base64 24)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/miniflux/.env
umask 022
ls -l ~/selfhost/miniflux/.env
```

Assert: the file exists with mode `-rw-------`. The database password is hex because upstream
warns that special characters can be rejected inside a URL-style connection string unless they
are URL encoded. Tell the user their username is `admin`, that they read the password with
`grep ADMIN_PASSWORD ~/selfhost/miniflux/.env`, and that they put it in their password manager
now. On Windows those mode bits are advisory: the boundary is their own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/miniflux/compose.yml <<'EOF'
# Miniflux · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://miniflux.app/docs/docker.html
#   configuration ...... https://miniflux.app/docs/configuration.html
#   database ........... https://miniflux.app/docs/database.html
#
# Two services on the computer the reader is sitting at. Paths are relative to
# ~/selfhost/miniflux/, so one file works on macOS, Linux and Windows. Miniflux
# writes nothing to disk, so the database is the whole backup surface, and it is
# a named volume because PostgreSQL chowns that directory to its own uid, which
# a home-directory bind mount cannot allow on Windows. No TLS here, so the VPS
# file's HTTPS setting is absent. Digests read on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: miniflux-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: miniflux
      POSTGRES_USER: miniflux
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - miniflux-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U miniflux -d miniflux"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  miniflux:
    image: miniflux/miniflux:2.3.3@sha256:49d7b60987616387c306a8023087b31f2c9b7b21288b523026cb04058e8b6dbb
    container_name: miniflux
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Hex, not base64: upstream warns special characters can be rejected in
      # this URL form unless URL encoded.
      DATABASE_URL: postgres://miniflux:${DB_PASSWORD}@postgres:5432/miniflux?sslmode=disable
      # Miniflux exits when the schema is behind the binary, so this stays set.
      RUN_MIGRATIONS: "1"
      # The one account comes from ADMIN_USERNAME and ADMIN_PASSWORD in .env;
      # later starts log a skip. Miniflux has no self-registration.
      CREATE_ADMIN: "1"
    healthcheck:
      # Upstream's own: the binary asks its own /healthcheck route.
      test: ["CMD", "/usr/bin/miniflux", "-healthcheck", "auto"]
      interval: 10s
      retries: 12
    ports:
      # Loopback only; the same host port the VPS compose file publishes.
      - "127.0.0.1:8180:8080"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  miniflux-pgdata:
EOF
cd ~/selfhost/miniflux && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose reads ./.env from this folder for the
`${DB_PASSWORD}` substitution, which is why every later command starts by changing into it.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8180 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/miniflux/compose.yml
```

Assert: that prints `1`, the single published-port entry `- "127.0.0.1:8180:8080"`. PostgreSQL
declares no `ports:`, so 5432 cannot appear. A `0.0.0.0:8180` or a bare `8180:8080` there means
the file was edited: put the `127.0.0.1:` prefix back first.

## 7. Start and verify

Miniflux runs its migrations on the way up and creates the one account from the environment
during that start-up.

```bash
cd ~/selfhost/miniflux
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8180/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8180/healthcheck; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8180/v1/me
curl -sS http://localhost:8180/ | grep -c 'Sign In - Miniflux'
docker compose logs miniflux | grep -c 'admin user'
```

Assert all five, and print what you received for each: the loop ends on `200`; the health body
is `OK`, which upstream returns only when the database answers too; the unauthenticated API
call prints `401`, the security assert here: the REST API is on by default and refuses a call
with no token; the page grep prints `1`, the login screen's title; the log grep
prints `1` or more, matching `Created new admin user`, or `Skipping admin user creation` on a
repeat. If any misses, stop, run `docker compose logs --tail 40 miniflux` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a database that never
reports healthy is step 4, where an empty `DB_PASSWORD` leaves PostgreSQL refusing to start. If
`port is already allocated` came back, find what holds 8180
(`lsof -nP -iTCP:8180 -sTCP:LISTEN`, or `netstat -ano | findstr :8180` on Windows) and stop
until the user frees it, because 8180 is inside `BASE_URL`. A running container is not success.

The first screen at http://localhost:8180 is a sign-in form with `Username` and `Password`
fields and a `Login` button, and the browser tab reads `Sign In - Miniflux`. There is no
sign-up link, because Miniflux has none to show.

STOP: tell the user to open http://localhost:8180, sign in as `admin` with the password from
step 4, and wait. Do not continue until they confirm they are looking at the reader. Then tell
them feeds poll once an hour by default, so a subscription added now can leave the list empty
for a while, and the refresh button proves it works today.

## 8. First backup and restore

Two artifacts: a database dump with every feed, entry and read mark, and a config archive with
the two files that rebuild the service around it.

```bash
cd ~/selfhost/miniflux
docker compose exec -T postgres pg_dump -U miniflux -d miniflux | gzip > ~/selfhost/miniflux/backups/miniflux-db-$(date +%F).sql.gz
tar -C ~/selfhost/miniflux -czf ~/selfhost/miniflux/backups/miniflux-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/miniflux/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together, so this is not a backup yet. Ask the user for a destination that leaves this
computer, a folder their sync service watches or a USB stick, and copy both there with `cp`.
In Git Bash a Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user
confirms both filenames are listed there. Otherwise say plainly there is no backup.

To restore, in this order. `cd ~/selfhost/miniflux`, untar the config archive there first, so
compose.yml and .env are back before any container starts: PostgreSQL takes `DB_PASSWORD` from
.env the moment it initialises an empty volume, and a missing .env means a blank password and a
database that will not start. Then `docker compose down -v`, the one place `-v` belongs because
it drops the old volume on purpose, `docker compose up -d postgres`, wait about 30 seconds for
healthy, then pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U miniflux -d miniflux`, then `docker compose up -d`.
Sign in and check the subscriptions are back. That is the disaster plan.

## 9. Updating later

New versions are listed at https://github.com/miniflux/v2/releases. Take both backups first,
then edit the image line in ~/selfhost/miniflux/compose.yml to the new tag and digest.

```bash
cd ~/selfhost/miniflux
docker compose pull
docker compose up -d
docker compose logs --tail 30 miniflux
```

Miniflux exits at start-up if the schema is behind the binary, which is why `RUN_MIGRATIONS`
stays set rather than being a one-off. Watch that log until it settles, then re-run step 7's
health check before calling the update done.

## 10. What will probably go wrong

I shut the laptop on a Friday and opened the reader on Monday expecting the weekend. Miniflux
does not catch up. Its scheduler runs only while the container runs, and on restart it fetches
what each feed holds at that moment, so anything that scrolled out of a busy feed over the
weekend is gone and nothing in the interface says it was there. Turn on Docker Desktop's
start-at-login setting, and tell the user plainly that a computer which sleeps is a reader with
holes in it.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8180 to 0.0.0.0 for a phone app, and do not point `BASE_URL` at this machine's
  wifi address. Both put the reader on every network the user joins.
- Do not enable the Google Reader or Fever API. Each hands out a second credential, and no
  device but this one can reach the endpoint it would authenticate against.
- Do not lower `POLLING_FREQUENCY` below its 60 minute default. That multiplies requests to
  sites that did not ask for them.
