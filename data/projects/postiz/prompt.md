You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Postiz 2.23.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. Say why: it is the host inside every OAuth redirect URI they register at X, Meta
and LinkedIn, so moving it later means editing each of those apps by hand. Its A record
must already point at this server.

Postiz needs 4096 MB of RAM available and 20 GB free on /srv: upstream tested its compose
file on a 2 GB machine, then says to plan for 4 GB or more once PostgreSQL, Redis and the
workflow engine share a host, which is this install. A VPS sold as 4 GB has less than
4096 MB available once the OS takes its share, so this gate stops on one by design: 8 GB
is the size to buy. All four images are amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop.
Do not install and hope. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/postiz /srv/postiz/backups /srv/postiz/config /srv/postiz/uploads
sudo install -d -m 700 /srv/postiz/postgres /srv/postiz/temporal-postgres /srv/postiz/redis
ls -la /srv/postiz
```

Assert: six directories. `backups`, `config` and `uploads` owned by the login user, and
`postgres`, `temporal-postgres` and `redis` at mode `700` owned by root. Both PostgreSQL
images and Redis chown their own data directory on first start; leave those three alone.

## 3. Secrets

Three: a password for each PostgreSQL, and the key that signs session tokens. Generate them
on the server. Do not print them, do not repeat them in your summary, and keep them out of
every log line.

```bash
umask 077
cat > /srv/postiz/.env <<EOF
POSTIZ_DOMAIN=<DOMAIN>
POSTIZ_DB_PASSWORD=$(openssl rand -hex 32)
TEMPORAL_DB_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 48)
EOF
chmod 600 /srv/postiz/.env
umask 022
ls -l /srv/postiz/.env
```

Assert: mode `-rw-------`. Hex rather than base64, because two of the three travel inside
connection strings. Compose reads this file from the working directory, so every command
from here runs with /srv/postiz as that directory. Tell the user `sudo cat /srv/postiz/.env`
reads it, that rotating the signing key signs every session out, and that this file is
where the social-network keys go later.

## 4. compose.yml

Five services: Postiz, its PostgreSQL, its Redis, the Temporal server, and the PostgreSQL
Temporal keeps its workflow history in.

```bash
cat > /srv/postiz/compose.yml <<'EOF'
# Postiz · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose install ....... https://docs.postiz.com/installation/docker-compose
#   variable reference .... https://docs.postiz.com/configuration/reference
#   system requirements ... https://docs.postiz.com/installation/system-requirements
#   temporal, sql only .... https://github.com/temporalio/docker-compose/blob/main/docker-compose-postgres.yml
#
# Five services. Postiz runs its frontend, backend and orchestrator in one
# container behind an nginx on port 5000. Upstream has required Temporal since
# v2.12.0, and Temporal keeps workflow history in its own database, so the two
# PostgreSQL services differ: the first holds your posts, the second holds
# state you can throw away. Upstream also ships Elasticsearch, a Temporal web
# UI and admin-tools; Temporal's own PostgreSQL-only compose has none of them,
# so neither does this. Digests read 2026-08-06; all four are amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: postiz

services:
  postiz-postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_DB: postiz
      POSTGRES_USER: postiz
      POSTGRES_PASSWORD: ${POSTIZ_DB_PASSWORD}
    volumes:
      - /srv/postiz/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postiz -d postiz"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other containers.

  postiz-redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/postiz/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  temporal-postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_USER: temporal
      POSTGRES_PASSWORD: ${TEMPORAL_DB_PASSWORD}
    volumes:
      - /srv/postiz/temporal-postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U temporal"]
      interval: 10s
      retries: 12

  temporal:
    image: temporalio/auto-setup:1.28.1@sha256:607d68caa111338d754771efb876c92dfcdae06d056e4530bb31cd0f37406e6a
    restart: unless-stopped
    environment:
      # postgres12 names the driver, not a version floor.
      DB: postgres12
      DB_PORT: "5432"
      POSTGRES_USER: temporal
      POSTGRES_PWD: ${TEMPORAL_DB_PASSWORD}
      POSTGRES_SEEDS: temporal-postgres
    # No dynamic-config mount: the image ships its own, and Postiz overrides
    # nothing in it.
    healthcheck:
      test: ["CMD", "temporal", "operator", "cluster", "health", "--address", "temporal:7233"]
      interval: 10s
      retries: 30
    depends_on:
      temporal-postgres:
        condition: service_healthy

  postiz:
    image: ghcr.io/gitroomhq/postiz-app:v2.23.0@sha256:785f97312f66a347fb96cdccc4ded5a33ced69a672c89a9adc8054e7d6a21dc5
    restart: unless-stopped
    environment:
      # /api because the container's nginx routes /api/ to the backend.
      FRONTEND_URL: "https://${POSTIZ_DOMAIN}"
      NEXT_PUBLIC_BACKEND_URL: "https://${POSTIZ_DOMAIN}/api"
      BACKEND_INTERNAL_URL: "http://localhost:3000"
      DATABASE_URL: "postgresql://postiz:${POSTIZ_DB_PASSWORD}@postiz-postgres:5432/postiz"
      REDIS_URL: "redis://postiz-redis:6379"
      JWT_SECRET: ${JWT_SECRET}
      TEMPORAL_ADDRESS: "temporal:7233"
      # RUN_CRON registers the workflows that post on a schedule.
      IS_GENERAL: "true"
      RUN_CRON: "true"
      # One signup while the database is empty, then the page shuts.
      DISABLE_REGISTRATION: "true"
      STORAGE_PROVIDER: "local"
      UPLOAD_DIRECTORY: "/uploads"
      NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY: "/uploads"
    volumes:
      - /srv/postiz/config:/config
      - /srv/postiz/uploads:/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8111.
      - "127.0.0.1:8111:5000"
    depends_on:
      postiz-postgres:
        condition: service_healthy
      postiz-redis:
        condition: service_healthy
      temporal:
        condition: service_healthy
EOF
cd /srv/postiz && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK` and nothing else. A warning about an unset variable means step 3 did
not write .env.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first:
a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-postiz
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Postiz · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://docs.postiz.com/reverse-proxies/caddy
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. It is also
# POSTIZ_DOMAIN in .env, and the host every OAuth redirect URI points back at.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting a channel bounces out to a provider.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8111 is the loopback port compose publishes here. It is not a container
	# port and it is not open in the firewall. One upstream serves both halves
	# of the app: the nginx inside the container sends /api/ to the backend and
	# everything else to the frontend.
	reverse_proxy 127.0.0.1:8111
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-postiz, reload, and report what it objected to. Caddy issues
the certificate on the first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, idempotent:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the way in, 443/udp is
HTTP/3. 8111 is bound to 127.0.0.1, and compose publishes no host port at all for the
databases, the cache or the workflow engine. Assert: `ufw status verbose` prints
`Status: active`, shows those three rules, and nothing for 8111, 5432, 6379 or 7233.

## 7. Start and verify

The first start is slow: Temporal builds two schemas, then Postiz runs its migrations.

```bash
cd /srv/postiz
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose exec -T temporal temporal operator cluster health --address temporal:7233
curl -sS https://<DOMAIN>/api/
curl -sS https://<DOMAIN>/api/auth/can-register
```

Assert all four, printing what you received for each. The loop ends on `200`. The Temporal
check prints `SERVING`. The third prints `App is running!`, the backend answering through
Caddy. The fourth prints `{"register":true}`, the sign-up window open because the database
holds no account yet. If any of the four misses, stop, run
`docker compose logs --tail 40 postiz` and `docker compose logs --tail 20 temporal`, and
name the likely cause: a Temporal container stuck below healthy points at step 3, where an
empty password leaves its PostgreSQL refusing connections. A running container is not
success.

The first screen is https://<DOMAIN>/auth: the heading `Sign Up` over an email, password
and company form, with a `Create Account` button.

STOP: tell the user to open https://<DOMAIN>/auth, create the one account this install will
have, and wait. Do not continue until they confirm. Then check the window shut:

```bash
curl -sS https://<DOMAIN>/api/auth/can-register
```

Assert: `{"register":false}`. Upstream documents `DISABLE_REGISTRATION`, which compose.yml
sets, as allowing one signup and then closing the sign-up page, so this proves the account
it allowed is the user's own. Have them reload https://<DOMAIN>/auth and confirm it reads
`Registration is disabled`. Both asserts pass before you claim success.

## 8. First backup and restore

Two artifacts: the dump holds accounts, drafts and the schedule, the archive holds the
files that rebuild the service around it, uploaded media included. Temporal's database is in
neither, because auto-setup rebuilds it from empty.

```bash
cd /srv/postiz
docker compose exec -T postiz-postgres pg_dump -U postiz -d postiz | gzip > /srv/postiz/backups/postiz-db-$(date +%F).sql.gz
sudo tar -czf /srv/postiz/backups/postiz-config-$(date +%F).tar.gz -C /srv/postiz compose.yml .env config uploads -C /etc/caddy Caddyfile
ls -lh /srv/postiz/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops: `pg_dump` snapshots
a running database consistently. A backup on the same disk is not a backup, so run this
from the user's machine:

```bash
mkdir -p ~/backups/postiz
scp vps:/srv/postiz/backups/* ~/backups/postiz/
```

To restore: `docker compose down`, remove /srv/postiz/postgres and
/srv/postiz/temporal-postgres, recreate both as in step 2, untar the archive into
/srv/postiz, `docker compose up -d postiz-postgres`, wait for healthy, pipe `gunzip -c` on
the `.sql.gz` into `docker compose exec -T postiz-postgres psql -U postiz -d postiz`, then
`docker compose up -d`. Drafts and calendar come back; a channel comes back only if its
token has not expired meanwhile.

## 9. Updating later

New versions are listed at https://github.com/gitroomhq/postiz-app/releases. Take both
backups first, then edit the image line in /srv/postiz/compose.yml to the new tag and
digest:

```bash
cd /srv/postiz
docker compose pull
docker compose up -d
docker compose logs --tail 30 postiz
```

Watch that log until it settles, then re-run the four checks from step 7. Which services
the stack needs changes between releases, so read the notes, not only the tag.

## 10. What will probably go wrong

The first four minutes look like a broken install. I watched https://<DOMAIN>/api/ return
`502` over and over while `docker compose ps` showed every container up, and went hunting a
Caddy mistake that was not there. Temporal was still building its schemas, and Postiz
answers nothing until it can reach Temporal. Watch `docker compose logs -f temporal`, then
the Postiz log, and give step 7 its ten minutes first.

## 11. Out of scope

- Do not connect a social network, and do not create developer accounts or apps for the
  user. Each network needs an app registered in that company's own developer portal, a
  redirect URI under `https://<DOMAIN>/integrations/social/`, and its client id and secret
  added to /srv/postiz/.env. Several are reviewed by a person at the other company
  and take days, which you cannot clear and a STOP cannot wait out. Say that in your
  summary, with https://docs.postiz.com/providers/overview.
- Do not configure SMTP or set `EMAIL_PROVIDER`. With no mail provider set, upstream
  activates accounts without email, which this install relies on.
- Do not install the Temporal web UI, the admin-tools container or Elasticsearch. Upstream
  ships all three; each is a service to watch.
- Do not set `OPENAI_API_KEY`, the Stripe keys, or `STORAGE_PROVIDER=cloudflare`.
