You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Plausible CE 3.2.1 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer. It
becomes `BASE_URL` and goes into the tracking snippet on every page they measure, so changing it
later means editing all of them. Its A record must already point here.

Plausible CE needs 2048 MB of RAM available and 10 GB free on /srv. ClickHouse needs SSE 4.2 on
amd64 or NEON on arm64. All three images publish both.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
grep -o -m1 -E 'sse4_2|asimd' /proc/cpuinfo || echo "NO SSE4.2 OR NEON"
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both and stop: ClickHouse is
the process the kernel kills, and it dies mid-write. Stop too if the fourth command prints
`NO SSE4.2 OR NEON` or `dig +short` prints nothing.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/plausible /srv/plausible/backups /srv/plausible/clickhouse
sudo install -d -m 700 /srv/plausible/postgres /srv/plausible/clickhouse/data
sudo install -d -m 750 -o 999 -g 999 /srv/plausible/data
```

ClickHouse is built for a 16 GB machine and behaves that way unless told otherwise. This file is
what holds it inside a small VPS; compose mounts it read-only in step 4.

```bash
cat > /srv/plausible/clickhouse/plausible-ce.xml <<'EOF'
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
chmod 644 /srv/plausible/clickhouse/plausible-ce.xml
ls -la /srv/plausible /srv/plausible/clickhouse
```

Assert: `backups` and `clickhouse` belong to the login user, `postgres` and `clickhouse/data` are
`drwx------` owned by root, `data` is owned by `999`, and the XML file is listed. Leave those
ownerships: each database image chowns its own data directory on first start, and the app image
runs as uid 999 and writes under /var/lib/plausible.

## 3. Secrets

Three secrets, generated here on the server: the session key base, the key encrypting two-factor
secrets at rest, and the PostgreSQL password. Print none of them, repeat none in your summary,
and keep them out of the logs.

```bash
umask 077
cat > /srv/plausible/.env <<EOF
BASE_URL=https://<DOMAIN>
SECRET_KEY_BASE=$(openssl rand -base64 48)
TOTP_VAULT_KEY=$(openssl rand -base64 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/plausible/.env
umask 022
ls -l /srv/plausible/.env
```

Assert: mode `-rw-------`. Upstream documents the key base as needing at least a 64-byte string,
which `openssl rand -base64 48` gives, and the vault key as a 32-byte value encrypting two-factor
secrets with AES256-GCM; written out rather than derived, the two rotate independently. Tell the
user this file is the only copy of all three.

## 4. compose.yml

```bash
cat > /srv/plausible/compose.yml <<'EOF'
# Plausible CE · the deterministic fallback, authored by caniselfhostit from
# https://plausible.io/docs/self-hosting , the quick start at
# https://github.com/plausible/community-edition , its wiki page
# https://github.com/plausible/community-edition/wiki/configuration and
# https://clickhouse.com/docs/en/operations/tips . Not copied from a repository.
#
# Three services: the app, the PostgreSQL holding accounts and sites, and the
# ClickHouse holding every pageview event, which assumes a 16 GB machine and is
# cut down by the read-only XML file step 2 writes. Neither database
# publishes a host port. Digests read 2026-08-05; amd64 and arm64 both.
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
      - /srv/plausible/postgres:/var/lib/postgresql/data
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
      - /srv/plausible/clickhouse/data:/var/lib/clickhouse
      - /srv/plausible/clickhouse/plausible-ce.xml:/etc/clickhouse-server/config.d/plausible-ce.xml:ro
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8123/ping || exit 1"]
      interval: 10s
      retries: 18
    # No `ports:`: 8123 stays on the compose network.

  plausible:
    image: ghcr.io/plausible/community-edition:v3.2.1@sha256:33e60bfb40f2df5da00f8753b76fad04f67dba3abe6d73eb516e440e3fb62985
    restart: unless-stopped
    command: sh -c "/entrypoint.sh db createdb && /entrypoint.sh db migrate && /entrypoint.sh run"
    env_file: /srv/plausible/.env
    environment:
      TMPDIR: /var/lib/plausible/tmp
      # Caddy terminates TLS on the host, so HTTPS_PORT stays unset here.
      HTTP_PORT: "8000"
      DISABLE_REGISTRATION: "true"
      DATABASE_URL: postgres://plausible:${POSTGRES_PASSWORD}@plausible_db:5432/plausible_db
      CLICKHOUSE_DATABASE_URL: http://plausible_events_db:8123/plausible_events_db
    volumes:
      - /srv/plausible/data:/var/lib/plausible
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8093.
      - "127.0.0.1:8093:8000"
    depends_on:
      plausible_db:
        condition: service_healthy
      plausible_events_db:
        condition: service_healthy
EOF
cd /srv/plausible && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The `command:` line is upstream's: create both databases, run
every pending migration, then start. Safe on every restart, because an existing database is
reported and skipped.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, `<DOMAIN>` replaced by the real
hostname. Copy the file first: a syntax error takes down every other site here.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-plausible
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Plausible CE · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/plausible/community-edition/wiki/reverse-proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box, which is also BASE_URL
# in .env and is baked into the tracking snippet on every page you measure. The
# dashboard is a LiveView: reverse_proxy passes its WebSocket upgrade unaided.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No X-Frame-Options: Plausible's shared dashboards are meant to be iframed.

	# 8093 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8093
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` and the reload both exit 0. If validate fails, restore
/etc/caddy/Caddyfile.before-plausible, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it alone.

## 6. Firewall

Two ports open, both Caddy's. Idempotent: on a Prompt Zero box they change nothing.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8093 stays closed because compose binds it to 127.0.0.1, 5432 and 8123 because compose
never publishes them. Assert: `Status: active`, rules for 80, 443/tcp and 443/udp, nothing
mentioning 8093, 5432 or 8123.

## 7. Start and verify

The first start creates both databases, runs every migration, and gives ClickHouse minutes to lay
out its data directory. Do not intervene inside it.

```bash
cd /srv/plausible
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/system/health/ready); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/system/health/ready
curl -sSL https://<DOMAIN>/ | grep -c 'Register your Plausible CE account'
```

Assert all three, printing what you got. The loop ends on `200`. In the health JSON,
`"clickhouse"` and `"postgres"` both read `ok`. The last prints `1`: with no account yet,
https://<DOMAIN>/ redirects to https://<DOMAIN>/register, whose first screen carries the heading
`Register your Plausible CE account`. On any miss, stop, run
`docker compose logs --tail 40 plausible`, and name the cause: `connection refused` against
ClickHouse points at a step 2 XML file, a 502 means migrations are still running, a certificate
error means step 1's A record. A running container is not success.

STOP: tell the user to open https://<DOMAIN>/register, create the first account with a password
they keep in their password manager, and wait. Do not continue until they confirm.

Then prove registration is closed:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
```

Assert: `302`. `DISABLE_REGISTRATION` is `true`, which upstream bypasses exactly once, for the
first account on an instance with no users; from here that page redirects to the login form.
Both asserts pass before you report success.

## 8. First backup and restore

Three artifacts: PostgreSQL holds accounts, sites and settings, ClickHouse holds every event
recorded, and the config archive rebuilds the service around them, secrets included.

```bash
cd /srv/plausible
docker compose exec -T plausible_db pg_dump -U plausible -d plausible_db | gzip > /srv/plausible/backups/plausible-pg-$(date +%F).sql.gz
docker compose stop
sudo tar -C /srv/plausible/clickhouse -czf /srv/plausible/backups/plausible-events-$(date +%F).tar.gz data
sudo tar -C /srv/plausible -czf /srv/plausible/backups/plausible-config-$(date +%F).tar.gz compose.yml .env clickhouse/plausible-ce.xml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/plausible/backups/
```

Assert: all three exist, all three are non-empty, and print all three sizes. `pg_dump` snapshots a
running database consistently, so it goes first; the ClickHouse archive is cold, because copying
that directory under a live server restores into corruption. Downtime is half a minute.

A backup on the same disk is not a backup, so run this on the user's machine:

```bash
mkdir -p ~/backups/plausible
scp vps:/srv/plausible/backups/* ~/backups/plausible/
```

To restore: `docker compose down`, `sudo rm -rf /srv/plausible/postgres /srv/plausible/clickhouse/data`,
recreate both at mode 700 as in step 2, untar the config archive into /srv/plausible and the events
archive into /srv/plausible/clickhouse, `docker compose up -d plausible_db`, wait thirty seconds,
pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T plausible_db psql -U plausible -d plausible_db`, then `docker compose up -d`.
The config archive goes back first: PostgreSQL reads .env the moment it initialises an empty
directory.

## 9. Updating later

New versions are listed at https://github.com/plausible/analytics/releases, roughly two a year.
Take all three backups first, then edit the image line in /srv/plausible/compose.yml to the new
tag and digest:

```bash
cd /srv/plausible
docker compose pull
docker compose up -d
docker compose logs --tail 40 plausible
```

Migrations run on the way up, so watch that log until it settles, then re-run step 7's health
check before calling the update done. Read the release notes for a major version first: those
can carry a data migration longer than the start-up allowance.

## 10. What will probably go wrong

ClickHouse is the part that will scare you. On the first start it lays out its data directory and
answers nothing for minutes while Plausible retries its migrations against it and logs connection
failures that read like a broken install. I reached for `docker compose down` twice before the
health endpoint went green at about four minutes, both times interrupting an install that was
working. Let step 7's loop run its full ten minutes first. And the XML file in step 2 is load
bearing: delete it because the install "works without it", and ClickHouse goes back to assuming
16 GB with the kernel taking that container in your first busy hour.

## 11. Out of scope

- Do not configure SMTP. Plausible CE runs without it; the user gives up password-reset mail and
  the weekly report email, neither worth a port-25 fight on a fresh VPS.
- Do not set `MAXMIND_LICENSE_KEY` or `IP_GEOLOCATION_DB`. Country data needs a MaxMind account,
  and this install trades the map for not having one.
- Do not set `GOOGLE_CLIENT_ID` or `GOOGLE_CLIENT_SECRET`. Search Console is its own registration
  in Google Cloud.
- Do not set `HTTPS_PORT` and do not publish 80 or 443 from the container. The image carries its
  own certbot, which would fight Caddy over one certificate.
