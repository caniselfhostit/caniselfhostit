You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Formbricks 5.3.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for it once and stop until they answer. Say why: it
becomes `WEBAPP_URL`, the front of every survey link they send, so a link already in somebody's
inbox dies if they change it. Its A record must point at this server now.

Formbricks 5 needs 4096 MB of RAM available and 20 GB free on /srv. That floor is upstream's own
Helm limits added up: 2 GB web, 1 GB Cube, 512 MB Hub, 192 MB Valkey, plus PostgreSQL. Both
architectures are published.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk under 20 GB, print both and stop. If `dig +short`
prints nothing, print that and stop. Do not install and hope.

## 2. Layout

Cube reads two files upstream ships in their repository, not in their image. Fetch both at the
pinned tag and verify them before they are mounted.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/formbricks /srv/formbricks/backups /srv/formbricks/cube /srv/formbricks/cube/schema
sudo install -d -m 700 /srv/formbricks/postgres /srv/formbricks/redis
cd /srv/formbricks/cube
for f in cube.js schema/FeedbackRecords.js; do curl -fsSL -o "$f" "https://raw.githubusercontent.com/formbricks/formbricks/5.3.0/docker/cube/$f"; done
cat > SHA256SUMS <<'EOF'
723eea0f581200a686f854ff47b38f2e92bbfe5d802338049afaa061f154a335  cube.js
c3322a3739ee1cc57224139f502395a20dcbe4dd71e331be41d687ffdfe140f8  schema/FeedbackRecords.js
EOF
sha256sum -c SHA256SUMS
ls -la /srv/formbricks
```

Assert: `sha256sum -c` prints two lines ending `OK`; print both. On `FAILED`, stop: those are
not the bytes recorded on 2026-08-06. `ls -la` shows `backups` and `cube` owned by the login
user, `postgres` and `redis` at mode `700` owned by root. Leave those two: both images chown
their own data directory on first start.

## 3. Secrets

Six: the PostgreSQL password and five keys the app requires. Generate all six here, print none
of them, and keep them out of your summary and out of every log line. Hex, because upstream caps
three at 32 bytes.

```bash
umask 077
cat > /srv/formbricks/.env <<EOF
WEBAPP_URL=https://<DOMAIN>
NEXTAUTH_URL=https://<DOMAIN>
DB_PASSWORD=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
CRON_SECRET=$(openssl rand -hex 32)
HUB_API_KEY=$(openssl rand -hex 32)
CUBEJS_API_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/formbricks/.env
umask 022
ls -l /srv/formbricks/.env
```

Assert: mode `-rw-------`. `ENCRYPTION_KEY` matters most: upstream uses it for two-factor
secrets, single-use survey links and audit-log hashing, so a database restored without it is
unreadable. Step 8 gets a copy off the box.

## 4. compose.yml

```bash
cat > /srv/formbricks/compose.yml <<'EOF'
# Formbricks · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose setup ....... https://formbricks.com/docs/self-hosting/setup/docker
#   variable reference .. https://formbricks.com/docs/self-hosting/configuration/environment-variables
#
# Seven services: five that stay up, two migration jobs that run in order and
# exit. Upstream makes Hub, Cube and Valkey mandatory in version 5. Only 8110
# is published, on loopback. Digests read 2026-08-06, all five multi-arch.
#
# Three deliberate trims from upstream's compose: no validate-env prefix on
# the migrate job (the web container runs it at startup), no direct postgres
# depends_on for hub and cube (the migration chain already gates them), and
# no saml-connection mount (paid edition, out of scope).
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: formbricks

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg18@sha256:691673308c99d2161ba298736f3147f1f22d79de2fb7ec93ae9b4afcab870b62
    restart: unless-stopped
    environment:
      POSTGRES_DB: formbricks
      POSTGRES_USER: formbricks
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/formbricks/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U formbricks -d formbricks"]
      interval: 10s
      retries: 30

  redis:
    image: valkey/valkey:9.0.5-alpine@sha256:0cb61366757e2bcd26500b4e8bb63cbd7117610e3e4f05aacb3c812511da7632
    restart: unless-stopped
    command: ["valkey-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - /srv/formbricks/redis:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 30

  formbricks-migrate:
    image: ghcr.io/formbricks/formbricks:5.3.0@sha256:d79dba3668a359b63d984ac39b19a58fb6746b3aed57fd890b9f2f6f372210e6
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?schema=public
    command: ["node", "packages/database/dist/scripts/apply-migrations.js"]
    depends_on:
      postgres:
        condition: service_healthy

  hub-migrate:
    image: ghcr.io/formbricks/hub:0.8.3@sha256:4dc0c4f26cf999b3bf4a26d7b09634fc65ae23cbb30c9ad82042da019d231458
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?sslmode=disable
    entrypoint: ["sh", "-c"]
    command: ['/usr/local/bin/goose -dir /app/migrations postgres "$$DATABASE_URL" up && /usr/local/bin/river migrate-up --database-url "$$DATABASE_URL"']
    depends_on:
      formbricks-migrate:
        condition: service_completed_successfully

  hub:
    image: ghcr.io/formbricks/hub:0.8.3@sha256:4dc0c4f26cf999b3bf4a26d7b09634fc65ae23cbb30c9ad82042da019d231458
    restart: unless-stopped
    environment:
      API_KEY: ${HUB_API_KEY}
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?sslmode=disable
    depends_on:
      hub-migrate:
        condition: service_completed_successfully

  cube:
    image: cubejs/cube:v1.6.6@sha256:746a381c5deb1f33500c84bed357ebe68aa08acc5030939f9e9efd35796d368c
    restart: unless-stopped
    environment:
      CUBEJS_DB_TYPE: postgres
      CUBEJS_DB_HOST: postgres
      CUBEJS_DB_NAME: formbricks
      CUBEJS_DB_USER: formbricks
      CUBEJS_DB_PASS: ${DB_PASSWORD}
      CUBEJS_API_SECRET: ${CUBEJS_API_SECRET}
      CUBEJS_JWT_ISSUER: formbricks-web
      CUBEJS_JWT_AUDIENCE: formbricks-cube
      CUBEJS_DEFAULT_API_SCOPES: meta,data
      CUBEJS_EXTERNAL_DEFAULT: "false"
      CUBEJS_CACHE_AND_QUEUE_DRIVER: memory
    volumes:
      - /srv/formbricks/cube/cube.js:/cube/conf/cube.js:ro
      - /srv/formbricks/cube/schema:/cube/conf/model:ro
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:4000/readyz', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: 10s
      retries: 18
      start_period: 40s
    depends_on:
      hub-migrate:
        condition: service_completed_successfully

  formbricks:
    image: ghcr.io/formbricks/formbricks:5.3.0@sha256:d79dba3668a359b63d984ac39b19a58fb6746b3aed57fd890b9f2f6f372210e6
    restart: unless-stopped
    env_file: /srv/formbricks/.env
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?schema=public
      REDIS_URL: redis://redis:6379
      HUB_API_URL: http://hub:8080
      CUBEJS_API_URL: http://cube:4000
      EMAIL_VERIFICATION_DISABLED: "1"
      PASSWORD_RESET_DISABLED: ${PASSWORD_RESET_DISABLED:-1}
      SKIP_STARTUP_MIGRATION: "true"
    ports:
      - "127.0.0.1:8110:3000"
    depends_on:
      formbricks-migrate:
        condition: service_completed_successfully
      redis:
        condition: service_healthy
      cube:
        condition: service_healthy
      hub:
        condition: service_started
EOF
cd /srv/formbricks && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Nothing here is optional: Hub and Cube joined the baseline stack at
version 5, and the app will not start without a Redis URL.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy first: a syntax
error here takes down every other site.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-formbricks
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Formbricks · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://formbricks.com/docs/self-hosting/configuration/domain-configuration
# and https://caddyserver.com/docs/automatic-https

<DOMAIN> {
	# No X-Frame-Options and no frame-ancestors on purpose: link surveys are
	# meant to be embedded in other people's pages.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8110 is the loopback port compose publishes. Not open in the firewall.
	reverse_proxy 127.0.0.1:8110
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. On failure restore /etc/caddy/Caddyfile.before-formbricks, reload, and
report what it said. Caddy gets the certificate on the first request and renews it
itself, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the way in, 443/udp is HTTP/3. 8110
stays closed because it binds to 127.0.0.1; 5432, 6379, 8080 and 4000 because compose publishes
none. Assert: `Status: active`, rules for 80, 443/tcp and 443/udp, none for those five.

## 7. Start and verify

The migration jobs run and exit first, then Cube must be healthy before the web container
starts. On a cold pull this takes minutes.

```bash
cd /srv/formbricks
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -c 'Welcome to Formbricks'
docker compose ps -a
```

Assert all five, printing what you got: the loop ends on `200`; health returns `{"status":"ok"}`;
the redirect lands on `https://<DOMAIN>/setup/intro`; the grep prints at least `1`: that screen
carries the heading `Welcome to Formbricks!` above a `Get started` button; `ps -a` shows
both migration containers `exited (0)` and the other five up. If any misses, stop, run
`docker compose logs --tail 40 formbricks cube hub-migrate`, and name the step to blame:
hub-migrate exiting non-zero is step 3 and an empty `DB_PASSWORD`, cube stuck unhealthy is
step 2 and a failed checksum. A running container is not success.

STOP: tell the user to open https://<DOMAIN>, click `Get started`, create their administrator
account and organization, and wait. Do not continue until they confirm. It is the only moment
that account can be made: signup stays closed afterwards and only an owner or admin can invite
anyone. No SMTP means no reset mail, so have them save the password in a manager first.

Then prove the door shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup/intro
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/
```

Assert: `404`, then `https://<DOMAIN>/auth/login`. The wizard answers only while the user table
is empty. Both must pass before you report success.

## 8. First backup and restore

Two artifacts: the database holds every survey, response and account; the config archive holds
what rebuilds the service around them, `ENCRYPTION_KEY` included.

```bash
cd /srv/formbricks
docker compose exec -T postgres pg_dump -U formbricks -d formbricks | gzip > /srv/formbricks/backups/formbricks-db-$(date +%F).sql.gz
sudo tar -czf /srv/formbricks/backups/formbricks-config-$(date +%F).tar.gz -C /srv/formbricks compose.yml .env cube -C /etc/caddy Caddyfile
ls -lh /srv/formbricks/backups/
```

Assert: both exist, both non-empty, print both sizes. Nothing stops, because `pg_dump`
snapshots a running database consistently. Valkey is not backed up: cache and jobs, not data. A
backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/formbricks
scp vps:/srv/formbricks/backups/* ~/backups/formbricks/
```

To restore: `docker compose down`, `sudo rm -rf /srv/formbricks/postgres`, recreate it as in
step 2, untar the config archive there so .env is back first, `docker compose up -d postgres`,
wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U formbricks -d formbricks`, then `docker compose up -d`.
Say the stakes: a dump without that `.env` is rows nobody can decrypt, so they travel together.

## 9. Updating later

Releases are at https://github.com/formbricks/formbricks/releases; the Hub and Cube versions
that pair with each are in `charts/formbricks/values.yaml` in that tag. Back up first, then edit
the image lines in compose.yml:

```bash
cd /srv/formbricks
docker compose pull
docker compose up -d
docker compose logs --tail 40 formbricks-migrate hub-migrate formbricks
```

Both migration jobs rerun on every start, so watch them exit 0, then re-run step 7's check.

## 10. What will probably go wrong

The wait. I brought this up on a 4 GB box, saw two containers in `Created` and one `starting`,
and went looking for what I had broken. Nothing was: the app is gated on Cube being healthy,
Cube has a 40 second start period before its first check counts, and is gated on both migration
jobs finishing. That chain ran past six minutes before /health answered. Let the loop in step 7
run all forty times before deciding it is broken.

## 11. Out of scope

- Do not configure SMTP. `EMAIL_VERIFICATION_DISABLED` and `PASSWORD_RESET_DISABLED` are 1,
  upstream's default, and the survey loop needs no mail.
- Do not configure S3 or the bundled RustFS storage. That is a second subdomain and another
  service; without it the file-upload and image questions stay off.
- Do not enable the `qwen` or `taxonomy` profiles, set `ENTERPRISE_LICENSE_KEY`, or configure
  SSO, SAML or OIDC. The AI profiles are opt-in and one wants an NVIDIA GPU; the rest is the
  paid edition, and this is the community one.
