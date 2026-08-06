You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Plausible CE 3.2.1, with the PostgreSQL and ClickHouse it stores traffic in, under
~/selfhost/plausible, answering at http://localhost:8093.

## 1. Preflight

Say this first; it decides whether the user wants this install. `BASE_URL` here is
http://localhost:8093, which means "this computer" in whoever reads it, so a public website
cannot send events to it: a visitor's browser would post the pageview to its own machine. This
measures sites the user runs here, a development server or a preview build.

Detect the OS and measure:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. This needs 2048 MB of RAM available and
10 GB free on the home disk, and all three images publish amd64 and arm64. On macOS and Windows
that figure is the host's and Docker Desktop takes its share, so check it has 4 GB. Under
either floor, print both and stop: ClickHouse is what gets killed, mid-write.

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
mkdir -p ~/selfhost/plausible/backups ~/selfhost/plausible/clickhouse
cat > ~/selfhost/plausible/clickhouse/plausible-ce.xml <<'EOF'
<clickhouse>
  <!-- Sized for a small machine, not the 16 GB one ClickHouse assumes. -->
  <logger><level>warning</level><console>true</console></logger>
  <listen_host>0.0.0.0</listen_host>
  <mark_cache_size>524288000</mark_cache_size>
  <max_server_memory_usage_to_ram_ratio>0.6</max_server_memory_usage_to_ram_ratio>
  <metric_log remove="remove"/><asynchronous_metric_log remove="remove"/>
  <query_log remove="remove"/><query_thread_log remove="remove"/>
  <trace_log remove="remove"/><part_log remove="remove"/>
</clickhouse>
EOF
ls -la ~/selfhost/plausible ~/selfhost/plausible/clickhouse
```

Assert: `backups` and `clickhouse` exist and the XML file is listed. ClickHouse is built for a
16 GB machine and behaves that way unless told otherwise; that file holds it down. The data
directories are Docker volumes, so there is no `data` folder and no ownership fix.

## 4. Secrets

Three secrets, generated here: the session key base, the key encrypting two-factor secrets at
rest, and the PostgreSQL password. Print none of them, and keep them out of your summary and out
of the logs.

```bash
umask 077
cat > ~/selfhost/plausible/.env <<EOF
BASE_URL=http://localhost:8093
SECRET_KEY_BASE=$(openssl rand -base64 48)
TOTP_VAULT_KEY=$(openssl rand -base64 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/plausible/.env
umask 022
ls -l ~/selfhost/plausible/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run everywhere. Upstream documents
the key base as at least 64 bytes and the vault key as 32 bytes, encrypting two-factor secrets
with AES256-GCM. On Windows those mode bits are advisory: NTFS ignores them, and the real
boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/plausible/compose.yml <<'EOF'
# Plausible CE · the deterministic fallback for the local path, authored by
# caniselfhostit from https://plausible.io/docs/self-hosting , the quick start
# at https://github.com/plausible/community-edition and its wiki page
# https://github.com/plausible/community-edition/wiki/configuration . Not
# copied from a repository.
#
# Three services, paths relative to ~/selfhost/plausible/ so one file works on
# macOS, Linux and Windows. Data lives in named volumes because Postgres,
# ClickHouse and the app each want a uid Docker Desktop on Windows cannot grant
# on a home-directory bind. Digests read 2026-08-05, amd64 and arm64 both.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  plausible_db:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_DB: plausible_db
      POSTGRES_USER: plausible
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - plausible-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U plausible -d plausible_db"]
      interval: 10s
      retries: 18
    # No `ports:`: 5432 is reachable only from the other containers.

  plausible_events_db:
    image: clickhouse/clickhouse-server:24.12.6.70-alpine@sha256:cd450891db46cc6ffe313ca2b0fb7dbfb897a6873ca74a724cbe050a2cf62621
    restart: unless-stopped
    environment:
      CLICKHOUSE_SKIP_USER_SETUP: "1"
    volumes:
      - plausible-chdata:/var/lib/clickhouse
      - ./clickhouse/plausible-ce.xml:/etc/clickhouse-server/config.d/plausible-ce.xml:ro
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8123/ping || exit 1"]
      interval: 10s
      retries: 18
    # No `ports:`: 8123 stays inside.

  plausible:
    image: ghcr.io/plausible/community-edition:v3.2.1@sha256:33e60bfb40f2df5da00f8753b76fad04f67dba3abe6d73eb516e440e3fb62985
    restart: unless-stopped
    command: sh -c "/entrypoint.sh db createdb && /entrypoint.sh db migrate && /entrypoint.sh run"
    env_file: ./.env
    environment:
      TMPDIR: /var/lib/plausible/tmp
      HTTP_PORT: "8000"
      DISABLE_REGISTRATION: "true"
      DATABASE_URL: postgres://plausible:${POSTGRES_PASSWORD}@plausible_db:5432/plausible_db
      CLICKHOUSE_DATABASE_URL: http://plausible_events_db:8123/plausible_events_db
    volumes:
      - plausible-appdata:/var/lib/plausible
    ports:
      # Loopback only: this computer, nothing else on the wifi.
      - "127.0.0.1:8093:8000"
    depends_on:
      plausible_db:
        condition: service_healthy
      plausible_events_db:
        condition: service_healthy

volumes:
  plausible-pgdata:
  plausible-chdata:
  plausible-appdata:
EOF
cd ~/selfhost/plausible && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS and no TLS: there is no hostname to resolve and no public name for a certificate to
  attest. Browsers treat http://localhost as a secure context, so pages needing crypto work.
- No firewall rule: nothing is published beyond loopback, so no port needs closing.

Assert by reading step 5's file back: the only published port is `- "127.0.0.1:8093:8000"`, and
neither database publishes one at all. The user's phone cannot reach this, nor a laptop on the
same wifi, nor anyone on the internet.

## 7. Start and verify

The first start creates both databases, runs every migration, and gives ClickHouse minutes to
lay out its data. Do not intervene inside it.

```bash
cd ~/selfhost/plausible
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8093/api/system/health/ready); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8093/api/system/health/ready
curl -sSL http://localhost:8093/ | grep -c 'Register your Plausible CE account'
```

Assert all three, printing what you got: the loop ends on `200`, the health JSON reads `ok` for
`"clickhouse"` and `"postgres"`, and the last prints `1`, because with no account yet
http://localhost:8093/ redirects to http://localhost:8093/register, whose first screen carries
the heading `Register your Plausible CE account`. On any miss, stop, run
`docker compose logs --tail 40 plausible` and name the cause: `connection refused` against
ClickHouse points at step 3's XML file, a log still in migrations wants more time, and `port is
already allocated` means something else holds 8093. A running container is not success.

STOP: tell the user to open http://localhost:8093/register, create the first account with a
password they keep in their password manager, and wait. Do not continue until they confirm.

Then prove registration is closed:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8093/register
```

Assert: `302`. `DISABLE_REGISTRATION` is `true`, which upstream bypasses once, for the first
account on an instance with no users. Both asserts pass before you report success.

## 8. First backup and restore

Three artifacts: accounts and sites in PostgreSQL, every event in ClickHouse, and a config archive
that rebuilds the service around them, secrets included. The events come out through a throwaway
container, because that data sits in a volume.

```bash
cd ~/selfhost/plausible
docker compose exec -T plausible_db pg_dump -U plausible -d plausible_db | gzip > backups/plausible-pg-$(date +%F).sql.gz
docker compose stop
docker compose run --rm --no-deps -T --entrypoint sh plausible_events_db -c 'tar -C /var/lib/clickhouse -czf - .' > backups/plausible-events-$(date +%F).tar.gz
tar -czf backups/plausible-config-$(date +%F).tar.gz compose.yml .env clickhouse
docker compose start
ls -lh backups/
```

Assert: all three exist, all three are non-empty, and print all three sizes. `pg_dump` snapshots a
running database consistently, so it goes first; the events archive is cold, because copying it
under a live server restores into corruption. Downtime is half a minute.

These sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a sync folder or
a USB stick, and copy all three there with `cp`; in Git Bash a Windows drive is `/d/Backups`.
Assert: the user confirms the three names are there.

To restore: `cd ~/selfhost/plausible`, untar the config archive there first because PostgreSQL
reads .env the moment it initialises an empty volume, then `docker compose down -v`. Then the
events command above, with `-xzf -` and `<` in place of `-czf -` and `>`, puts the events back.
Then `docker compose up -d plausible_db`, wait thirty seconds, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T plausible_db psql -U plausible -d plausible_db`, then
`docker compose up -d` and re-run step 7's health check.

## 9. Updating later

New versions are listed at https://github.com/plausible/analytics/releases, roughly two a year.
Take all three backups first, then edit the image line in ~/selfhost/plausible/compose.yml to
the new tag and digest:

```bash
cd ~/selfhost/plausible
docker compose pull
docker compose up -d
docker compose logs --tail 40 plausible
```

Migrations run on the way up, so watch that log until it settles, then re-run step 7's health
check. Read the release notes for a major version first: they can carry a longer migration.

## 10. What will probably go wrong

I rebooted, opened the dashboard the next morning, and got a connection refused that read like a
lost database. It was not: Docker Desktop had not started with the session, so nothing listened
on 8093 and nothing had been counted overnight either. `restart: unless-stopped` acts
only once the Docker daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/plausible && docker compose up -d` before concluding anything broke. The other
half of the same fact: while this machine sleeps, nothing is counted at all.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `BASE_URL` to this machine's LAN address, and do not rebind 8093 to 0.0.0.0 so a
  phone can reach it. That puts a login page on every network the user joins.
- Do not configure SMTP, and do not set `MAXMIND_LICENSE_KEY`, `IP_GEOLOCATION_DB`,
  `GOOGLE_CLIENT_ID` or `GOOGLE_CLIENT_SECRET`.
