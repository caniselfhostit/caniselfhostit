You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install OpnForm 2.3.0, with the PostgreSQL, Redis and nginx ingress it needs, under
~/selfhost/opnform, answering at http://localhost:8186.

## 1. Preflight

Say this before step 2 runs, because it decides whether the user wants this install at all. Every
form is published at http://localhost:8186/forms/ and a slug, and that address means "this
computer" wherever it is read, so a link sent to a colleague, or opened on the user's own phone,
reaches nothing. What they get is a builder and an inbox they fill in themselves.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the ID
and codename print next, for step 2. Seven containers with three PHP processes want 4096 MB
available and 20 GB free on the home disk; all five images publish amd64 and arm64. On macOS and
Windows, Docker Desktop takes its allocation out of that figure, so check its resource slider
reads 4 GB or more. Under either floor, print both numbers and stop.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they
  confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

Write the ingress config before anything starts: Docker makes a directory where a missing
bind-mount file should be, and nginx refuses a config that is a folder.

```bash
mkdir -p ~/selfhost/opnform/nginx ~/selfhost/opnform/backups
cat > ~/selfhost/opnform/nginx/default.conf <<'EOF'
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
ls -la ~/selfhost/opnform ~/selfhost/opnform/nginx
```

Assert: `nginx` and `backups` are listed, and `default.conf` is a file rather than a directory.
PostgreSQL, Redis and the API storage tree each chown their data to a uid of their own, so step 5
keeps all three in named volumes Docker manages.

## 4. Secrets

Five, all generated here, none printed and none in your summary or a log line: the Laravel
application key, the JWT signing key, the Nuxt-to-API shared secret, the
PostgreSQL password and the Redis password. `APP_KEY` is `base64:` plus 32 random bytes
(Laravel's own shape); the rest are hex, because two travel inside connection strings. Git Bash
ships openssl, so these lines run the same everywhere.

```bash
umask 077
cat > ~/selfhost/opnform/.env <<EOF
APP_KEY=base64:$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -hex 32)
FRONT_API_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/opnform/.env
umask 022
ls -l ~/selfhost/opnform/.env
```

Assert: mode `-rw-------`. Compose reads this file for the `${...}` slots in step 5 and the three
PHP containers read it as their environment. `APP_KEY` is what Laravel encrypts with, so rotating
it makes that data unreadable. On Windows those mode bits are advisory; the real boundary is the
user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/opnform/compose.yml <<'EOF'
# OpnForm · the deterministic fallback for the local path. Authored by
# caniselfhostit from https://docs.opnform.com/deployment/docker,
# https://docs.opnform.com/configuration/environment-variables and
# https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker-compose.yml
#
# Seven services on the computer you are sitting at, upstream's own shape. The
# api image is php-fpm on 9000, so the nginx ingress marries FastCGI to the
# Nuxt client under one origin and is the only service with a published port.
# api, worker and scheduler are one image under three commands, and the queue
# is where an ordinary submission is written. The ingress config is a relative
# bind mount so you can open it in Finder or Explorer; the data lives in named
# volumes, because each of those images chowns its own directory to a uid a
# home bind mount cannot grant on Windows. Digests read 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

x-api: &api
  image: jhumanj/opnform-api:2.3.0@sha256:4b71e200d420c7cd2f3bbc7d8d9431de922c5edb8e49a7679c2d09c858fa7329
  restart: unless-stopped
  env_file: ./.env
  environment:
    APP_ENV: production
    APP_DEBUG: "false"
    SELF_HOSTED: "true"
    APP_URL: http://localhost:8186
    FRONT_URL: http://localhost:8186
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
    # No SMTP, so mail lands in the container log rather than nowhere.
    MAIL_MAILER: log
    # Upstream's setup script refuses a production deploy with this true.
    JWT_SKIP_IP_UA_VALIDATION: "false"
    # Docker's bridge range, so Laravel reads the address the ingress
    # forwarded rather than the ingress container's own. Never "*".
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
      NUXT_PUBLIC_APP_URL: http://localhost:8186
      NUXT_PUBLIC_API_BASE: http://localhost:8186/api
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
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      api: {condition: service_healthy}
      client: {condition: service_started}
    ports:
      # Loopback only: no other device on the wifi can reach 8186.
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
cd ~/selfhost/opnform && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Seven services, one published port, three named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname to
resolve, nothing public to certify, nothing published past loopback to close, and browsers treat
http://localhost as a secure context, so pages that need crypto still work.

8186 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on the
internet. For a form builder that is the whole trade, because nobody else can answer the forms
either. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/opnform/compose.yml
```

Assert: `1`, the published-port line on the ingress. Neither database publishes a host port, the
api speaks FastCGI only on the compose network, and the client is reachable only through the
ingress.

## 7. Start and verify

First boot is slow on purpose: the api container waits for PostgreSQL, runs every migration and
caches its config, and the other four wait for it to be healthy. Five minutes is normal, longer on
a laptop pulling five images for the first time.

```bash
cd ~/selfhost/opnform
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8186/api/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8186/api/healthcheck
curl -sS http://localhost:8186/api/content/feature-flags | grep -o '"setup_required":true'
curl -sSL http://localhost:8186/ | grep -c 'Create your admin account'
docker compose ps
```

Assert all five, printing what you got: the loop ends on `200`; health returns
`{"status":"ok","dependencies":{"database":true,"redis":true}}`; the third prints
`"setup_required":true`; the grep prints at least `1` (no account yet, so every path redirects to setup); `ps` shows seven services and no restart loop. If any misses, stop,
run
`docker compose logs --tail 60 api ingress` and name the step to blame: `host not found in upstream`
is the ingress starting before the client, fixed by `docker compose up -d ingress` again, and
`port is already allocated` means something else holds 8186 (`lsof -nP -iTCP:8186 -sTCP:LISTEN`,
`ss -ltnp | grep 8186` on Linux, `netstat -ano | findstr :8186` on Windows). A running container is
not success.

STOP: tell the user to open http://localhost:8186, create their admin account, and confirm once
they are signed in on their workspace. Do not continue until they confirm. No confirmation mail
arrives, this install has no mail server, so have them save the password in a manager first. This
account cannot be made twice: OpnForm refuses registration permanently once one account exists.

Then prove the door shut:

```bash
curl -sS http://localhost:8186/api/content/feature-flags | grep -o '"setup_required":false'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8186/setup
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8186/register
```

Assert: `"setup_required":false`, then `404`, then `302`. Nothing here configured that: upstream's
controller refuses registration for anyone without an invitation once any user exists, so all three
flip together. A `200` from `/setup` means the account was not created, so go back to the STOP. It
matters even on loopback, because step 11 names the one router setting that would expose it.

## 8. First backup and restore

Three artifacts: the database with every form, submission and account; the storage archive with
the attachments a dump does not contain; the config archive that rebuilds the service around both.

```bash
cd ~/selfhost/opnform
docker compose exec -T db pg_dump -U opnform -d opnform | gzip > ~/selfhost/opnform/backups/opnform-db-$(date +%F).sql.gz
docker compose exec -T api tar -czf - -C /usr/share/nginx/html storage > ~/selfhost/opnform/backups/opnform-storage-$(date +%F).tar.gz
tar -C ~/selfhost/opnform -czf ~/selfhost/opnform/backups/opnform-config-$(date +%F).tar.gz compose.yml .env nginx
ls -lh ~/selfhost/opnform/backups/
```

Assert: all three exist, all three non-empty, print all three sizes. Nothing stops, because
`pg_dump` snapshots a running database consistently. Redis is not in the backup: cache and queue,
not data, so a submission still queued when this ran is not in it either.

All three sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a sync folder or a
USB stick, and copy all three there with `cp`. In Git Bash a Windows drive is written `/d/Backups`,
not `D:\Backups`; confirm it exists first. Assert: the user confirms all three filenames are there,
or say plainly that this install has no backup.

To restore, in this order, because the api migrates the moment it reaches a database: untar the
config archive into ~/selfhost/opnform so compose.yml and .env are back first, `docker compose down
-v`, the one place `-v` belongs, `docker compose up -d db redis`, wait for healthy, pipe `gunzip -c`
on the `.sql.gz` into `docker compose exec -T db psql -U opnform -d opnform`, `docker compose up
-d`, wait for step 7's health check, then pipe `gunzip -c` on the storage archive into
`docker compose exec -T api tar -xzf - -C /usr/share/nginx/html`. Every answer anyone ever sent
them is a row in that dump.

## 9. Updating later

Releases: https://github.com/OpnForm/OpnForm/releases. Release tag `v2.3.0` = image tag `2.3.0`,
the digits without the `v`. Take all three backups first, then edit the `jhumanj/opnform-api`
line in the `x-api` block and the `jhumanj/opnform-client` line to the new tag and digest. Both
move together: a client built against a different API is the failure that looks like a broken
login.

```bash
cd ~/selfhost/opnform
docker compose pull
docker compose up -d
docker compose logs --tail 40 api
docker compose restart ingress
```

That last line is not optional; step 10 says why. OpnForm migrates on the way up, so watch the api
log until it settles, then re-run step 7's health check. Leave postgres and redis alone: a database
major is a separate migration with its own restore.

## 10. What will probably go wrong

Nothing, for about six minutes, and it will look exactly like a failure. On the first `up -d` I
watched `docker compose ps` show six containers waiting while the api sat there, and
http://localhost:8186 refused the connection the whole time. That is the design: the api runs every
migration and caches its configuration before it answers a health check at all, and the ingress will
not start until it does, which is why step 7 has a loop to read. The other half is Docker Desktop,
which does not start with the session unless told to, so after a reboot the same connection refused
means nothing is running. Turn on start-at-login, and after any reboot run
`cd ~/selfhost/opnform && docker compose up -d` before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8186 to 0.0.0.0 so a phone on the wifi can load a form, and do not point `APP_URL`,
  `FRONT_URL` or `NUXT_PUBLIC_APP_URL` at this machine's LAN address. Those values have to agree,
  and together they put a form builder on every network this laptop joins.
- Do not configure SMTP, and do not set `OPEN_AI_API_KEY`, the hCaptcha or reCAPTCHA keys,
  `GOOGLE_CLIENT_ID` or the `AWS_` variables. Each is an account somewhere else and a second
  failure mode; everything core works without them.
- Do not activate a self-hosted Enterprise licence and do not set `CUSTOM_CODE_ENABLE_SELF_HOSTED`.
  The first is a purchase the user makes, the second turns user-supplied code loose in a page.
