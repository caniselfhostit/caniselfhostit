You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Docmost 0.95.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Tell them why it matters when you ask: `<DOMAIN>` becomes `APP_URL`, and Docmost builds every
invitation link and every shared page link from `APP_URL`. Its A record must already point at
this server.

Docmost, PostgreSQL and Redis together need 2048 MB of RAM available and 10 GB free on /srv.
All three images publish amd64 and arm64. Measure all four before installing anything:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/docmost /srv/docmost/backups
sudo install -d -m 755 -o 1000 -g 1000 /srv/docmost/storage
sudo install -d -m 700 /srv/docmost/postgres /srv/docmost/redis
ls -la /srv/docmost
```

Assert: `ls -la` shows `backups` owned by the login user, `storage` owned by uid 1000, and
`postgres` and `redis` at mode `700` owned by root. Three different owners, three reasons.
Uploaded attachments go in `storage`, and the Docmost image runs as its base image's `node`
user, which is uid 1000. The PostgreSQL and Redis images each chown their own data directory
at start-up, so those two are left alone.

## 3. Secrets

Two secrets: the application secret Docmost signs sessions with, and the PostgreSQL password.
Generate both on the server. Do not print either, do not repeat them in your summary, and do
not put them in any log line. Upstream states the app refuses to start if `APP_SECRET` keeps
its shipped default, and asks for 32 characters minimum.

```bash
umask 077
cat > /srv/docmost/.env <<EOF
APP_URL=https://<DOMAIN>
APP_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/docmost/.env
umask 022
ls -l /srv/docmost/.env
```

Assert: the file exists with mode `-rw-------`. Hex rather than base64 for both, because
`DB_PASSWORD` is interpolated into a PostgreSQL connection string in the next step and a `/`
or a `+` in a URL is an argument nobody needs to have. Tell the user the file is the whole
configuration of this install and that step 8 backs it up.

## 4. compose.yml

```bash
cat > /srv/docmost/compose.yml <<'EOF'
# Docmost · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installation ....... https://docmost.com/docs/installation
#   variable reference . https://docmost.com/docs/self-hosting/environment-variables
#   reverse proxy ...... https://docmost.com/docs/self-hosting/reverse-proxy
#   caddy notes ........ https://docmost.com/docs/self-hosting/reverse-proxy/caddy
#   image ............. https://github.com/docmost/docmost/blob/main/Dockerfile
#
# Three services: Docmost, the PostgreSQL that holds every page, and the Redis
# that carries the collaborative editor and the job queue. Upstream lists
# DATABASE_URL and REDIS_URL as required, so neither is a nice-to-have here.
# The PostgreSQL 18 image keeps its cluster under /var/lib/postgresql and
# chowns that directory itself on first start, and the Redis image chowns /data
# on every start, so step 2 leaves both root-owned and lets the images sort it
# out. Docmost runs as the node user of its base image, uid 1000, so the
# storage bind mount is created with that owner instead. Tags and digests were
# read from the registries on 2026-08-05; all three images publish amd64 and
# arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: docmost-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: docmost
      POSTGRES_USER: docmost
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/docmost/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U docmost -d docmost"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: docmost-redis
    restart: unless-stopped
    # appendonly writes every change to disk, and noeviction makes Redis refuse
    # writes rather than silently drop a queued job when memory runs out.
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - /srv/docmost/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 6379 never leaves the compose network.

  docmost:
    image: docmost/docmost:0.95.0@sha256:41c8d777cf23c74e78f94e676aec328b7d7856f48df5e573543dac68d371e37c
    container_name: docmost
    restart: unless-stopped
    env_file: /srv/docmost/.env
    environment:
      DATABASE_URL: postgresql://docmost:${DB_PASSWORD}@postgres:5432/docmost
      REDIS_URL: redis://redis:6379
      # Attachments land on this disk, under the bind mount below. No S3
      # bucket, no Azure account, nothing extra to sign up for.
      STORAGE_DRIVER: local
    volumes:
      - /srv/docmost/storage:/app/data/storage
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8092.
      - "127.0.0.1:8092:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/docmost && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose reads `.env` from this directory to fill
`${DB_PASSWORD}` in two places, the PostgreSQL environment and the connection string, which is
why one generated value ends up in both without ever being typed twice.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-docmost
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Docmost · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docmost.com/docs/self-hosting/reverse-proxy/caddy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_URL in .env, and Docmost builds its invitation links and its shared
# page links from APP_URL, so the two have to say the same thing.

<DOMAIN> {
	encode zstd gzip

	# No X-Frame-Options here on purpose. Docmost decides its own frame
	# header from IFRAME_EMBED_ALLOWED, and one set at this layer would
	# override the application's answer without the application knowing.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8092 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Upstream states the
	# real-time editor rides WebSockets and stays read-only if the proxy
	# does not pass the Upgrade and Connection headers. Caddy's reverse_proxy
	# performs that upgrade with no extra directive, which is the reason this
	# block is three lines rather than thirty.
	reverse_proxy 127.0.0.1:8092
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-docmost, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it by itself, so there is nothing
to schedule.

## 6. Firewall

Two ports open, both Caddy's. The commands are idempotent, so on a box Prompt Zero configured
they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8092 stays closed because compose binds it to 127.0.0.1, and 5432 and 6379
stay closed because compose publishes no host port for them at all. Assert: `ufw status
verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule naming 8092, 5432
or 6379.

## 7. Start and verify

Docmost runs its own database migrations on the way up, so the first start is slower than the
ones after it.

```bash
cd /srv/docmost
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/workspace/public
```

Assert, all three, and print what you received for each. The loop ends printing `200`. The
health body contains `"status":"ok"` and reports both `database` and `redis` as `up`, which is
the whole reason to look at it rather than at `docker ps`. The third command prints `404`,
because no workspace exists yet. If any of the three misses, stop, run
`docker compose logs --tail 40 docmost`, `docker compose logs --tail 20 postgres` and
`docker compose logs --tail 20 redis`, and say which earlier step is the likely cause: a health
body with `redis` down points at step 4, and a `502` from Caddy points at step 5. A running
container is not success.

The first screen at https://<DOMAIN>/setup/register shows the heading `Create workspace` above
fields for a workspace name, a name, an email and a password of at least 8 characters.

STOP: tell the user to open https://<DOMAIN>/setup/register, create the workspace and their own
account there, and wait. Do not continue until they confirm. That first account becomes the
workspace owner.

Once they confirm, prove that first-run registration is now closed to everyone else:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/workspace/public
curl -sS -w '\n%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' https://<DOMAIN>/api/auth/setup
```

Assert: the first prints `200`, so the workspace exists. The second returns a body containing
`Workspace setup already completed.` and a 403 status, so nobody who finds this hostname can
create a second owner account. Both asserts must pass before you report success.

## 8. First backup and restore

Two artifacts. The database holds every page, space, user and permission. The file archive
holds the attachments plus the three files that rebuild the service around them.

```bash
cd /srv/docmost
docker compose exec -T postgres pg_dump -U docmost -d docmost | gzip > /srv/docmost/backups/docmost-db-$(date +%F).sql.gz
sudo tar -czf /srv/docmost/backups/docmost-files-$(date +%F).tar.gz -C /srv/docmost storage compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/docmost/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Redis is not backed up on purpose: it
holds the editor's live session state and the job queue, not content, and it rebuilds itself.

A backup on the same disk is not a backup, so run this one from the user's machine:

```bash
mkdir -p ~/backups/docmost
scp vps:/srv/docmost/backups/* ~/backups/docmost/
```

To restore: `docker compose down`, `sudo rm -rf /srv/docmost/postgres /srv/docmost/storage`,
recreate both directories exactly as step 2 does, untar the file archive into /srv/docmost,
`docker compose up -d postgres`, wait for it to report healthy, then pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U docmost -d docmost`, then
`docker compose up -d`. The `.env` inside the archive matters as much as the dump: PostgreSQL
keeps the password it was created with, and a restore with a different `DB_PASSWORD` produces
an authentication error that says nothing about passwords.

## 9. Updating later

New versions are listed at https://github.com/docmost/docmost/releases. Take both backup
artifacts first, then edit the image line in /srv/docmost/compose.yml to the new tag and its
digest:

```bash
cd /srv/docmost
docker compose pull
docker compose up -d
docker compose logs --tail 30 docmost
```

Docmost migrates its own database on the way up, so watch that log until it settles, then
re-run the health check from step 7 before calling the update done.

## 10. What will probably go wrong

Attachments, and not until later. On my first run I left /srv/docmost/storage owned by root,
the containers started, the health endpoint answered `"status":"ok"`, pages saved, and
everything looked finished. The first image a user dragged into a page failed with a server
error, and the only trace was an `EACCES` line in the Docmost log. Health checks the database
and Redis and never touches the storage directory, so nothing warns you. If uploads fail, run
`ls -ld /srv/docmost/storage` and confirm it is owned by uid 1000 before looking anywhere else.

## 11. Out of scope

- Do not configure SMTP. Docmost runs without mail, and invitations can be handed out as links
  copied from the members page. Password resets are the thing the user gives up until they add
  a mail provider.
- Do not switch `STORAGE_DRIVER` to s3 or azure. That is a second vendor account, and the
  backup in step 8 assumes attachments are on this disk.
- Do not add a license key and do not enable the enterprise features. Bases, SSO, AI, audit
  logs and SCIM are sold separately and are not part of this install.
- Do not set `AI_DRIVER`, `OPENAI_API_KEY` or any other model credential. Nothing here needs a
  model to store a page.
