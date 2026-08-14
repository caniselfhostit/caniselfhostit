You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install OpnForm 2.3.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer. Its
A record must already point here. Say why it is final: every form is that hostname plus `/forms/`
and a slug, so changing it breaks links already in other people's inboxes.

Seven containers: the Laravel API, a queue worker and a scheduler on one image, the Nuxt client,
PostgreSQL, Redis and the nginx ingress. 4096 MB available, 20 GB free on /srv, amd64 or
arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

Under either floor, or with empty `dig` output, print what you got and stop: three 1 GB PHP
processes plus Node and PostgreSQL is OOM territory, and Caddy cannot certify a name that does
not resolve; its failed attempts count against a hidden rate limit.

## 2. Layout

Write the ingress config before anything starts: Docker makes a directory where a missing
bind-mount file should be, and nginx refuses a config that is a folder.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/opnform /srv/opnform/backups /srv/opnform/nginx
cat > /srv/opnform/nginx/default.conf <<'EOF'
# OpnForm · the ingress, authored by caniselfhostit from
# https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker/nginx.conf
# The map strips /api before PHP sees it, since Laravel's routes are at the
# root; `root` is a path inside the api container and only builds
# SCRIPT_FILENAME, so nothing static is served from this one.

map $request_uri $api_uri {
    ~^/api(/.*$) $1;
    default $request_uri;
}

server {
    listen 80;
    root /usr/share/nginx/html/public;
    client_max_body_size 50m;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://client:3000;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
    }

    location ~/(api|open|local\/temp|forms\/assets)/ {
        try_files $uri /index.php$is_args$args;
    }

    location ~ \.php$ {
        fastcgi_pass api:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_param REQUEST_URI $api_uri;
        fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
    }
}
EOF
ls -la /srv/opnform/nginx
```

Assert: `default.conf` is a file, not a directory. PostgreSQL, Redis and the API storage tree
each chown their data, so all three live in named volumes that step 8
dumps rather than copies.

## 3. Secrets

Five, all generated here, none printed and none in your summary or a log line: the Laravel
application key, the JWT signing key, the Nuxt-to-API shared secret, the
PostgreSQL password and the Redis password. `APP_KEY` is `base64:` plus 32 random bytes
(Laravel's own shape); the rest are hex, because two travel inside connection strings.

```bash
umask 077
cat > /srv/opnform/.env <<EOF
APP_URL=https://<DOMAIN>
FRONT_URL=https://<DOMAIN>
APP_KEY=base64:$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -hex 32)
FRONT_API_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/opnform/.env
umask 022
ls -l /srv/opnform/.env
```

Put the real hostname on the first two lines before running this. Assert: mode `-rw-------`.
Compose reads this file for the `${...}` slots in step 4 and the three PHP containers read it as
their environment. Tell the user `APP_KEY` is what Laravel encrypts with, rotating it makes that
data unreadable, and they read values themselves with `sudo grep JWT_SECRET /srv/opnform/.env`.

## 4. compose.yml

```bash
cat > /srv/opnform/compose.yml <<'EOF'
# OpnForm · the deterministic fallback. Authored by caniselfhostit from
# https://docs.opnform.com/deployment/docker,
# https://docs.opnform.com/configuration/environment-variables and
# https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker-compose.yml
#
# Seven services, upstream's own shape. The api image is php-fpm on 9000, so
# the nginx ingress speaks FastCGI to it and proxies the rest to the Nuxt
# client under one origin; the host's Caddy fronts that on 8186. api, worker
# and scheduler are one image under three commands, and the queue is not
# optional: an ordinary submission is dispatched to it, not written during the
# request. Digests read from Docker Hub on 2026-08-14; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

x-api: &api
  image: jhumanj/opnform-api:2.3.0@sha256:4b71e200d420c7cd2f3bbc7d8d9431de922c5edb8e49a7679c2d09c858fa7329
  restart: unless-stopped
  env_file: /srv/opnform/.env
  environment:
    APP_ENV: production
    APP_DEBUG: "false"
    SELF_HOSTED: "true"
    LOG_CHANNEL: errorlog
    LOG_LEVEL: warning
    DB_CONNECTION: pgsql
    DB_HOST: db
    DB_DATABASE: opnform
    DB_USERNAME: opnform
    REDIS_HOST: redis
    CACHE_DRIVER: redis
    QUEUE_CONNECTION: redis
    SESSION_DRIVER: redis
    LOCAL_FILESYSTEM_VISIBILITY: public
    # Mail to the container log, not nowhere. Upstream's setup script refuses
    # a production deploy with JWT validation skipped. The bridge range lets
    # Laravel read the forwarded visitor address; never "*".
    MAIL_MAILER: log
    JWT_SKIP_IP_UA_VALIDATION: "false"
    TRUSTED_PROXIES: 172.16.0.0/12
    OPNFORM_ANONYMOUS_TELEMETRY_DISABLED: "true"
  volumes:
    - opnform-storage:/usr/share/nginx/html/storage

services:
  db:
    image: postgres:16.15-alpine@sha256:ab5c955e9e57ae9879d4411ab49a912be9d162455676f7bf56e951b11ac73785
    restart: unless-stopped
    environment:
      POSTGRES_DB: opnform
      POSTGRES_USER: opnform
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - opnform-postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U opnform -d opnform"]
      interval: 10s
      retries: 30

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"$$REDIS_PASSWORD\""]
    volumes:
      - opnform-redis:/data
    healthcheck:
      test: ["CMD-SHELL", 'redis-cli -a "$$REDIS_PASSWORD" --no-auth-warning ping | grep -q PONG']
      interval: 10s
      retries: 30

  api:
    <<: *api
    depends_on:
      db: {condition: service_healthy}
      redis: {condition: service_healthy}
    healthcheck:
      test: ["CMD-SHELL", "php /usr/share/nginx/html/artisan about || exit 1"]
      interval: 30s
      timeout: 15s
      retries: 5
      # Long: it migrates before it answers, and the other four wait here.
      start_period: 300s

  worker:
    <<: *api
    command: ["php", "artisan", "queue:work"]
    depends_on:
      api: {condition: service_healthy}

  scheduler:
    <<: *api
    command: ["php", "artisan", "schedule:work"]
    depends_on:
      api: {condition: service_healthy}

  client:
    image: jhumanj/opnform-client:2.3.0@sha256:1b46bef02db59525e21c9e403805c50839af8c257883430702f1157c6946c1c8
    restart: unless-stopped
    environment:
      NUXT_PUBLIC_APP_URL: ${APP_URL}
      NUXT_PUBLIC_API_BASE: ${APP_URL}/api
      # Rendering on the server goes back through the ingress: Node cannot
      # speak FastCGI. NUXT_API_SECRET is FRONT_API_SECRET renamed.
      NUXT_PRIVATE_API_BASE: http://ingress/api
      NUXT_API_SECRET: ${FRONT_API_SECRET}
      NUXT_PUBLIC_ENV: production
    depends_on:
      api: {condition: service_healthy}

  ingress:
    image: nginx:1.30.4-alpine@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46
    restart: unless-stopped
    volumes:
      - /srv/opnform/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      api: {condition: service_healthy}
      client: {condition: service_started}
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8186.
      - "127.0.0.1:8186:80"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/api/healthcheck || exit 1"]
      interval: 30s
      retries: 5
      start_period: 30s

volumes:
  opnform-postgres:
  opnform-redis:
  opnform-storage:
EOF
cd /srv/opnform && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. A complaint that `/srv/opnform/.env` is missing means step 3 did not run.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a syntax
error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-opnform
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# OpnForm · the Caddy site block for this service. Authored by caniselfhostit
# from https://docs.opnform.com/deployment/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is APP_URL, FRONT_URL and
# NUXT_PUBLIC_APP_URL at once, and every form link is it plus /forms/ and a
# slug, so it is the one value here you cannot change your mind about later.

<DOMAIN> {
	# No X-Frame-Options on purpose: OpnForm ships an embed script, so a form
	# is meant to run inside somebody else's page.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# Matches the ingress and the api image's own 50M PHP upload ceiling.
	request_body {
		max_size 50MB
	}

	# 8186 is the loopback port compose publishes for the nginx ingress: not a
	# container port, and not open in the firewall. TRUSTED_PROXIES is what
	# lets Laravel believe the X-Forwarded-For and -Proto that Caddy sends.
	reverse_proxy 127.0.0.1:8186
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-opnform, reload, and
report what it objected to.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3; 8186 is on
127.0.0.1, and 5432, 6379, 9000 and 3000 have no host port. Assert: `Status: active`,
those three rules, and nothing mentioning 8186.

## 7. Start and verify

First boot is slow on purpose: the api waits for PostgreSQL, runs every migration and
caches its config, and the other four wait for it to be healthy. Five minutes is normal.

```bash
cd /srv/opnform
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/healthcheck
curl -sS https://<DOMAIN>/api/content/feature-flags | grep -o '"setup_required":true'
curl -sSL https://<DOMAIN>/ | grep -c 'Create your admin account'
docker compose ps
```

Assert all five, printing what you got: the loop ends on `200`; health returns
`{"status":"ok","dependencies":{"database":true,"redis":true}}`; the third prints
`"setup_required":true`; the grep prints at least `1` (no account yet, so every path redirects to setup); `ps` shows seven services and no restart loop. If any misses, stop,
run `docker compose logs --tail 60 api ingress` and name the step to blame: `host not found in
upstream` is the ingress starting before the client, fixed by `docker compose up -d ingress`
again, and a `502` with healthy containers is a reverse-proxy line not on 8186. A running
container is not success.

Say this to the user before they touch that page. Anybody reaching this hostname right now can
fill in that form and own the instance, and there is no second chance: OpnForm refuses public
registration permanently once one account exists.

STOP: tell the user to open https://<DOMAIN>, create their admin account, and confirm once they
are signed in on their workspace. Do not continue until they confirm. No confirmation mail
arrives, this install has no mail server, so have them save the password in a manager first.

Then prove the door shut:

```bash
curl -sS https://<DOMAIN>/api/content/feature-flags | grep -o '"setup_required":false'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
```

Assert: `"setup_required":false`, then `404`, then `302`. Nothing here configured that: upstream's
own controller refuses registration for anyone without an invitation once any user exists, so all
three flip together. A `200` from `/setup` means the account was not created, so go back to the
STOP. Everyone after this joins by invitation from inside the workspace, and upstream caps a
licence-free instance at two users in total.

## 8. First backup and restore

Three artifacts: the database with every form, submission and account; the storage archive with
the attachments a dump does not contain; the config archive that rebuilds the service around both.

```bash
cd /srv/opnform
docker compose exec -T db pg_dump -U opnform -d opnform | gzip > /srv/opnform/backups/opnform-db-$(date +%F).sql.gz
docker compose exec -T api tar -czf - -C /usr/share/nginx/html storage > /srv/opnform/backups/opnform-storage-$(date +%F).tar.gz
sudo tar -czf /srv/opnform/backups/opnform-config-$(date +%F).tar.gz -C /srv/opnform compose.yml .env nginx -C /etc/caddy Caddyfile
ls -lh /srv/opnform/backups/
```

Assert: all three exist and are non-empty; print the sizes. Nothing stops: `pg_dump` snapshots a
running database consistently. Redis is not backed up (cache and queue, not data), so a
submission still queued when this ran is not in it. A backup on the same disk is not a backup, so
run this from the user's machine:

```bash
mkdir -p ~/backups/opnform
scp vps:/srv/opnform/backups/* ~/backups/opnform/
```

To restore, in this order, because the api migrates the moment it reaches a database: untar the
config archive into /srv/opnform so compose.yml and .env are back first, `docker compose down -v`,
the one place `-v` belongs, `docker compose up -d db redis`, wait for healthy, pipe `gunzip -c` on
the `.sql.gz` into `docker compose exec -T db psql -U opnform -d opnform`, `docker compose up -d`,
wait for step 7's health check, then pipe `gunzip -c` on the storage archive into
`docker compose exec -T api tar -xzf - -C /usr/share/nginx/html`. Say the stakes: every answer
anyone ever sent them is a row in that dump.

## 9. Updating later

Releases: https://github.com/OpnForm/OpnForm/releases. Release tag `v2.3.0` = image tag `2.3.0`,
the digits without the `v`. Take all three backups first, then edit the `jhumanj/opnform-api`
line in the `x-api` block and the `jhumanj/opnform-client` line to the new tag and digest. Both
move together: a client built against a different API is the failure that looks like a broken
login.

```bash
cd /srv/opnform
docker compose pull
docker compose up -d
docker compose logs --tail 40 api
docker compose restart ingress
```

That last line is not optional; step 10 says why. OpnForm migrates on the way up: watch the api
log until it settles, then re-run step 7's health check. Leave postgres and redis alone: a database
major is a separate migration with its own restore.

## 10. What will probably go wrong

The ingress will lie to you. I changed one line in .env, recreated the client the way upstream's
documentation says to, and every page went to `502` while `docker compose ps` showed seven healthy
containers and the api answered its own health check perfectly from inside the network. nginx had
resolved `client:3000` to an address once at start-up and kept it, and the recreated container had
come back on a different one. Nothing says so except the ingress log, which reads `connect()
failed`. Any time you recreate `api` or `client`, run `docker compose restart ingress` straight
after, and read `docker compose logs --tail 20 ingress` before concluding anything else is broken.

## 11. Out of scope

- Do not configure SMTP. Sign-in and submissions work with no mail server, and MAIL_MAILER is
  `log` so nothing is swallowed. Mail buys password reset, verification and response notices, and
  outbound mail from a fresh VPS is a fight for another day.
- Do not set `NUXT_PUBLIC_ROOT_REDIRECT_URL`. The root showing OpnForm's landing page to strangers
  is upstream's default, not a fault; where the bare domain sends them is the user's editorial
  call.
- Do not set `OPEN_AI_API_KEY`, the hCaptcha or reCAPTCHA keys, `GOOGLE_CLIENT_ID` or the `AWS_`
  variables. Each is an account somewhere else and a second failure mode; everything core works
  without them.
- Do not activate a self-hosted Enterprise licence and do not set `CUSTOM_CODE_ENABLE_SELF_HOSTED`.
  The first is a purchase the user makes, the second turns user-supplied code loose in a page that
  strangers load.
