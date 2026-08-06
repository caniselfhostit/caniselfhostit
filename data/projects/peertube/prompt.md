You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install PeerTube 8.2.4 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask once and stop. `<DOMAIN>` becomes
`PEERTUBE_WEBSERVER_HOSTNAME`, inside every embed code and federated URL this instance publishes,
so changing it later breaks all of them; its A record must point here now. Tell the user this
streams only videos they upload, and that ffmpeg re-encodes each one here.

PeerTube with PostgreSQL and Redis wants 2048 MB of RAM available and 40 GB free on /srv before
any video. Upstream's own floor is 1.5 GB for the application alone.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

Both architectures ship. Under 2048 MB or 40 GB, print both and stop; do not install and hope.
If `dig +short` prints nothing, print that and stop: Caddy cannot certify a name that does not
resolve. 40 GB is a floor, not a budget, because HLS keeps every video as segments.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/peertube /srv/peertube/backups
sudo install -d -m 750 -o 999 -g 999 /srv/peertube/data /srv/peertube/config
sudo install -d -m 700 /srv/peertube/postgres /srv/peertube/redis
ls -la /srv/peertube
```

Assert: five entries, `data` and `config` owned by uid `999`, `postgres` and `redis` at mode `700`
owned by root. The image runs as uid 999 and walks /data at every start to chown what it does not
own, so handing those two over keeps that walk short. The database images chown their own
directory.

## 3. Secrets

Three: the PostgreSQL password, the key PeerTube signs tokens with, and the password its built-in
`root` account is created with. Generate all three here, print none, and keep them out of your
summary and every log line.

```bash
umask 077
cat > /srv/peertube/.env <<EOF
PEERTUBE_WEBSERVER_HOSTNAME=<DOMAIN>
PEERTUBE_ADMIN_EMAIL=<ADMIN_EMAIL>
POSTGRES_PASSWORD=$(openssl rand -hex 32)
PEERTUBE_SECRET=$(openssl rand -hex 32)
PT_INITIAL_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/peertube/.env
umask 022
ls -l /srv/peertube/.env
```

Assert: mode `-rw-------`. Hex not base64: Docker Compose reads this same file for interpolation
and a `$` in a value would be expanded.

The third line is why this block matters. Left unset, PeerTube invents the root password and the
documented way to learn it is to grep the container log, which would put a live credential in this
transcript. Tell the user it is in /srv/peertube/.env, read with
`grep PT_INITIAL_ROOT_PASSWORD /srv/peertube/.env`, and belongs in their password manager now.
PeerTube logs it once at first boot, so say that whoever reads that log can already read the
file.

## 4. compose.yml

```bash
cat > /srv/peertube/compose.yml <<'EOF'
# PeerTube · the deterministic fallback. Authored by caniselfhostit from the
# upstream docs, not copied from a repository:
#   https://docs.joinpeertube.org/install/docker
#   https://github.com/Chocobozzz/PeerTube/tree/v8.2.4/support/docker/production
#
# Three services. Upstream's compose ships seven: nginx, certbot and a reload
# loop in front, a postfix relay behind. Caddy replaces the first three. No
# postfix means no mail: one admin, closed signup, a password reset from a
# shell. PeerTube connects as the superuser the PostgreSQL image creates,
# because it runs CREATE EXTENSION for pg_trgm and unaccent at first boot.
# Digests read 2026-08-06; all three are multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    restart: unless-stopped
    environment:
      POSTGRES_DB: peertube
      POSTGRES_USER: peertube
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/peertube/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U peertube -d peertube"]
      interval: 10s
      retries: 18
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    # Session store and job queue. Appendonly keeps queued jobs.
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/peertube/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 18

  peertube:
    image: chocobozzz/peertube:v8.2.4@sha256:fee7ff44b9705401d8c228227e770257f088c3f3cb056746493888344a5a0324
    restart: unless-stopped
    env_file: /srv/peertube/.env
    environment:
      PEERTUBE_DB_HOSTNAME: postgres
      PEERTUBE_DB_USERNAME: peertube
      PEERTUBE_DB_PASSWORD: ${POSTGRES_PASSWORD}
      PEERTUBE_DB_SSL: "false"
      PEERTUBE_REDIS_HOSTNAME: redis
      # Caddy terminates TLS; without these two, every URL PeerTube
      # writes would say http.
      PEERTUBE_WEBSERVER_HTTPS: "true"
      PEERTUBE_WEBSERVER_PORT: "443"
      # Trust the docker bridge, so rate limits see real client IPs.
      PEERTUBE_TRUST_PROXY: '["loopback","linklocal","uniquelocal"]'
      # Closed registration, stated rather than assumed. Upstream agrees.
      PEERTUBE_SIGNUP_ENABLED: "false"
      PEERTUBE_CONTACT_FORM_ENABLED: "false"
      # Live wants a second published port and transcoding pipeline.
      PEERTUBE_LIVE_ENABLED: "false"
    volumes:
      # Videos, HLS segments, thumbnails, logs. The one that grows.
      - /srv/peertube/data:/data
      # PEERTUBE_LOCAL_CONFIG: what the admin UI writes.
      - /srv/peertube/config:/config
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8124.
      - "127.0.0.1:8124:9000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/peertube && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Three services, one published port, no mail.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-peertube
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# PeerTube · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/Chocobozzz/PeerTube/blob/v8.2.4/support/nginx/peertube,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Upstream ships a 262-line nginx config and a container to run it in. This
# block replaces both; each comment names the nginx setting it stands in for.
# Its ciphers, certbot and ACME webroot become Caddy's automatic HTTPS; its
# sendfile, aio and limit_rate are dropped as I/O tuning.
#
# Append to /etc/caddy/Caddyfile with <DOMAIN> replaced by your hostname.

<DOMAIN> {
	# nginx: client_max_body_size 12G on the upload routes. Caddy applies
	# no limit unless told to, so one ceiling is tighter than the default.
	# Upstream's per-route regexes are not copied: such a list rots the day
	# PeerTube adds an endpoint.
	request_body {
		max_size 12GB
	}

	# nginx: X-File-Maximum-Size, which PeerTube's uploader reads off a
	# 413. 8GB against a 12GB cap because multipart encoding inflates a
	# body by about 1.4x. Upstream pairs the same two numbers.
	header /api/v1/videos/upload* X-File-Maximum-Size "8GB"

	header {
		# PeerTube sets its own X-Frame-Options, so this does not.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# nginx: gzip on CSS, JS, fonts, SVG and XML. Caddy's default matcher
	# is that list and holds no video type, so HLS segments and Range
	# requests pass through untouched and seeking works.
	encode zstd gzip

	# 8124 is the loopback port compose publishes here, not a container
	# port and not open in the firewall. Three nginx settings need nothing
	# written: proxy_request_buffering off (Caddy never spools a request
	# body to disk), proxy_read_timeout 15m (no transport read timeout) and
	# the Upgrade headers on the socket routes (reverse_proxy upgrades
	# WebSockets itself).
	reverse_proxy 127.0.0.1:8124
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. On failure restore /etc/caddy/Caddyfile.before-peertube, reload, and report
what it objected to. Caddy gets the certificate on the first request and renews it itself, the
whole job of upstream's certbot container.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the way in, 443/udp is HTTP/3. 8124
stays closed because compose binds it to loopback, 5432 and 6379 because compose publishes
neither, 1935 because live is off. Assert: `Status: active`, rules for 80, 443/tcp and 443/udp,
none for those four.

## 7. Start and verify

PeerTube runs its migrations, creates `root` from `PT_INITIAL_ROOT_PASSWORD` and builds its
storage tree on the way up. On a cold pull that takes several minutes.

```bash
cd /srv/peertube
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/ping; echo
curl -sS https://<DOMAIN>/api/v1/config | grep -o '"signup":{"allowed":false'
curl -sS https://<DOMAIN>/api/v1/accounts/root | grep -o '"name":"root"'
curl -sS https://<DOMAIN>/login | grep -o 'og:platform" content="PeerTube"'
```

Assert all five, printing what you got: the loop ends on `200`; ping answers `pong`; the third
prints `"signup":{"allowed":false`, the security assert here and the reason nobody else can open
an account; the fourth prints `"name":"root"`; the fifth prints `og:platform" content="PeerTube"`,
the served page rather than a Caddy error. On any miss, stop, run
`docker compose logs --tail 40 peertube` and `docker compose logs --tail 20 postgres` and name the
step: a database never healthy is step 2, a `502` is step 5, `pg_trgm` in the log means PeerTube
is not connecting as the superuser PostgreSQL created. A running container is not success.

The first screen at https://<DOMAIN>/login shows the heading `Login on PeerTube` over a
`Username or email address` box, a `Password` box and a `Login` button.

STOP: tell the user to read their password with
`grep PT_INITIAL_ROOT_PASSWORD /srv/peertube/.env`, save it, sign in at https://<DOMAIN>/login as
`root`, upload one short video at https://<DOMAIN>/videos/upload, and wait. Do not continue until
they confirm it plays back: that is the product end to end, a file in, ffmpeg to HLS here, back
out through Caddy. Step 10 says how long to expect.

## 8. First backup and restore

Two artifacts: the database holds accounts, video records, comments and views; the config archive
holds what rebuilds the service around them. The video files are in neither, on purpose:
/srv/peertube/data runs to tens of gigabytes and wants its own copy.

```bash
cd /srv/peertube
docker compose exec -T postgres pg_dump -U peertube -d peertube | gzip > /srv/peertube/backups/peertube-db-$(date +%F).sql.gz
sudo tar -czf /srv/peertube/backups/peertube-config-$(date +%F).tar.gz -C /srv/peertube compose.yml .env config -C /etc/caddy Caddyfile
ls -lh /srv/peertube/backups/
```

Assert: both exist, both non-empty, print both sizes. Nothing stops: `pg_dump` snapshots a running
database consistently. A backup on the same disk is not a backup, so run this from the user's
machine:

```bash
mkdir -p ~/backups/peertube
scp vps:/srv/peertube/backups/* ~/backups/peertube/
```

To restore: `docker compose down`, `sudo rm -rf /srv/peertube/postgres`, recreate it as in step 2,
untar the config archive into /srv/peertube so .env is back first, `docker compose up -d postgres`,
wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U peertube -d peertube`, then `docker compose up -d`. Order
matters: PostgreSQL takes its password from .env the moment it initialises an empty directory. And
say the other half: a restored database whose rows point at videos nobody copied is a catalogue of
dead links.

## 9. Updating later

Releases are at https://github.com/Chocobozzz/PeerTube/releases. Take both artifacts first, then
edit the image line in /srv/peertube/compose.yml to the new tag and digest:

```bash
cd /srv/peertube
docker compose pull
docker compose up -d
docker compose logs --tail 40 peertube
```

PeerTube migrates its database on the way up, and a major version spends minutes on it. Watch that
log until it settles, then re-run step 7's five checks.

## 10. What will probably go wrong

The first upload will look like a broken install. Mine did: the page said the video was published,
the video page showed a spinner where the player belongs, and the logs read like nothing was
happening for eleven minutes. Nothing was wrong. PeerTube had handed the file to ffmpeg with one
thread, upstream's default, and a two-core VPS re-encodes ten minutes of 1080p in about real time
or worse. That container near 100% CPU in `docker stats` is this working, not failing. If the user
wants it faster, the honest answers are more cores or a remote runner.

## 11. Out of scope

- Do not enable live streaming. It wants port 1935 open to the internet and a second transcoding
  pipeline running the whole time somebody watches.
- Do not configure SMTP or add upstream's postfix container. Registration is closed and there is
  one account, whose password is reset with
  `docker compose exec -u peertube peertube npm run reset-password -- -u root`.
- Do not enable object storage. Moving video to S3 is right for a growing instance, and it is a
  bucket, a credential pair and a base URL this prompt has not set up.
- Do not follow other instances or turn on auto-follow. That pulls remote videos and comments onto
  this disk, and it is the user's call.
