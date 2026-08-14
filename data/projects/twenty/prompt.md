You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Twenty 2.30.1 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer. It
becomes `SERVER_URL` in step 3, and its A record must point at this server already.

Say the security model to the user before anything installs. Twenty ships no setup wizard and no
seeded administrator: the first person to open the hostname and finish
the workspace form becomes the administrator, and upstream refuses every signup after that. A
sound default and a race, so step 7 claims the instance and proves the door shut in one sitting.

Twenty needs 4096 MB of RAM available and 20 GB free on /srv. Upstream's floor for the application
alone is 2 GB; this install adds a second Node process, PostgreSQL and Redis beside it. Both
architectures are published.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop: on a
smaller box the kernel kills the server partway through the first migration. If `dig +short`
prints nothing, print that and stop.

## 2. Layout

Three directories, three owners. The application image runs as uid 1000 and cannot write an
attachment directory owned by the login user; the PostgreSQL image chowns its own on first start.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/twenty /srv/twenty/backups
sudo install -d -m 700 /srv/twenty/postgres
sudo install -d -m 750 -o 1000 -g 1000 /srv/twenty/storage
ls -la /srv/twenty
```

Assert: `backups` owned by the login user, `postgres` at mode `700` owned by root, `storage` owned
by `1000`. Those last two hold the whole state, so step 8 archives both.

## 3. Secrets

Three. `ENCRYPTION_KEY` encrypts stored secrets at rest and upstream marks it required for new
installs. `APP_SECRET` is the older name upstream falls back to when the first is unset, and the
token code still throws without it, so both are set. `PG_DATABASE_PASSWORD` is hex because it
rides inside a connection string, where upstream asks for no special characters. Print none of them anywhere.

```bash
umask 077
cat > /srv/twenty/.env <<EOF
SERVER_URL=https://<DOMAIN>
IS_MULTIWORKSPACE_ENABLED=false
APP_SECRET=$(openssl rand -base64 32)
ENCRYPTION_KEY=$(openssl rand -base64 32)
PG_DATABASE_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/twenty/.env
umask 022
ls -l /srv/twenty/.env
```

Assert: mode `-rw-------`, and `SERVER_URL` reads `https://` then the real hostname, no trailing
slash. The first two lines are not secrets. `IS_MULTIWORKSPACE_ENABLED` is upstream's default, written out because step 7 rests on it: signup
closes once a workspace exists only while this is off. Tell the user to read their key with
`sudo grep ENCRYPTION_KEY /srv/twenty/.env` and store it today, because upstream says losing it
loses access to every secret in the database.

## 4. compose.yml

```bash
cat > /srv/twenty/compose.yml <<'EOF'
# Twenty · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation and upstream's own compose file:
#   docker compose ..... https://docs.twenty.com/developers/self-host/capabilities/docker-compose
#   upstream compose ... https://github.com/twentyhq/twenty/blob/064bdd795a0bd78c65f024350cefed2c8f38a661/packages/twenty-docker/docker-compose.yml
#
# Four services, the same four upstream runs: the server, a worker on the same
# image draining the job queue, PostgreSQL and Redis. Upstream writes postgres:16
# and a bare redis; this file pins the patch and digest of each, and that bare
# tag is the 8.10 line below. SERVER_URL and IS_MULTIWORKSPACE_ENABLED arrive
# from .env, so both containers read one value. Digests read from the registries
# on 2026-08-12; the application image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: twenty-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: default
      POSTGRES_USER: twenty
      POSTGRES_PASSWORD: ${PG_DATABASE_PASSWORD}
    volumes:
      - /srv/twenty/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U twenty -d default"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: twenty-redis
    restart: unless-stopped
    # Upstream's own flag: the job queue must not be evicted under pressure.
    command: ["--maxmemory-policy", "noeviction"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  server:
    image: twentycrm/twenty:v2.30.1@sha256:36049a73f0d2e25c059007ccb452cf183b02fd57cb107afee7d959879639fa97
    container_name: twenty-server
    restart: unless-stopped
    env_file: /srv/twenty/.env
    environment:
      NODE_PORT: 3000
      PG_DATABASE_URL: postgres://twenty:${PG_DATABASE_PASSWORD}@db:5432/default
      REDIS_URL: redis://redis:6379
      # Attachments land in the mount below, not in an S3 bucket.
      STORAGE_TYPE: local
    volumes:
      - /srv/twenty/storage:/app/packages/twenty-server/.local-storage
    healthcheck:
      # Upstream's own. Many retries: the entrypoint runs the schema setup and
      # every migration before this port answers anything.
      test: ["CMD", "curl", "--fail", "http://localhost:3000/healthz"]
      interval: 10s
      timeout: 5s
      retries: 30
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8183.
      - "127.0.0.1:8183:3000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  worker:
    image: twentycrm/twenty:v2.30.1@sha256:36049a73f0d2e25c059007ccb452cf183b02fd57cb107afee7d959879639fa97
    container_name: twenty-worker
    restart: unless-stopped
    command: ["yarn", "worker:prod"]
    env_file: /srv/twenty/.env
    environment:
      PG_DATABASE_URL: postgres://twenty:${PG_DATABASE_PASSWORD}@db:5432/default
      REDIS_URL: redis://redis:6379
      STORAGE_TYPE: local
      # Upstream's own values here: the server owns migrations and cron
      # registration, and two processes racing one migration half-apply it.
      DISABLE_DB_MIGRATIONS: "true"
      DISABLE_CRON_JOBS_REGISTRATION: "true"
    volumes:
      - /srv/twenty/storage:/app/packages/twenty-server/.local-storage
    depends_on:
      db:
        condition: service_healthy
      server:
        condition: service_healthy
EOF
cd /srv/twenty && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose reads /srv/twenty/.env from the working directory for
`${PG_DATABASE_PASSWORD}`, which is why every later command changes into it first.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-twenty
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Twenty · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.twenty.com/developers/self-host/capabilities/docker-compose and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# SERVER_URL in .env: upstream says to set the server URL to your public URL,
# because the server uses it for the links it generates and to work out that it
# is being reached over HTTPS, which is what makes its session cookies secure.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Nothing here is meant to be framed by another site.
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8183 is the loopback port compose publishes; it is not open in the firewall.
	reverse_proxy 127.0.0.1:8183
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-twenty, reload, and report what it objected to. Upstream notes the
clipboard copy buttons need a secure context, one more reason the certificate matters.

## 6. Firewall

Two ports open, both Caddy's, and idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3. 8183 is bound to 127.0.0.1, and 5432 and 6379 are never published at all. Assert: `Status: active`, rules for 80, 443/tcp and 443/udp,
and no rule mentioning 8183, 5432, 6379 or 3000.

## 7. Start and verify

The server runs the schema setup and every migration before it answers a request, so a first boot
is minutes, and the worker waits on the server's health check. Use the loop, not a fixed sleep.

```bash
cd /srv/twenty
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthz; echo
curl -sSL https://<DOMAIN>/ | grep -c '<title>Twenty</title>'
curl -sS https://<DOMAIN>/client-config | grep -o '"isMultiWorkspaceEnabled":[a-z]*'
docker compose ps --format '{{.Service}} {{.State}}'
```

Assert all five and print what you received for each: the loop ends on `200`; the health body
contains `"status":"ok"`; the grep prints a number above `0`, the title the served page carries;
the fourth prints `"isMultiWorkspaceEnabled":false`, step 3's setting read back out of the running
server; the last prints four lines, `db`, `redis`, `server` and `worker`, each `running`. Upstream
registers that health check with no dependency indicators, so `200` says the process is alive and
nothing about PostgreSQL.

If any of the five misses, stop, run `docker compose logs --tail 60 server` and
`docker compose logs --tail 20 db`, and name the likely earlier step: a database that never
reports healthy points at step 2, a `server` that keeps restarting is usually memory and points at
step 1, and a 502 with all four up points at step 5. A running container is not success.

The first screen at https://<DOMAIN> is a sign-in card with a `Continue with Email` button, and
the browser tab reads `Twenty`.

STOP: tell the user to open https://<DOMAIN> now, choose `Continue with Email`, create their
account, name the workspace, and keep going until the CRM itself has loaded. Tell them to save
that password in their password manager first, because no mail is configured and the reset link
has nothing to send. Do not continue until they confirm the CRM has loaded.

Once they confirm, prove the door is shut. The signup mutation is served on `/graphql`
beside every other mutation. It asks the public signup mutation for an account nobody owns, with a
five-character password upstream's own rule rejects. Upstream checks whether
signup is allowed before it looks at the password, so a closed instance answers with the refusal,
an open one with a password complaint, and neither creates an account:

```bash
curl -sS -X POST https://<DOMAIN>/graphql -H 'content-type: application/json' --data '{"query":"mutation Probe($e: String!, $p: String!) { signUp(email: $e, password: $p) { __typename } }","variables":{"e":"closure-probe@example.com","p":"probe"}}' -o /srv/twenty/signup-probe.json
cat /srv/twenty/signup-probe.json; echo
grep -c SIGNUP_DISABLED /srv/twenty/signup-probe.json
```

Assert: the body carries `"subCode":"SIGNUP_DISABLED"` with the message
`New workspace setup is disabled`, and the grep prints `1`. If the grep prints `0` and the body
says `Password too weak`, the user stopped before the workspace was created: send them back, then
probe again. Do not report success until it prints `1`. Then `rm /srv/twenty/signup-probe.json`.

## 8. First backup and restore

Two artifacts: the database with every record and account, and a file archive with the
attachments and the three files that rebuild the service.

```bash
cd /srv/twenty
docker compose exec -T db pg_dump -U twenty -d default | gzip > /srv/twenty/backups/twenty-db-$(date +%F).sql.gz
sudo tar -czf /srv/twenty/backups/twenty-files-$(date +%F).tar.gz -C /srv/twenty compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/twenty/backups/
```

Assert: both exist, both are non-empty, and print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Expect a few hundred kilobytes on a fresh
install: the schema is large before anybody has entered anything.

A backup on the same disk as the data is not a backup. Run this one from the user's machine:

```bash
mkdir -p ~/backups/twenty
scp vps:/srv/twenty/backups/* ~/backups/twenty/
```

To restore: `docker compose down`; untar the archive into /srv/twenty with `sudo`, so `storage`
returns owned by 1000 and `.env` is back before anything starts (PostgreSQL takes its password
from it on first initialise); `sudo rm -rf /srv/twenty/postgres`, recreate it as in step 2;
`docker compose up -d db`; wait for healthy; pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db psql -U twenty -d default`; then `docker compose up -d`.
`ENCRYPTION_KEY` in `.env` decrypts the secrets inside those rows.

## 9. Updating later

Release notes are at https://github.com/twentyhq/twenty/releases, where the tag carries a
`twenty/` prefix the image tag does not: release `twenty/v2.30.1` is image tag `v2.30.1`. This install pins 2.30.1 rather
than the newest tag on purpose. Twenty publishes an image every few days, `v2.31.1` landed hours
before this file was written, and 2.30.1 is the newest tag with a day in the wild behind it. Back
up first, then edit both image lines in /srv/twenty/compose.yml: server and worker run one build
against one database.

```bash
cd /srv/twenty
docker compose pull
docker compose up -d
docker compose logs --tail 40 server
```

Watch that log until it settles, then re-run step 7's health check and the signup probe: a
migration that stopped halfway leaves a service answering `ok` on health and failing on the first
record opened.

## 10. What will probably go wrong

The first boot looks like a hang. I watched `docker compose ps` report `server` as
`starting` for four minutes, got a 502 the whole time, and went hunting through the reverse
proxy for a fault that was not there. The container runs the schema setup and
every migration before it opens the port, and the worker sits idle on the server's health check
while that happens, so a stack that looks half dead is doing what it should. Watch
`docker compose logs -f server` rather than the browser, and suspect step 5 only once that log has
settled and the page is still 502.

## 11. Out of scope

- Do not configure SMTP and do not set `EMAIL_DRIVER`. Mail is off, so invitations and password
  resets have nothing to send, which is why step 7 has the user save that password.
- Do not set `IS_MULTIWORKSPACE_ENABLED` to true. It reopens signup to every visitor and moves
  the application onto per-workspace subdomains wanting a wildcard DNS record.
- Do not configure Google or Microsoft authentication, calendar sync or messaging sync. Each is an
  OAuth client registered in somebody else's console with its own callback URLs.
- Do not set `LOGIC_FUNCTION_TYPE` or `CODE_INTERPRETER_TYPE` to `LOCAL`, and do not point
  `STORAGE_TYPE` at an S3 bucket. The local driver runs submitted code on the host with no sandbox.
