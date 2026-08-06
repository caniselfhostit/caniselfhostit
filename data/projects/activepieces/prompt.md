You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Activepieces 0.86.3-hotfix.1 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say this when you ask: `<DOMAIN>` becomes `AP_FRONTEND_URL`, and every webhook URL this
instance hands out is built from it, so moving it later breaks flows already running. Its A
record must already point at this server.

Activepieces needs 4096 MB of RAM available and 20 GB free on /srv. All three images publish
amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope. Upstream sizes a combined API-and-worker container at roughly 1 GB per
concurrent flow on top of a 2 GB API tier. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/activepieces /srv/activepieces/backups /srv/activepieces/cache
sudo install -d -m 700 /srv/activepieces/postgres /srv/activepieces/redis
ls -la /srv/activepieces
```

Assert: `ls -la` shows `backups` and `cache` owned by the login user, and `postgres` and
`redis` at mode `700` owned by root. Leave those two alone: both images chown their own data
directory at first start, and one already chowned to yourself makes PostgreSQL refuse to
initialise. `cache` holds downloaded piece packages, which is a cache and not user data.

## 3. Secrets

Three secrets: the encryption key that protects stored connection credentials, the JWT signing
secret, and the PostgreSQL password. Generate all three on the server. Do not print any of
them, do not repeat them in your summary, and do not put them in a log line. Upstream documents
the encryption key as 32 hexadecimal characters, which is `-hex 16`; that length is not
optional.

```bash
umask 077
cat > /srv/activepieces/.env <<EOF
AP_FRONTEND_URL=https://<DOMAIN>
AP_ENCRYPTION_KEY=$(openssl rand -hex 16)
AP_JWT_SECRET=$(openssl rand -hex 32)
AP_POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/activepieces/.env
umask 022
ls -l /srv/activepieces/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user what the encryption key is for:
every credential they hand a piece is encrypted with it and unreadable without it. It belongs
in their password manager tonight, read with
`sudo grep AP_ENCRYPTION_KEY /srv/activepieces/.env`.

## 4. compose.yml

```bash
cat > /srv/activepieces/compose.yml <<'EOF'
# Activepieces · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose install ..... https://www.activepieces.com/docs/install/options/docker-compose
#   variable reference .. https://www.activepieces.com/docs/install/reference/environment-variables
#   sizing and sandbox .. https://www.activepieces.com/docs/install/configure-operate/production-setup
#
# Three services: Activepieces, the PostgreSQL that holds the flows and the run
# history, and the Redis that holds the job queue. Upstream's own compose file
# splits the API and five worker replicas apart; this one does not, because
# AP_CONTAINER_TYPE defaults to WORKER_AND_APP and one image runs both roles.
# PostgreSQL is the pgvector image because the knowledge base asks the database
# for that extension at every boot and drops the feature when it is absent.
# Upstream's compose pins pgvector 0.8.0-pg14; this file runs the pg16 line,
# the major upstream's own CI runs its Postgres suite against.
#
# Neither the database nor the queue declares `ports:`, and 8095 binds to
# loopback, so the host's Caddy is the only thing that reaches this stack.
# AP_EXECUTION_MODE is upstream's choice for a single-tenant install and the
# image default: flow code runs with this container's own reach.
# AP_WORKER_CONCURRENCY is 2, roughly 1 GB per concurrent flow on top of the API
# tier, and the queue dashboard stays off because it stops the boot when it is on
# with no credentials set. Digests read 2026-08-05; all three images publish
# amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg16@sha256:a36250871de0833b8757561c72f2477ef1ddd1101afa4e617fb552e0de514c6b
    container_name: activepieces-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: activepieces
      POSTGRES_USER: activepieces
      POSTGRES_PASSWORD: ${AP_POSTGRES_PASSWORD}
    volumes:
      - /srv/activepieces/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U activepieces -d activepieces"]
      interval: 10s
      retries: 12

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: activepieces-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/activepieces/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  activepieces:
    image: ghcr.io/activepieces/activepieces:0.86.3-hotfix.1@sha256:4da6910cf46dbc38857c8c4fac6ba867ab804b8a3a8551d672d4490cb1245566
    container_name: activepieces
    restart: unless-stopped
    env_file: /srv/activepieces/.env
    environment:
      AP_ENVIRONMENT: prod
      AP_CONTAINER_TYPE: WORKER_AND_APP
      AP_DB_TYPE: POSTGRES
      AP_POSTGRES_HOST: postgres
      AP_POSTGRES_PORT: "5432"
      AP_POSTGRES_DATABASE: activepieces
      AP_POSTGRES_USERNAME: activepieces
      AP_REDIS_TYPE: STANDALONE
      AP_REDIS_HOST: redis
      AP_REDIS_PORT: "6379"
      AP_EXECUTION_MODE: UNSANDBOXED
      AP_WORKER_CONCURRENCY: "2"
      AP_QUEUE_UI_ENABLED: "false"
      AP_TELEMETRY_ENABLED: "false"
    volumes:
      - /srv/activepieces/cache:/usr/src/app/cache
    ports:
      - "127.0.0.1:8095:80"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/activepieces && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port, and neither the database
nor the queue publishes anything. `${AP_POSTGRES_PASSWORD}` comes from the `.env` step 3 wrote,
which compose reads from the project directory.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-activepieces
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Activepieces · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.activepieces.com/docs/install/configure-operate/setup-ssl and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# AP_FRONTEND_URL in .env, and every webhook URL this instance hands out is built
# from it, so it is the value here you cannot change once flows are running.

<DOMAIN> {
	# The flow editor holds a websocket open for live run output. Upstream's proxy
	# example passes the upgrade headers by hand; Caddy does it without being told.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting a piece sends the user out to a third-party
		# OAuth consent screen and back, and some providers check the origin.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8095 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8095
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-activepieces, reload, and report what it objected to. Caddy
requests the certificate on the first request and renews it on its own, so there is nothing to
schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3. 8095 stays closed because it is bound to 127.0.0.1, and 5432 and 6379 stay closed
because compose never publishes them at all. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8095, 5432 or 6379.

## 7. Start and verify

Activepieces runs its own migrations on the way up, then syncs the piece catalogue metadata, so
the first boot is slow. The image's health check waits 60 seconds before it asks.

```bash
cd /srv/activepieces
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/health
curl -sS https://<DOMAIN>/api/v1/flags | grep -o '"USER_CREATED":[a-z]*' || echo "USER_CREATED absent"
```

Assert, all three, and print what you received for each. The loop ends on `200`. The health
response is exactly `{"status":"Healthy"}`. The flags call prints `USER_CREATED absent`, which
is how a fresh instance says nobody has registered yet. If any of the three misses, stop, run
`docker compose logs --tail 40 activepieces` and `docker compose logs --tail 20 postgres`, and
name the likely cause: a `502` past ten minutes points at step 4, a database that never reports
healthy points at step 2, a certificate error at step 5. A running container is not success.

The first screen is at https://<DOMAIN>/sign-up and shows the heading `Create a new account`
over a form asking for a first name, a last name, an email and a password.

STOP: tell the user to open https://<DOMAIN>/sign-up, create the first account, and wait. Do
not continue until they confirm. That account owns the instance. Then confirm registration has
closed behind them:

```bash
curl -sS https://<DOMAIN>/api/v1/flags | grep -o '"USER_CREATED":true'
```

Assert: that prints `"USER_CREATED":true`. From here a second sign-up is answered against the
platform the first account created, and that path requires an invitation unless
`AP_ALLOW_OPEN_SIGN_UP` is set, which this install never sets. Both asserts must pass.

## 8. First backup and restore

Two artifacts. The database holds the flows, the connections and the run history. The config
archive holds the files that rebuild the service around them, encryption key included.

```bash
cd /srv/activepieces
docker compose exec -T postgres pg_dump -U activepieces -d activepieces | gzip > /srv/activepieces/backups/activepieces-db-$(date +%F).sql.gz
sudo tar -C /srv/activepieces -czf /srv/activepieces/backups/activepieces-config-$(date +%F).tar.gz compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/activepieces/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently. Redis is not backed up and does not need
to be: it carries jobs in flight, not the record of what the flows are.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/activepieces
scp vps:/srv/activepieces/backups/* ~/backups/activepieces/
```

To restore: `docker compose down`, `sudo rm -rf /srv/activepieces/postgres`, recreate it as in
step 2, untar the config archive into /srv/activepieces so `.env` is back before anything
starts, `docker compose up -d postgres`, wait for it to report healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U activepieces -d activepieces`, then
`docker compose up -d`. Tell the user the stake: a database restored without the matching
`AP_ENCRYPTION_KEY` comes back with every flow intact and every credential unreadable, so the
two artifacts travel together or neither is worth keeping.

## 9. Updating later

New versions are listed at https://github.com/activepieces/activepieces/releases. Take both
backups first, then edit the image line in /srv/activepieces/compose.yml to the new tag and
digest:

```bash
cd /srv/activepieces
docker compose pull
docker compose up -d
docker compose logs --tail 30 activepieces
```

Activepieces migrates its own database on the way up, so watch that log until it settles, then
re-run step 7's health check before calling the update done.

## 10. What will probably go wrong

The first boot looks like a failed install for several minutes. I watched Caddy answer `502`
over and over while the container ran migrations and pulled the piece catalogue metadata, and
the pull to start editing the compose file was strong. Nothing was wrong. The image's health
check does not begin probing for 60 seconds, and step 7's loop waits ten minutes for a reason.
Before touching anything, run `docker compose logs --tail 40 activepieces`: a log still moving
is an install still working.

## 11. Out of scope

- Do not configure SMTP. No `AP_SMTP_` variable is set here, and the community edition verifies
  the first account itself rather than mailing a link.
- Do not set `AP_GOOGLE_CLIENT_ID`, `AP_GOOGLE_CLIENT_SECRET` or any SSO variable. First login
  is an email address and a password, and single sign-on is a paid-edition feature.
- Do not split the worker into its own container, raise `AP_WORKER_CONCURRENCY`, or configure
  S3 storage. Those are the production shape for a fleet, and this is one machine.
- Do not set `AP_NETWORK_MODE=STRICT` or change `AP_EXECUTION_MODE`. Upstream states that the
  strict guard is best-effort inside the process, not a boundary against hostile code.
