You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install wger 2.6.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here. wger also needs a hostname of its own: upstream states it
does not work in a subdirectory.

wger needs 2048 MB of RAM available and 10 GB free on /srv, and all four images publish amd64
and arm64. Its compose file carries an inline nginx config, so Docker Compose has to be 2.23 or
newer.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
docker compose version
dig +short <DOMAIN>
```

Print the numbers and stop if RAM is under 2048 MB, disk is under 10 GB, compose is older than
2.23, or `dig +short` prints nothing.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wger /srv/wger/backups
sudo install -d -m 700 /srv/wger/postgres
sudo install -d -m 755 -o 1000 -g 1000 /srv/wger/static /srv/wger/media
ls -la /srv/wger
```

Assert: `backups` owned by the login user, `postgres` at mode `700` owned by root, `static` and
`media` owned by uid `1000`. PostgreSQL chowns its own data directory, so leave it alone. The
other two follow upstream: a folder of static files belongs to UID and GID 1000, whether or not
that user exists here, and is readable by everyone. Get it wrong and the site loads unstyled.

## 3. Secrets

Four secrets, all generated here. Do not print any of them, do not repeat them in your summary,
and keep them out of log lines. Hex for the first three: each passes through a file a shell and
a compose parser both read.

```bash
umask 077
cat > /srv/wger/.env <<EOF
SITE_URL=https://<DOMAIN>
CSRF_TRUSTED_ORIGINS=https://<DOMAIN>
TIME_ZONE=UTC
TZ=UTC
SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
WGER_ADMIN_PASSWORD=$(openssl rand -hex 20)
EOF
chmod 600 /srv/wger/.env
umask 022
ls -l /srv/wger/.env
```

The fourth is the RSA keypair that signs API tokens, in the shape only wger makes. It pulls the
image, so allow a few minutes:

```bash
docker run --rm wger/server:2.6.0@sha256:e7f58e15d380d8f5edc055c8a1ed11199e7eb5649138670703401b0c9c407c01 python3 manage.py generate-jwt-keys | grep -E '^JWT_(PRIVATE|PUBLIC)_KEY=' >> /srv/wger/.env
grep -c '^JWT_' /srv/wger/.env
```

Assert: mode `-rw-------`, and that prints `2`. Upstream ships a default keypair in its public
repository and says to replace it.

## 4. compose.yml

```bash
cat > /srv/wger/compose.yml <<'EOF'
# wger · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install ... https://wger.readthedocs.io/en/latest/installation/docker.html
#   settings .. https://wger.readthedocs.io/en/latest/administration/settings.html
#   static .... https://wger.readthedocs.io/en/latest/administration/errors.html
#
# Four services. Django serves none of its own static files in production, so
# nginx reads the directory collectstatic writes into, and nginx alone
# publishes a host port. Two services upstream ships are absent on purpose:
# the celery worker and beat scheduler, marked optional on its architecture
# page, and PowerSync, which costs the phone app its sync. Digests read
# 2026-08-06, all four publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:15.18-alpine@sha256:3d0f7584ed7d04e27fa050d6683a74746608faf21f202be78460d679cc56461f
    restart: unless-stopped
    environment:
      POSTGRES_DB: wger
      POSTGRES_USER: wger
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: UTC
    volumes:
      - /srv/wger/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U wger -d wger"]
      interval: 10s
      retries: 12

  cache:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    command: ["redis-server", "--save", "", "--appendonly", "no"]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 10s
      retries: 12

  web:
    image: wger/server:2.6.0@sha256:e7f58e15d380d8f5edc055c8a1ed11199e7eb5649138670703401b0c9c407c01
    restart: unless-stopped
    env_file: /srv/wger/.env
    environment:
      DJANGO_DB_ENGINE: django.db.backends.postgresql
      DJANGO_DB_DATABASE: wger
      DJANGO_DB_USER: wger
      DJANGO_DB_PASSWORD: ${POSTGRES_PASSWORD}
      DJANGO_DB_HOST: db
      DJANGO_DB_PORT: 5432
      DJANGO_CACHE_BACKEND: django_redis.cache.RedisCache
      DJANGO_CACHE_LOCATION: redis://cache:6379/1
      DJANGO_CACHE_CLIENT_CLASS: django_redis.client.DefaultClient
      # Caddy terminates TLS, nginx states the scheme, and two proxies stand
      # between a visitor and gunicorn.
      X_FORWARDED_PROTO_HEADER_SET: "True"
      NUMBER_OF_PROXIES: "2"
      AXES_IPWARE_PROXY_COUNT: "2"
      AXES_IPWARE_META_PRECEDENCE_ORDER: HTTP_X_FORWARDED_FOR,REMOTE_ADDR
      ALLOW_REGISTRATION: "False"
      ALLOW_GUEST_USERS: "False"
      USE_CELERY: "False"
      DJANGO_CLEAR_STATIC_FIRST: "False"
      WGER_USE_GUNICORN: "True"
    volumes:
      - /srv/wger/static:/home/wger/static
      - /srv/wger/media:/home/wger/media
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:8000/api/v2/version/"]
      interval: 15s
      timeout: 10s
      retries: 40
      # A first start migrates and collects static files, so allow minutes.
      start_period: 300s
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_healthy

  nginx:
    image: nginx:1.30.4-alpine@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46
    restart: unless-stopped
    configs:
      - source: wger-nginx
        target: /etc/nginx/conf.d/default.conf
    volumes:
      - /srv/wger/static:/wger/static:ro
      - /srv/wger/media:/wger/media:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8147.
      - "127.0.0.1:8147:80"
    depends_on:
      web:
        condition: service_started

configs:
  wger-nginx:
    content: |
      # A doubled dollar sign is how compose escapes the one nginx wants.
      server {
        listen 80;
        client_max_body_size 100M;

        location /static/ { alias /wger/static/; }
        location /media/ { alias /wger/media/; }

        location / {
          proxy_pass http://web:8000;
          proxy_http_version 1.1;
          proxy_set_header Host $$http_host;
          proxy_set_header X-Forwarded-For $$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto https;
        }
      }
EOF
cd /srv/wger && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`.

## 5. Caddy and TLS

Append the block below, with `<DOMAIN>` replaced by the real hostname, to the Caddyfile Prompt
Zero installed. Copy it first: a syntax error takes down every site here.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-wger
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# wger · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://wger.readthedocs.io/en/latest/installation/docker.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also SITE_URL and CSRF_TRUSTED_ORIGINS in .env: Django refuses a form post
# from an origin nobody told it about, so all three have to agree. This block
# proxies everything and serves nothing; nginx inside the stack has the static
# and media files.

<DOMAIN> {
	# HSTS because there is a login form on every path.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "same-origin"
		-Server
	}

	# 8147 is the loopback port compose publishes and nginx answers on. It is
	# not a container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8147
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-wger, reload, and
report the objection. Caddy asks for the certificate on the first request and renews it alone.

## 6. Firewall

Two ports open, both Caddy's, and idempotent:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3. 8147 is bound
to loopback and 5432 and 6379 are never published, so none of the three belongs here. Assert:
`Status: active`, rules for 80, 443/tcp and 443/udp, nothing for 8147, 5432 or 6379.

## 7. Start and verify

```bash
cd /srv/wger
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v2/version/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v2/version/
```

Assert: the loop ends printing `200` and the last line prints `"2.6.0"`, quotes included.

The image creates an `admin` account whose password upstream publishes in its install guide.
Give it the one step 3 made and prove the published one is dead, printing neither:

```bash
docker compose exec -T web python3 manage.py shell -c "import os;from django.contrib.auth.models import User;u=User.objects.get(username='admin');u.set_password(os.environ['WGER_ADMIN_PASSWORD']);u.save();u.refresh_from_db();print('default rejected' if not u.check_password('adminadmin') else 'DEFAULT STILL ACCEPTED')"
```

Assert: `default rejected`. On `DEFAULT STILL ACCEPTED`, stop: this box is on the internet with
a credential anyone can look up.

Now load a food database and check the path end to end:

```bash
docker compose exec -T web wger load-online-fixtures
curl -sS 'https://<DOMAIN>/api/v2/ingredient/?limit=1' | head -c 100
curl -sS https://<DOMAIN>/en/user/login > /tmp/wger-login.html
grep -o '<h2 class="mb-1">Login</h2>' /tmp/wger-login.html; grep -c 'user/registration' /tmp/wger-login.html
asset=$(grep -oE '/static/[^"]+\.css' /tmp/wger-login.html | head -1); curl -sS -o /dev/null -w "$asset %{http_code}\n" "https://<DOMAIN>$asset"
```

Assert all four, printing what you got for each: an ingredient count above zero;
`<h2 class="mb-1">Login</h2>`, the first screen a human sees; `0` from the registration grep,
so signup is closed and this instance has one account; a `/static/` path and `200`, where a
`404` means an unstyled site and step 2 at fault. If any of the four misses, stop, run
`docker compose logs --tail 40 web`, then `docker compose logs --tail 20 nginx`, and name the
step. A running container is not success.

STOP: tell the user to read their password with `grep WGER_ADMIN_PASSWORD /srv/wger/.env`, put
it in their password manager, and log in at https://<DOMAIN>/en/user/login as `admin`.
Do not continue until they confirm the dashboard loaded.

## 8. First backup and restore

PostgreSQL holds every workout and every meal; the config archive holds what rebuilds the
service around it.

```bash
cd /srv/wger
docker compose exec -T db pg_dump -U wger -d wger | gzip > /srv/wger/backups/wger-db-$(date +%F).sql.gz
sudo tar -czf /srv/wger/backups/wger-config-$(date +%F).tar.gz -C /srv/wger compose.yml .env media -C /etc/caddy Caddyfile
ls -lh /srv/wger/backups/
```

Assert: both files exist, both are non-empty, print both sizes. The dump runs live because
`pg_dump` takes a consistent snapshot. Static files are in neither archive: upstream rebuilds
them on each start.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/wger
scp vps:/srv/wger/backups/* ~/backups/wger/
```

To restore: `docker compose down`, `sudo rm -rf /srv/wger/postgres`, recreate it as in step 2,
`docker compose up -d db`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db psql -U wger -d wger`, untar the config archive into /srv/wger, then
`docker compose up -d`. Most of that dump is the ingredient table; the workouts and the diary
are what nobody can fetch again.

## 9. Updating later

New versions are listed at https://github.com/wger-project/wger/releases. Take both backups
first, then edit the `wger/server` image line in /srv/wger/compose.yml to the new tag and
digest:

```bash
cd /srv/wger
docker compose pull
docker compose up -d
docker compose logs --tail 30 web
```

wger migrates its own database on the way up, so watch that log until it settles, then re-run
step 7's checks. If the interface comes back half-styled, set `DJANGO_CLEAR_STATIC_FIRST` to
`True` for one restart.

## 10. What will probably go wrong

For the first several minutes https://<DOMAIN> answers `502` and reads like a failed install. I
sat through it twice before I believed it: on an empty database that container migrates, loads
the exercise fixtures and processes every static file before gunicorn binds a port, and
upstream's own health check allows five minutes for it. nginx is up and answering the whole
time, which is what makes it read as broken rather than slow. Run `docker compose logs -f web`
and wait for the line about gunicorn on port 8000 before doubting anything.

## 11. Out of scope

- Do not add the PowerSync service, though upstream's compose file has one. It wants logical
  replication, its own database role, sync-rule files this install does not carry, and a
  compaction job on a schedule. Without it the phone app logs in and then says sync is
  unavailable: the trade this install makes.
- Do not add the celery worker or the beat scheduler. Upstream marks both optional and the
  application does that work synchronously without them.
- Do not run `sync-ingredients-bulk` here. Upstream sizes the full ingredient dataset at around
  1 GB of database and hours of work: the user's decision, later.
- Do not configure SMTP. Nothing here needs mail, and on a one-account instance the password
  reset is a file on the server.
