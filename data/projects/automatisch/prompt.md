You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Automatisch 0.15.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say this when you ask: `<DOMAIN>` becomes `API_URL`, and every webhook address this instance
hands a third party is built from it, so moving it later breaks published flows. Its A record
must point at this server already.

Automatisch needs 2048 MB of RAM available and 10 GB free on /srv. All three images publish
amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. Upstream publishes no sizing figure; this floor covers two Node processes,
PostgreSQL and Redis. If `dig +short` prints nothing, stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/automatisch /srv/automatisch/backups
sudo install -d -m 700 /srv/automatisch/postgres /srv/automatisch/redis
ls -la /srv/automatisch
```

Assert: `ls -la` shows `backups` owned by the login user, and `postgres` and `redis` at mode
`700` owned by root. Leave those two alone: both images chown their own data directory at first
start, and one already chowned to the login user makes PostgreSQL refuse to initialise.

## 3. Secrets

Four secrets: the key that encrypts every stored third-party credential, the key that verifies
inbound webhooks, the app secret key upstream documents as required, and the PostgreSQL password.
Generate all four on the server. Do not print any of them, do not repeat them in your summary,
and do not put them in a log line. Hex for all four: one rides inside a connection string.

```bash
umask 077
cat > /srv/automatisch/.env <<EOF
API_URL=https://<DOMAIN>
ENCRYPTION_KEY=$(openssl rand -hex 32)
WEBHOOK_SECRET_KEY=$(openssl rand -hex 32)
APP_SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/automatisch/.env
umask 022
ls -l /srv/automatisch/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user what the first two do, in
upstream's own words: they encrypt the credentials of third-party services and verify webhook
requests, and if they change, existing connections and flows stop working. The first belongs in
the user's password manager tonight, read with `sudo grep ENCRYPTION_KEY /srv/automatisch/.env`.

## 4. compose.yml

```bash
cat > /srv/automatisch/compose.yml <<'EOF'
# Automatisch · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installation ....... https://automatisch.io/docs/guide/installation
#   variable reference . https://automatisch.io/docs/advanced/configuration
#   credentials ........ https://automatisch.io/docs/advanced/credentials
#   url resolution ..... https://github.com/automatisch/automatisch/blob/v0.15.0/packages/backend/src/config/app.js
#
# Four services. One image runs twice: as the web and API process, and with
# WORKER=true as the queue worker, the split upstream documents for Docker.
# PostgreSQL holds the flows, the connections and the run history; Redis holds
# the BullMQ queues and the schedule of every published flow. Upstream's own
# compose file builds from a git checkout; this one runs the image their release
# workflow publishes to ghcr.io.
#
# API_URL is the one address variable that matters: config/app.js derives the
# API base, the web app URL and the webhook URL from it, where the documented
# HOST and PORT pair would build https://host:3000 and break the app icons in
# the editor. Digests read 2026-08-07; all images publish arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# The web process and the worker share an image; compose ignores x- keys.
x-automatisch-env: &automatisch-env
  APP_ENV: production
  POSTGRES_HOST: postgres
  POSTGRES_DATABASE: automatisch
  POSTGRES_USERNAME: automatisch
  REDIS_HOST: redis
  # No seeded admin: the first account is typed on the installation screen.
  DISABLE_SEED_USER: "true"
  TELEMETRY_ENABLED: "false"

x-automatisch: &automatisch
  image: ghcr.io/automatisch/automatisch:0.15.0@sha256:3bace7a12d5fb3f5b1305a6a52232270e0e0abd8465a8b78baacb07f6ea89594
  restart: unless-stopped
  env_file: /srv/automatisch/.env
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: automatisch-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: automatisch
      POSTGRES_USER: automatisch
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/automatisch/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U automatisch -d automatisch"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: automatisch-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/automatisch/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  automatisch:
    <<: *automatisch
    container_name: automatisch
    environment: *automatisch-env
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8171.
      - "127.0.0.1:8171:3000"

  worker:
    <<: *automatisch
    container_name: automatisch-worker
    environment:
      <<: *automatisch-env
      # The one difference: this copy runs the queue, not the web process.
      WORKER: "true"
EOF
cd /srv/automatisch && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Four services, one published port, and neither the database
nor the queue publishes anything. `${POSTGRES_PASSWORD}` comes from the `.env` step 3 wrote,
which compose reads from the project directory. The image is written once, under an anchor both
app services share.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-automatisch
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Automatisch · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://automatisch.io/docs/guide/installation and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also API_URL in .env, and every webhook address Automatisch hands a third
# party is built from it, so it is the value here you cannot change once
# published flows are running. The app sends its own frame headers, so there is
# no frame directive below.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting an app sends the user out to a third-party
		# consent screen and back, and some providers check the origin.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8171 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8171
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-automatisch, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it alone; there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp is
HTTP/3. 8171 stays closed because it is bound to 127.0.0.1, and 5432 and 6379 stay closed because
compose never publishes them. Assert: `ufw status verbose` prints `Status: active`, shows 80,
443/tcp and 443/udp, and no rule for 8171, 5432 or 6379.

## 7. Start and verify

The main container runs the database migrations on the way up, so the first boot is slow and
Caddy answers `502` through most of it.

```bash
cd /srv/automatisch
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/internal/api/v1/automatisch/version
curl -sS https://<DOMAIN>/internal/api/v1/automatisch/info
docker compose logs --tail 20 worker | grep -c 'Workers are ready'
```

Assert, all four, and print what you received for each. The loop ends on `200`. The version
response contains `"version":"0.15.0"`, the pinned release answering and not something already on
the box. The info response contains `"installationCompleted":false`, which is how a fresh
instance says nobody owns it yet. The worker count is `1`. If any of the four misses, stop,
run `docker compose logs --tail 40 automatisch`, and name the likely cause: a `502` past ten
minutes points at step 4, a database that never reports healthy at step 2, a certificate error at
step 5, a worker that never says it is ready at Redis. A running container is not success.

The first screen is at https://<DOMAIN>/installation, and https://<DOMAIN>/ redirects to it while
the instance has no account. It shows the heading `Installation` over a form asking for a full
name, an email and a password twice, above a button reading `Create admin`.

STOP: tell the user to open https://<DOMAIN>/, fill that form in, and wait.
Do not continue until they confirm. That account is the admin here. Then confirm the door
shut behind them:

```bash
curl -sS https://<DOMAIN>/internal/api/v1/automatisch/info | grep -o '"installationCompleted":true'
```

Assert: that prints `"installationCompleted":true`. The endpoint that creates the first admin
answers `403` from here on, and `DISABLE_SEED_USER` means the default account upstream's
entrypoint would otherwise seed never existed. Both asserts must pass before you report
success.

## 8. First backup and restore

Two artifacts: the database holds the flows, the connections and the run history, and the config
archive holds the files that rebuild the service around them, encryption key included.

```bash
cd /srv/automatisch
docker compose exec -T postgres pg_dump -U automatisch -d automatisch | gzip > /srv/automatisch/backups/automatisch-db-$(date +%F).sql.gz
sudo tar -C /srv/automatisch -czf /srv/automatisch/backups/automatisch-config-$(date +%F).tar.gz compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/automatisch/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. Redis is in neither archive, and the last step of the
restore is what that costs.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/automatisch
scp vps:/srv/automatisch/backups/* ~/backups/automatisch/
```

To restore: `docker compose down`, `sudo rm -rf /srv/automatisch/postgres /srv/automatisch/redis`,
recreate both as in step 2, untar the config archive into /srv/automatisch so `.env` is back
before anything starts, `docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U automatisch -d automatisch`, run that same
psql command again with `-c "UPDATE flows SET active = false;"`, then `docker compose up -d`. That
last statement is the step people miss: the repeating schedule of a published flow lives in Redis,
not PostgreSQL, so a restored database describes flows nothing is scheduled to run. Clearing the
flag lets the user switch each one back on in the browser, which re-registers the schedule. A
database restored without the matching `ENCRYPTION_KEY` comes back with every flow intact and
every credential unreadable, so the two artifacts travel together or neither is worth keeping.

## 9. Updating later

New versions are listed at https://github.com/automatisch/automatisch/releases. Take both backups
first, then edit the image line in /srv/automatisch/compose.yml to the new tag and digest.

```bash
cd /srv/automatisch
docker compose pull
docker compose up -d
docker compose logs --tail 30 automatisch
```

Automatisch migrates its own database on the way up, so watch that log until it settles, then
re-run step 7's first three checks.

## 10. What will probably go wrong

Nothing will happen for fifteen minutes and it will look like the worker is dead. I published my
first flow, watched the executions page stay empty, and restarted the whole stack twice before I
read the code. Without an enterprise licence Automatisch pins every polling trigger to a
fifteen-minute cron, and the interval selector is put back to fifteen when you save it lower. The
first run is up to a quarter of an hour after publishing, every time. Before touching anything,
run `docker compose logs --tail 20 worker` and look for `Workers are ready!`. If that line is
there, the install is fine and the clock is what you are waiting for.

## 11. Out of scope

- Do not configure SMTP. No `SMTP_` variable is set here: the first admin account is made in the
  browser in step 7, and the password-reset screens live in files marked `.ee.`.
- Do not set `ENABLE_BULLMQ_DASHBOARD` or its two credential variables. That publishes the raw
  job queue on the same hostname, and this install has no reason to.
- Do not set `LICENSE_KEY`, and do not enable SAML, roles, templates or the public REST API under
  /api/v1. Those read files marked `.ee.`, which carry a separate commercial licence.
- Do not connect a third-party app yet and do not add any client id or secret to `.env`. Each
  connector needs its own developer registration in that company's portal, done from the Apps
  screen after login.
