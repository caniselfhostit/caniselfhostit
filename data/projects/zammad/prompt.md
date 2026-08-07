You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Zammad 7.1.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
It becomes `ZAMMAD_FQDN`, the address Zammad writes into every link it builds, and its A record
must already point at this server.

Zammad needs 6144 MB of RAM available and 20 GB free on /srv. Six gigabytes is upstream's own
minimum for a stack without Elasticsearch, which is this one. Every image publishes amd64 and
arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 6144 MB or free disk is under 20 GB, print both numbers and stop.
Four Rails processes hold the application in memory at once, and the OOM killer arrives
mid-schema-load. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/zammad /srv/zammad/backups /srv/zammad/redis
sudo install -d -m 750 -o 1000 -g 1000 /srv/zammad/storage
sudo install -d -m 700 /srv/zammad/postgres
ls -la /srv/zammad
```

Assert: `backups` and `redis` are owned by the login user, `storage` by uid `1000`, and
`postgres` is mode `700` owned by root. The Zammad image runs as uid 1000 and fails on first
boot if it cannot write `storage`. The PostgreSQL image chowns its own data directory, so leave
it alone.

## 3. Secrets

One secret: the PostgreSQL password. Upstream ships `zammad` as its default, so this step
replaces a published credential rather than inventing a requirement. Generate it on the server,
do not print it, do not repeat it in your summary, keep it out of any log line.

```bash
umask 077
cat > /srv/zammad/.env <<EOF
ZAMMAD_FQDN=<DOMAIN>
ZAMMAD_HTTP_TYPE=https
POSTGRESQL_PASS=$(openssl rand -hex 32)
EOF
chmod 600 /srv/zammad/.env
umask 022
ls -l /srv/zammad/.env
```

Assert: mode `-rw-------`. Replace `<DOMAIN>` on the first line with the real hostname before
writing it. No human signs in with this value; the administrator account is made in a browser
in step 7. Tell the user this file is half the backup: a database restored beside a
different .env does not open.

## 4. compose.yml

```bash
cat > /srv/zammad/compose.yml <<'EOF'
# Zammad · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose ..... https://docs.zammad.org/en/latest/install/docker-compose.html
#   scenarios .......... https://docs.zammad.org/en/latest/install/docker-compose/docker-compose-scenarios.html
#   variable reference . https://docs.zammad.org/en/latest/appendix/environment-variables.html
#
# Seven services. Four are one Zammad image under different commands:
# railsserver answers the browser, websocket carries live updates, scheduler
# works the job queue, nginx serves the assets and routes /ws. PostgreSQL,
# Redis and memcached are the prerequisites upstream names. Their own file
# adds three more, each left out here: Elasticsearch through their
# ELASTICSEARCH_ENABLED switch, at the cost of full-text search; the nightly
# backup container, since step 8 takes a dump that leaves the box; and the
# migration container, run once by hand so its output is on screen. Digests
# read from Docker Hub on 2026-08-07; all four images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: zammad

# The four Zammad processes share one image; compose ignores x- keys.
x-zammad: &zammad
  image: zammad/zammad:7.1.2-0003@sha256:1ce0e929fac75f83f3e7534e9eb7aabfc3596cffbd00e25393be79709b9bea0c
  restart: unless-stopped
  init: true
  env_file: /srv/zammad/.env
  environment:
    POSTGRESQL_HOST: zammad-postgresql
    POSTGRESQL_DB: zammad_production
    POSTGRESQL_USER: zammad
    MEMCACHE_SERVERS: zammad-memcached:11211
    REDIS_URL: redis://zammad-redis:6379
    # Upstream's own switch for a stack with no Elasticsearch in it.
    ELASTICSEARCH_ENABLED: "false"
    # Caddy terminates TLS, so nginx is told the scheme it cannot see.
    NGINX_SERVER_SCHEME: https
    # Clients reach nginx over the compose network, never over loopback.
    RAILS_TRUSTED_PROXIES: 127.0.0.1,::1,172.16.0.0/12
  volumes:
    - /srv/zammad/storage:/opt/zammad/storage
  depends_on:
    zammad-postgresql:
      condition: service_healthy
    zammad-redis:
      condition: service_healthy
    zammad-memcached:
      condition: service_healthy

services:
  zammad-postgresql:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: zammad-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: zammad_production
      POSTGRES_USER: zammad
      POSTGRES_PASSWORD: ${POSTGRESQL_PASS}
    volumes:
      - /srv/zammad/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zammad -d zammad_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  zammad-redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: zammad-redis
    restart: unless-stopped
    volumes:
      - /srv/zammad/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  zammad-memcached:
    image: memcached:1.6.45-alpine@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7
    container_name: zammad-memcached
    restart: unless-stopped
    command: memcached -m 256M
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "11211"]
      interval: 10s
      retries: 12

  zammad-railsserver:
    <<: *zammad
    container_name: zammad-railsserver
    command: ["zammad-railsserver"]
    healthcheck:
      # The first boot loads a large schema, hence the long start period.
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:3000"]
      interval: 30s
      start_period: 240s
      retries: 5

  zammad-websocket:
    <<: *zammad
    container_name: zammad-websocket
    command: ["zammad-websocket"]

  zammad-scheduler:
    <<: *zammad
    container_name: zammad-scheduler
    command: ["zammad-scheduler"]

  zammad-nginx:
    <<: *zammad
    container_name: zammad-nginx
    command: ["zammad-nginx"]
    init: false
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8169.
      - "127.0.0.1:8169:8080"
    depends_on:
      zammad-railsserver:
        condition: service_healthy
EOF
cd /srv/zammad && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The scheduler is not scenery: it works the queue where
triggers, escalation clocks and notifications run, and without it nothing happens on schedule.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-zammad
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Zammad · the Caddy site block for this service. Authored by caniselfhostit
# from https://docs.zammad.org/en/latest/install/docker-compose.html and
# https://caddyserver.com/docs/automatic-https. Append it to
# /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname pointed at this
# box; that hostname is also ZAMMAD_FQDN in .env.

<DOMAIN> {
	# A helpdesk holds other people's names and complaints, so nothing here
	# is framed, sniffed, or leaked through a referrer.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8169 is the loopback port compose publishes here, not open in the
	# firewall. The Zammad nginx behind it routes /ws itself, so Caddy has
	# one upstream.
	reverse_proxy 127.0.0.1:8169
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` and the reload both exit 0. If validate fails, restore
/etc/caddy/Caddyfile.before-zammad, reload, and report what it objected to. Caddy gets the
certificate on first request and renews it.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so nothing changes on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the way in, 443/udp is HTTP/3.
8169 is bound to 127.0.0.1, and 5432, 6379 and 11211 have no host port at all. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for
8169, 5432, 6379 or 11211.

## 7. Start and verify

The migration container runs first, once, in the foreground: it creates the database, loads the
schema, seeds it and writes the FQDN from .env into the settings. Expect minutes of output.

```bash
cd /srv/zammad
docker compose pull
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/users
```

Assert all three, printing what you received. The init run exits 0, having reached PostgreSQL
and loaded the schema; the loop ends on `200`; the unauthenticated call to /api/v1/users prints
`401`, the security assert here. If any misses, stop, run
`docker compose logs --tail 40 zammad-railsserver` and name the cause: a `502` that never
becomes `200` means nginx is still waiting on the rails health check, and a connection failure
in the init run points at step 3. A running container is not success.

The first screen at https://<DOMAIN> shows the heading `Welcome!` above a button reading
`Set up a new system`.

STOP: tell the user to open https://<DOMAIN>, press `Set up a new system`, and work through the
wizard to create their administrator account, and wait. Do not continue until they confirm.
Tell them to put that password in their password manager as they type it: this install has no
mail, so there is no reset link behind it.

Once they confirm, shut the self-signup door Zammad ships open, then prove both facts:

```bash
cd /srv/zammad
docker compose exec -T zammad-railsserver bundle exec rails r "Setting.set('user_create_account', false)"
curl -sS -H 'Content-Type: application/json' -d '{"query":"{systemSetupInfo{status}}"}' https://<DOMAIN>/graphql
curl -sS -H 'Content-Type: application/json' -d '{"query":"{applicationConfig{key value}}"}' https://<DOMAIN>/graphql | grep -q user_create_account && echo "signup OPEN" || echo "signup CLOSED"
```

Assert: the first curl prints `"status":"done"`, Zammad confirming through its own API that an
administrator now exists, and the last line prints `signup CLOSED`, because Zammad hands
`user_create_account` to anonymous browsers only while it is on. Both must pass before you
report success.

## 8. First backup and restore

Two artifacts. Attachments live in the database on the default storage setting, so the dump is
the whole of the data; the config archive rebuilds the service around it.

```bash
cd /srv/zammad
docker compose exec -T zammad-postgresql pg_dump -U zammad -d zammad_production | gzip > /srv/zammad/backups/zammad-db-$(date +%F).sql.gz
sudo tar -czf /srv/zammad/backups/zammad-config-$(date +%F).tar.gz -C /srv/zammad compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/zammad/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Redis and memcached are in neither archive:
they hold sessions and caches, not durable data.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/zammad
scp vps:/srv/zammad/backups/* ~/backups/zammad/
```

To restore: `docker compose down`, `sudo rm -rf /srv/zammad/postgres`, recreate it as in step 2,
untar the config archive into /srv/zammad so `.env` is back before anything starts,
`docker compose up -d zammad-postgresql`, wait for healthy, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T zammad-postgresql psql -U zammad -d zammad_production`, run step
7's init command once, then `docker compose up -d`. Tell the user every ticket and attachment
they will ever have is in that one dump.

## 9. Updating later

Image tags are listed at https://hub.docker.com/r/zammad/zammad/tags and software versions at
https://github.com/zammad/zammad/tags. The tag carries a build number, which is why this pins
`7.1.2-0003` and not `7.1.2`. Back up first, then edit the image line in
/srv/zammad/compose.yml to the new tag and digest:

```bash
cd /srv/zammad
docker compose pull
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d
docker compose logs --tail 30 zammad-railsserver
```

That init run is not optional: the new image migrates the database it inherited, and skipping it
leaves every container waiting on migrations nobody ran. Then re-run step 7's checks.

## 10. What will probably go wrong

The wait after `docker compose up -d`. It returned in a second, `docker compose ps` showed
zammad-nginx as `Created` rather than running, and https://<DOMAIN> answered `502` for four
minutes. Nothing was wrong: nginx waits on the rails health check, which has a four-minute start
period because the first boot loads a great deal before answering anything. I tore the stack
down and started again, sure it had hung, and bought another four minutes. Let step 7's loop
run, and watch `docker compose logs -f zammad-railsserver` meanwhile.

## 11. Out of scope

- Do not configure SMTP, IMAP or POP3. Ticket-by-email is what most people eventually want
  here, and it is a separate day's work with a mail provider; the web form, the agent interface
  and the customer portal all work without it.
- Do not add Elasticsearch. This stack is built without it deliberately, and it costs another
  container, four gigabytes and a reindex.
- Do not set `user_create_account` back to true. Step 7 asserts it is off, and an open signup
  on a public helpdesk is an open door.
- Do not enable the built-in backup container or S3 storage. Step 8 owns the backup, and a
  bucket hides attachments from it.
