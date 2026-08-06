You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Umami 3.2.0, with the PostgreSQL it stores every pageview in, under ~/selfhost/umami,
answering at http://localhost:8105.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all. The
tracking script has to be reachable from every browser that loads a tracked page, and
http://localhost:8105 means "this computer" in each of them. So this counts pages the user
opens here, on a site running here, and nothing anyone else loads.

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
distribution ID and codename print next, for step 2. Umami plus PostgreSQL needs 1024 MB of RAM
available and 5 GB free on the home disk, and both images publish amd64 and arm64. Every branch
prints free memory, so one floor covers all three; on macOS and Windows that is the host's, out
of which Docker Desktop takes its own allocation. If available RAM is under 1024 MB or free
disk is under 5 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/umami/backups
ls -la ~/selfhost/umami
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: Umami writes
nothing to disk, and step 5 keeps the database in a volume Docker manages, so nothing here
needs an ownership fix.

## 4. Secrets

Three secrets, all generated here. `DB_PASSWORD` is the PostgreSQL password, `APP_SECRET` signs
the login tokens, and `ADMIN_PASSWORD` replaces the password the image ships on its admin
account. Hex, not base64: two travel inside a URL and the third inside a JSON body. Print none
of them, and keep all three out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/umami/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
APP_SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/umami/.env
umask 022
ls -l ~/selfhost/umami/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. Docker Compose reads this file for the `${...}` substitutions in
compose.yml, so the first two reach the containers as environment variables and the file itself
is never mounted. `ADMIN_PASSWORD` is not an Umami setting; step 7 hands it to the API.
On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/umami/compose.yml <<'EOF'
# Umami · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   install ............ https://docs.umami.is/docs/install
#   variable reference . https://docs.umami.is/docs/environment-variables
#   heartbeat route .... https://github.com/umami-software/umami/blob/v3.2.0/src/app/api/heartbeat/route.ts
#
# Two services driven from ~/selfhost/umami/, so one file works on macOS, Linux
# and Windows. Version 3 is a PostgreSQL-only build, so the tag carries no
# database flavour. The database is a named volume rather than a bind mount:
# PostgreSQL chowns its data directory to its own uid, which Windows cannot
# grant on a home-directory mount. Umami itself writes nothing to disk. Digests
# read 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: umami-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: umami
      POSTGRES_USER: umami
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - umami-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U umami -d umami"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  umami:
    image: ghcr.io/umami-software/umami:3.2.0@sha256:8edfe4beaef13f9d1300619fa264ef250a3688df9cc54d24ca830ca31cb475ec
    container_name: umami
    restart: unless-stopped
    # init reaps the child processes the migration step leaves behind.
    init: true
    environment:
      # Docker Compose substitutes both values from ./.env, which is mode 600
      # and is never mounted into the container.
      DATABASE_URL: postgresql://umami:${DB_PASSWORD}@postgres:5432/umami
      APP_SECRET: ${APP_SECRET}
      # No anonymous usage pings leave this computer.
      DISABLE_TELEMETRY: "1"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/api/heartbeat || exit 1"]
      interval: 10s
      retries: 18
    ports:
      # Loopback only: no other device on the wifi can reach 8105.
      - "127.0.0.1:8105:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  umami-pgdata:
EOF
cd ~/selfhost/umami && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8105 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop
on the same wifi, nor anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/umami/compose.yml
```

Assert: one line, `- "127.0.0.1:8105:3000"`. PostgreSQL publishes no host port at all.

## 7. Start and verify

Umami applies its own schema migrations on the way up, which creates the built-in admin
account.

```bash
cd ~/selfhost/umami
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8105/api/heartbeat); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8105/api/heartbeat
curl -sS http://localhost:8105/login | grep -o '<title>[^<]*</title>'
```

Assert all three, and print what you received: the loop ends on `200`, the heartbeat prints
`{"ok":true}`, and the last command prints `<title>Login | Umami</title>`. If any of the three
misses, stop, run `docker compose logs --tail 40 umami` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a database that never
reports healthy points at step 4, where an empty `DB_PASSWORD` stops PostgreSQL starting. If
`port is already allocated` came back, find what holds 8105
(`lsof -nP -iTCP:8105 -sTCP:LISTEN`, or `netstat -ano | findstr :8105` on Windows) and stop
until the user frees it. A running container is not success.

Now close the account the image ships with. Upstream documents it as `admin` with a published
password, so it is a known credential until this runs:

```bash
cd ~/selfhost/umami
login=$(curl -sS -X POST http://localhost:8105/api/auth/login -H 'Content-Type: application/json' --data '{"username":"admin","password":"umami"}')
token=$(printf '%s' "$login" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
userid=$(printf '%s' "$login" | sed -n 's/.*"user":{"id":"\([^"]*\)".*/\1/p')
[ -n "$token" ] && [ -n "$userid" ] && echo "logged in"
printf '{"password":"%s"}' "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' ~/selfhost/umami/.env)" | curl -sS -o /dev/null -w '%{http_code}\n' -X POST "http://localhost:8105/api/users/${userid}" -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' --data-binary @-
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8105/api/auth/login -H 'Content-Type: application/json' --data '{"username":"admin","password":"umami"}'
unset login token userid
```

Assert all three: `logged in`, then `200` from the update, then `401` from the second login. If
the last line is anything but `401`, the shipped password still works: stop and say so. Neither
the password nor the token goes into your output.

The first screen at http://localhost:8105/login shows the wordmark `umami` over a `Username`
box, a `Password` box and a `Login` button.

STOP: tell the user to read their password with `grep ADMIN_PASSWORD ~/selfhost/umami/.env`,
put it in their password manager, sign in as `admin`, and confirm they see the dashboard. Wait.
Do not continue until they confirm.

## 8. First backup and restore

Two artifacts: a database dump with the accounts, websites and every pageview, and a config
archive with the two files that rebuild the service around it.

```bash
cd ~/selfhost/umami
docker compose exec -T postgres pg_dump -U umami -d umami | gzip > ~/selfhost/umami/backups/umami-db-$(date +%F).sql.gz
tar -C ~/selfhost/umami -czf ~/selfhost/umami/backups/umami-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/umami/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are listed there. If
they have neither, say so: this install has no backup.

To restore, in this order. `cd ~/selfhost/umami`, untar the config archive there first so
compose.yml and .env are back before any container starts: PostgreSQL takes `DB_PASSWORD` from
.env the moment it initialises an empty volume, and a missing .env means a blank password and
a database that will not start. Then `docker compose down -v`, the one place `-v` belongs because
it drops the old volume on purpose, `docker compose up -d postgres`, wait 30 seconds for it to
report healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U umami -d umami`, then `docker compose up -d`. That is
the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/umami-software/umami/releases. Back up first,
then edit the image line in ~/selfhost/umami/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/umami
docker compose pull
docker compose up -d
docker compose logs --tail 30 umami
```

Watch that log until it settles, then re-run step 7's heartbeat check before calling the update
done. After a major version jump upstream tells you to run `ANALYZE;` on the database, because
the migration leaves its query planner with stale statistics.

## 10. What will probably go wrong

I closed the laptop for two hours, opened the dashboard again, and read a flat line as a broken
tracker. It was not broken. Nothing had been running: the machine slept, both containers with
it, and the pages I loaded in that window were never counted and never will be. This dashboard
is only as continuous as the computer is awake. Check `docker compose ps` first.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8105 to 0.0.0.0 so another device can send events to it. That puts an open
  collector on every network the user joins.
- Do not configure SMTP and do not add Redis. Umami needs neither.
