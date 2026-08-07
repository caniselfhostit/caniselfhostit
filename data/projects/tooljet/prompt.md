You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install ToolJet v3.20.208-lts on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and it becomes `TOOLJET_HOST`, the value the
server compares request origins against.

ToolJet needs 4096 MB of RAM available and 20 GB free on /srv. Upstream sizes the application
machine at 4 GB and the database machine at 8 GB, and this puts both on one box, so 4096 MB is
where it starts rather than where it is comfortable. The image is published for amd64 only.
Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope. If the architecture is anything but `amd64`, print it and stop: there is no
arm64 image and an arm64 VPS has no emulation to fall back on. If `dig +short` prints nothing,
print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/tooljet /srv/tooljet/backups
sudo install -d -m 700 /srv/tooljet/postgres
ls -la /srv/tooljet
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root. Leave that one alone: the PostgreSQL image chowns its own data directory on first start and
refuses one already chowned. Nothing here is ToolJet's own: its apps, queries and datasource
credentials are rows in that database.

## 3. Secrets

Four secrets: the lockbox master key, the application secret key, the PostgreSQL password and the
PostgREST JWT secret. Generate all four on the server. Do not print any of them, do not repeat
them in your summary, and do not put them in any log line. Hex throughout, at the lengths
upstream documents for each.

```bash
umask 077
cat > /srv/tooljet/.env <<EOF
TOOLJET_HOST=https://<DOMAIN>
LOCKBOX_MASTER_KEY=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 64)
PG_PASS=$(openssl rand -hex 32)
PGRST_JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/tooljet/.env
umask 022
ls -l /srv/tooljet/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user `LOCKBOX_MASTER_KEY` is the one to
copy into their password manager tonight, readable with
`sudo grep LOCKBOX_MASTER_KEY /srv/tooljet/.env`. It encrypts every database password, API key and
token they later hand to a datasource, so a database restored without it comes back with every app
intact and nothing able to connect.

## 4. compose.yml

```bash
cat > /srv/tooljet/compose.yml <<'EOF'
# ToolJet · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker deployment .. https://docs.tooljet.ai/docs/setup/docker/
#   variable reference . https://docs.tooljet.ai/docs/setup/env-vars/
#   sizing ............. https://docs.tooljet.ai/docs/setup/system-requirements/
#   tooljet database ... https://docs.tooljet.ai/docs/tooljet-db/tooljet-database/
#
# Upstream's in-built-PostgreSQL deployment in our layout: the ToolJet server,
# one PostgreSQL holding the three databases it makes for itself, and the
# PostgREST the ToolJet Database is read through. No Redis service: the -ce
# image starts one in its own container. -ce is the community edition, the tree
# AGPL-3.0 covers; the paid half sits in two private git submodules. Digests
# read 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: tooljet-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: tooljet_production
      POSTGRES_USER: tooljet
      POSTGRES_PASSWORD: ${PG_PASS}
    volumes:
      - /srv/tooljet/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U tooljet -d tooljet_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  tooljet:
    image: tooljet/tooljet-ce:v3.20.208-lts@sha256:78cb01a47c2a0f5efde54ebf2ff3d4c704c1523e1a6b497df65697028701f3c9
    container_name: tooljet
    restart: unless-stopped
    # amd64 only, named rather than guessed. PORT is 3000, not 80, because
    # this image runs as a non-root user.
    platform: linux/amd64
    env_file: /srv/tooljet/.env
    command: ["npm", "run", "start:prod"]
    environment:
      SERVE_CLIENT: "true"
      PORT: "3000"
      # Three databases are made on the first boot.
      PG_HOST: postgres
      PG_USER: tooljet
      PG_DB: tooljet_production
      TOOLJET_DB_HOST: postgres
      TOOLJET_DB_USER: tooljet
      TOOLJET_DB_PASS: ${PG_PASS}
      TOOLJET_DB: tooljet_db
      PGRST_HOST: http://postgrest:3000
      # No browser makes an account except the first administrator's, and
      # neither of the next two phones home, which upstream ships them doing.
      DISABLE_SIGNUPS: "true"
      DISABLE_TOOLJET_TELEMETRY: "true"
      CHECK_FOR_UPDATES: "false"
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8176.
      - "127.0.0.1:8176:3000"
    depends_on:
      postgres:
        condition: service_healthy

  postgrest:
    image: postgrest/postgrest:v12.2.0@sha256:2cf1efd2c9c2e7606610c113cc73e936d8ce9ba089271cb9cbf11aa564bc30c7
    container_name: tooljet-postgrest
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://tooljet:${PG_PASS}@postgres:5432/tooljet_db
      PGRST_JWT_SECRET: ${PGRST_JWT_SECRET}
      PGRST_DB_PRE_CONFIG: postgrest.pre_config
    depends_on:
      postgres:
        condition: service_healthy
    # Restarts until ToolJet's first boot has made tooljet_db and its
    # postgrest.pre_config function. No `ports:` here either.
EOF
cd /srv/tooljet && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port, one bind mount.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-tooljet
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# ToolJet · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://docs.tooljet.ai/docs/setup/docker/
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also TOOLJET_HOST in .env.

<DOMAIN> {
	# ToolJet sends a Content-Security-Policy carrying `frame-ancestors *`,
	# which lets any site load this editor in an iframe. This rewrites that
	# one directive with a regular expression and leaves the rest alone.
	header Content-Security-Policy "frame-ancestors [^;]+" "frame-ancestors 'self'"

	header {
		# Nothing in the container knows it is served over https.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8176 is the loopback port compose publishes here, not a container port
	# and not open in the firewall. reverse_proxy carries the editor's
	# multiplayer WebSocket with no extra configuration.
	reverse_proxy 127.0.0.1:8176
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-tooljet, reload, and report what it objected to. Caddy asks for the
certificate on the first request and renews it itself, so nothing is scheduled.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8176 stays closed because it is bound to 127.0.0.1, and PostgreSQL and PostgREST publish
no host port at all. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8176, 5432 or 3000.

## 7. Start and verify

The first boot is slow: about 3 GB to pull, then the server waits for PostgreSQL, makes three
databases and migrates before it answers anything.

```bash
cd /srv/tooljet
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/health
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/onboarding/signup
docker compose exec -T postgres psql -U tooljet -d tooljet_db -tAc "select count(*) from pg_proc where proname='pre_config'"
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The health
response contains `"works":"yeah"`; it also calls the licence invalid and expired, which is the
community edition answering honestly rather than a fault. The third prints `403`, the security
assert here: open signup is shut before any account exists. The fourth prints `1`, meaning
ToolJet's migrations have made the function PostgREST needs. If any of the four misses, stop, run
`docker compose logs --tail 60 tooljet`, and name the likely cause: a `502` past fifteen minutes
points at step 4, a certificate error at step 5, and a server stuck at `wait-for-it` means step
3's password does not match a volume left from an earlier attempt. A running container is not
success.

The first screen at https://<DOMAIN> is the setup form, headed `Set up your admin account`, over
fields for `Name`, `Email` and a password and a `Sign up` button. The browser draws that heading,
which is why the asserts above go to the API rather than grepping the page.

STOP: tell the user to open https://<DOMAIN>, fill that form in, and wait. Do not continue until
they confirm. It creates the one administrator this install has. Tell them to put the password in
their password manager as they type it: there is no mail server here, so there is no reset link.

Once they confirm, prove the door shut behind them:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/onboarding/setup-super-admin
```

Assert: `403`. Before the account existed that command answered `400`, because the body was empty
rather than because the door was closed, so the move from `400` to `403` is the proof. Both
asserts must pass before you report success.

## 8. First backup and restore

Two artifacts. The database holds every app, query, datasource and user; the config archive holds
the files that rebuild the service around them and the key that decrypts the credentials.

```bash
cd /srv/tooljet
docker compose exec -T postgres pg_dumpall -U tooljet | gzip > /srv/tooljet/backups/tooljet-db-$(date +%F).sql.gz
sudo tar -czf /srv/tooljet/backups/tooljet-config-$(date +%F).tar.gz -C /srv/tooljet compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/tooljet/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. `pg_dumpall` rather than
`pg_dump`, because there are three databases in there and the ToolJet Database is one. Nothing is
stopped: the dump snapshots a running database consistently.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/tooljet
scp vps:/srv/tooljet/backups/* ~/backups/tooljet/
```

To restore: `docker compose down`, `sudo rm -rf /srv/tooljet/postgres`, recreate it as in step 2,
untar the config archive into /srv/tooljet, `docker compose up -d postgres`, wait 30 seconds for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U tooljet -d postgres`, then `docker compose up -d`. Tell
the user the stakes: `LOCKBOX_MASTER_KEY` in that `.env` decrypts every datasource credential in
the dump, so a restore beside a fresh key gives back every app and not one working connection.

## 9. Updating later

New versions are listed at https://github.com/ToolJet/ToolJet/releases. Stay on the `-lts` line;
`-beta` tags are the pre-release channel upstream advises against for real use. Take both backups
first, then edit the ToolJet image line in /srv/tooljet/compose.yml to the new tag and digest:

```bash
cd /srv/tooljet
docker compose pull
docker compose up -d
docker compose logs --tail 40 tooljet
```

ToolJet migrates its own database on the way up. Watch that log until it settles, then re-run
step 7's health check before calling the update done.

## 10. What will probably go wrong

PostgREST. For the first few minutes of the first boot it exits and restarts every few seconds
while everything else looks fine. I read that log, saw a connection error naming a database that
did not exist, and checked the password three times. Nothing was wrong: ToolJet makes
`tooljet_db` and the `postgrest.pre_config` function inside it during its own first boot, and
PostgREST cannot start until both exist. The fourth assert in step 7 tells you it has settled. If
it still restarts after that assert prints `1`, `docker compose logs --tail 30 postgrest` will
say why.

## 11. Out of scope

- Do not set `TJ_LICENSE` and do not switch to the `tooljet/tooljet-ee` image. This prompt
  installs the community edition, the AGPL-3.0 one.
- Do not configure SMTP. ToolJet builds and serves apps without it; the cost is invitation and
  password-reset email, a trade the user makes later.
- Do not add a Redis service or set `WORKER=true`. Those belong to the multi-worker workflow
  deployment; this install runs one server with the Redis its own image starts.
- Do not set `ENABLE_CORS` or `ENABLE_CUSTOM_DOMAINS`. The first opens the API to every origin,
  the second changes the cookie policy this install depends on.
