You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Chatwoot 4.16.2, community edition, on that server, reachable at https://<DOMAIN>,
behind the existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say this when you ask: `<DOMAIN>` becomes `FRONTEND_URL`, baked into the chat widget snippet they
paste on their site and into every link Chatwoot sends. Its A record must point at this server.

Chatwoot needs 4096 MB of RAM available and 20 GB free on /srv. Upstream states 4 GB as the
minimum and sizes that at up to 10,000 conversations a day. All three images publish amd64 and
arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop. Rails
and Sidekiq each hold the whole application in memory, and the OOM killer arrives mid-migration.
If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/chatwoot /srv/chatwoot/backups /srv/chatwoot/storage /srv/chatwoot/redis
sudo install -d -m 700 /srv/chatwoot/postgres
ls -la /srv/chatwoot
```

Assert: `ls -la` shows `backups`, `storage` and `redis` owned by the login user, and `postgres`
at mode `700` owned by root. The PostgreSQL image chowns its own data directory on first start,
so that one is left alone. `storage` is where customer attachments land.

## 3. Secrets

Three secrets: the Rails key that signs cookies and sessions, the PostgreSQL password and the
Redis password. Generate all three on the server. Do not print any of them, do not repeat them
in your summary, and do not put them in any log line. Hex rather than base64, because upstream
asks for an alphanumeric value on the first and the others ride inside connection strings.

```bash
umask 077
cat > /srv/chatwoot/.env <<EOF
FRONTEND_URL=https://<DOMAIN>
SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/chatwoot/.env
umask 022
ls -l /srv/chatwoot/.env
```

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the
real hostname before writing it. Tell the user where the file is and that no human logs in with
any of these values. The Rails key is the one that matters for restores, because sessions signed
with a different key are rejected, which is why step 8 archives `.env`.

## 4. compose.yml

```bash
cat > /srv/chatwoot/compose.yml <<'EOF'
# Chatwoot · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker deployment .. https://developers.chatwoot.com/self-hosted/deployment/docker
#   variable reference . https://developers.chatwoot.com/self-hosted/configuration/environment-variables
#   requirements ....... https://developers.chatwoot.com/self-hosted/deployment/requirements
#
# Four services: the Rails web process, the Sidekiq worker every background job
# runs on, PostgreSQL and Redis. The database image is pgvector's, because
# Chatwoot's schema turns on the `vector` extension and a plain postgres refuses
# the schema load. The -ce tag is the community edition, built with the
# enterprise/ directory deleted, which is the tree the MIT licence covers.
# Digests read on 2026-08-06; all three images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# Rails and Sidekiq share an image and an environment; compose ignores x- keys.
x-chatwoot: &chatwoot
  image: chatwoot/chatwoot:v4.16.2-ce@sha256:7ee85a208147a86188ffc0e7fafafd2e1c0403b4ad6aea9e31f566662cce1d2f
  restart: unless-stopped
  env_file: /srv/chatwoot/.env
  environment:
    RAILS_ENV: production
    NODE_ENV: production
    INSTALLATION_ENV: docker
    POSTGRES_HOST: postgres
    POSTGRES_USERNAME: chatwoot
    POSTGRES_DATABASE: chatwoot_production
    REDIS_URL: redis://redis:6379
    # Signup stays shut: one account, made once through the onboarding screen.
    ENABLE_ACCOUNT_SIGNUP: "false"
    ACTIVE_STORAGE_SERVICE: local
  volumes:
    - /srv/chatwoot/storage:/app/storage
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg16@sha256:a36250871de0833b8757561c72f2477ef1ddd1101afa4e617fb552e0de514c6b
    container_name: chatwoot-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: chatwoot_production
      POSTGRES_USER: chatwoot
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/chatwoot/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chatwoot -d chatwoot_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: chatwoot-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    # Doubled dollar: compose leaves it, the container's own shell expands it.
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass $$REDIS_PASSWORD"]
    volumes:
      - /srv/chatwoot/redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli --no-auth-warning -a $$REDIS_PASSWORD ping | grep -q PONG"]
      interval: 10s
      retries: 12

  rails:
    <<: *chatwoot
    container_name: chatwoot-rails
    entrypoint: docker/entrypoints/rails.sh
    command: ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8102.
      - "127.0.0.1:8102:3000"

  sidekiq:
    <<: *chatwoot
    container_name: chatwoot-sidekiq
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
EOF
cd /srv/chatwoot && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Sidekiq is not scenery: every outgoing message, webhook and
notification is a background job, so a Chatwoot with no worker is a dashboard whose replies
never leave.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-chatwoot
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Chatwoot · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://developers.chatwoot.com/self-hosted/deployment/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also FRONTEND_URL in .env, so changing it later means editing .env too.

<DOMAIN> {
	# The dashboard holds customer conversations, so nothing here should be
	# framed, sniffed or leaked in a referrer.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8102 is the loopback port compose publishes on this host, not a container
	# port and not open in the firewall. Caddy upgrades the /cable websocket on
	# this same route and sets X-Forwarded-Proto, which is what lets Rails
	# accept that websocket as same-origin rather than rejecting it.
	reverse_proxy 127.0.0.1:8102
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-chatwoot, reload, and report what it objected to. Caddy requests the
certificate on first request and renews it itself, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box nothing changes:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8102 stays closed because compose binds it to 127.0.0.1, and 5432 and 6379 stay closed
because compose publishes no host port for them at all, unlike the upstream example file. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for
8102, 5432 or 6379.

## 7. Start and verify

Prepare the database once, before anything serves traffic. Upstream documents
`rails db:chatwoot_prepare` as the task that loads the schema on an empty database and migrates
an existing one; it also seeds the flag that unlocks the one-time onboarding screen.

```bash
cd /srv/chatwoot
docker compose pull
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/api
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/v1/accounts
curl -sS https://<DOMAIN>/installation/onboarding | grep -o 'Howdy, Welcome to Chatwoot'
```

Assert all five, printing what you received for each. The loop ends on `200`. The health
response is exactly `{"status":"woot"}`. The `/api` response contains `"queue_services":"ok"` and
`"data_services":"ok"`, Chatwoot reporting that it reached Redis and PostgreSQL itself rather
than you inferring it from container states. The unauthenticated POST prints `404`, because
signup is off, and that is the security assert here. The last command prints
`Howdy, Welcome to Chatwoot`. If any of the five misses, stop, run
`docker compose logs --tail 40 rails`, and name the likely cause:
`"data_services":"failing"` points at step 3 and a `.env` missing its password lines, and a `502`
where `200` was expected usually means Rails is still booting. A running container is not
success.

The first screen at https://<DOMAIN> shows the heading `Howdy, Welcome to Chatwoot`, a waving
emoji after it, above a form asking for a name, a company, a work email and a password.

STOP: tell the user to open https://<DOMAIN> and create their administrator account on that
screen, and wait. Do not continue until they confirm. That form runs once. Tell them to put the
password in their password manager as they type it: this install configures no mail, so there is
no reset email to fall back on.

Once they confirm, prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/installation/onboarding
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert: the first prints `302`, the onboarding screen now refusing, and the second prints `200`.
Both must pass before you report success.

## 8. First backup and restore

Two artifacts. The database holds every conversation, contact and agent; the config archive
holds the files and attachments that rebuild the service around them.

```bash
cd /srv/chatwoot
docker compose exec -T postgres pg_dump -U chatwoot -d chatwoot_production | gzip > /srv/chatwoot/backups/chatwoot-db-$(date +%F).sql.gz
sudo tar -czf /srv/chatwoot/backups/chatwoot-config-$(date +%F).tar.gz -C /srv/chatwoot compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/chatwoot/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Redis is in neither archive on purpose: it
holds the job queue and the caches, not durable data.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/chatwoot
scp vps:/srv/chatwoot/backups/* ~/backups/chatwoot/
```

To restore: `docker compose down`, `sudo rm -rf /srv/chatwoot/postgres`, recreate it as in step
2, untar the config archive into /srv/chatwoot so `.env` is back before anything starts,
`docker compose up -d postgres`, wait for it to report healthy, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T postgres psql -U chatwoot -d chatwoot_production`, then
`docker compose up -d`. Tell the user the `.env` in that archive is not paperwork: a database
restored without it comes back with every session cookie failing to verify.

## 9. Updating later

New versions are listed at https://github.com/chatwoot/chatwoot/releases. Keep the `-ce` suffix.
Take both backup artifacts first, then edit the application image line in
/srv/chatwoot/compose.yml to the new tag and its digest:

```bash
cd /srv/chatwoot
docker compose pull
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d
docker compose logs --tail 30 rails
```

The prepare task is not optional here: upstream documents re-running it so the new image
migrates the database it inherited. Then re-run step 7's health checks.

## 10. What will probably go wrong

The wait. On a 4 GB box the prepare task in step 7 spent several minutes loading a schema with no
output at all, and then `docker compose up -d` returned instantly while Caddy answered `502` for
another two minutes because Rails was still eager-loading. I restarted the whole stack during
that window, convinced it had hung, and all that did was start the two minutes again. The loop
waits ten minutes on purpose. Let it run, and watch `docker compose logs -f rails` if you need
something to look at rather than something to press.

## 11. Out of scope

- Do not configure SMTP. Live chat works without it, and this install trades agent-invite and
  password-reset email for not fighting port 25 on a fresh VPS.
- Do not add a Facebook, Instagram, WhatsApp or email channel. Each is an app registration at
  somebody else's console, and none is needed for the widget.
- Do not set `ENABLE_ACCOUNT_SIGNUP` to true. Step 7 asserts that endpoint answers 404, and an
  open signup on a support desk is an open door to the conversation history.
- Do not switch `ACTIVE_STORAGE_SERVICE` to S3. Attachments belong on the disk step 8 archives,
  not in a bucket the backup cannot see.
