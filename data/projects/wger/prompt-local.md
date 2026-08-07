You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install wger 2.6.0, with the PostgreSQL it keeps workouts and food in, under ~/selfhost/wger,
answering at http://localhost:8147.

## 1. Preflight

Say this before step 2 runs. wger answers at http://localhost:8147, which means this computer
and nowhere else, so the phone they would log lunch on cannot reach it: every meal and every
set gets typed here, while this machine is awake.

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. These four containers want 2048 MB of RAM
available and 10 GB free on the home disk, and all four images publish amd64 and arm64. Under
either floor, print the numbers and stop, do not install and hope.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version of 2.23 or newer, skip to step 3: step 5's
file has an inline nginx config older versions cannot read.

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

```bash
mkdir -p ~/selfhost/wger/backups ~/selfhost/wger/static ~/selfhost/wger/media
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "1000" ]; then sudo chown -R 1000:1000 ~/selfhost/wger/static ~/selfhost/wger/media; fi
ls -la ~/selfhost/wger
```

Assert: all three exist. The image runs as uid 1000 and writes its CSS into `static`, which
upstream requires to be owned by 1000:1000 and readable by everyone: that is the Linux-only
fence, and on macOS and Windows Docker Desktop owns it. Workouts and food are in a Docker
volume, so there is no `data` folder.

## 4. Secrets

Four secrets, all generated here. Print none of them, and keep them out of your summary and any
log line.

```bash
umask 077
cat > ~/selfhost/wger/.env <<EOF
SITE_URL=http://localhost:8147
CSRF_TRUSTED_ORIGINS=http://localhost:8147
TIME_ZONE=UTC
TZ=UTC
SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
WGER_ADMIN_PASSWORD=$(openssl rand -hex 20)
EOF
chmod 600 ~/selfhost/wger/.env
umask 022
ls -l ~/selfhost/wger/.env
```

Git Bash ships openssl. On Windows the mode bits are advisory and the boundary is the user's
own account. The fourth secret is the RSA keypair signing API tokens, and it pulls the image:

```bash
docker run --rm wger/server:2.6.0@sha256:e7f58e15d380d8f5edc055c8a1ed11199e7eb5649138670703401b0c9c407c01 python3 manage.py generate-jwt-keys | grep -E '^JWT_(PRIVATE|PUBLIC)_KEY=' >> ~/selfhost/wger/.env
grep -c '^JWT_' ~/selfhost/wger/.env
```

Assert: mode `-rw-------` and that prints `2`.

## 5. compose.yml

```bash
cat > ~/selfhost/wger/compose.yml <<'EOF'
# wger · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a
# repository:
#   install ... https://wger.readthedocs.io/en/latest/installation/docker.html
#   settings .. https://wger.readthedocs.io/en/latest/administration/settings.html
#   static .... https://wger.readthedocs.io/en/latest/administration/errors.html
#
# Four services, every path relative to ~/selfhost/wger/ so one file works on
# macOS, Linux and Windows. The database is a named volume because PostgreSQL
# chowns its data directory to a uid a home bind mount cannot grant on
# Windows. nginx is here because Django serves no static files itself; the
# celery worker, beat scheduler and PowerSync upstream ships are not, which
# costs the weekly sync and the phone app. Digests read 2026-08-06, amd64 and
# arm64.
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
      - wger-pgdata:/var/lib/postgresql/data
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
    env_file: ./.env
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
      NUMBER_OF_PROXIES: "1"
      ALLOW_REGISTRATION: "False"
      ALLOW_GUEST_USERS: "False"
      USE_CELERY: "False"
      DJANGO_CLEAR_STATIC_FIRST: "False"
      WGER_USE_GUNICORN: "True"
    volumes:
      - ./static:/home/wger/static
      - ./media:/home/wger/media
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
      - ./static:/wger/static:ro
      - ./media:/wger/media:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8147.
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
          proxy_set_header X-Forwarded-Proto http;
        }
      }

volumes:
  wger-pgdata:
EOF
cd ~/selfhost/wger && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Four services, one published port, one named volume.

## 6. Nothing is public

No hostname, so no DNS. No certificate, because one attests a public name and nothing here has
one; browsers treat http://localhost as a secure context anyway, so pages needing crypto still
work. No firewall rule, because nothing is published past loopback. nginx holds 8147 on
127.0.0.1 only because Django serves none of its own static files, and this computer is the
only thing that reaches it. Not the user's phone, not a laptop on the wifi, nobody at all.

```bash
grep -c '"127.0.0.1:' ~/selfhost/wger/compose.yml
```

Assert: `1`, the nginx line `- "127.0.0.1:8147:80"`. PostgreSQL, Redis and gunicorn publish no
host port at all.

## 7. Start and verify

```bash
cd ~/selfhost/wger
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8147/api/v2/version/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8147/api/v2/version/
```

Assert: the loop ends on `200` and the last line prints `"2.6.0"`, quotes included. It is slow
because the container migrates and processes every static file before gunicorn answers. The
image also makes an `admin` account whose password upstream publishes; give it the one step 4
made and prove the published one is dead, printing neither:

```bash
docker compose exec -T web python3 manage.py shell -c "import os;from django.contrib.auth.models import User;u=User.objects.get(username='admin');u.set_password(os.environ['WGER_ADMIN_PASSWORD']);u.save();u.refresh_from_db();print('default rejected' if not u.check_password('adminadmin') else 'DEFAULT STILL ACCEPTED')"
```

Assert: `default rejected`. Anything else, stop. Now load a food database and check the path end
to end:

```bash
docker compose exec -T web wger load-online-fixtures
curl -sS 'http://localhost:8147/api/v2/ingredient/?limit=1' | head -c 100
curl -sS http://localhost:8147/en/user/login > /tmp/wger-login.html
grep -o '<h2 class="mb-1">Login</h2>' /tmp/wger-login.html; grep -c 'user/registration' /tmp/wger-login.html
asset=$(grep -oE '/static/[^"]+\.css' /tmp/wger-login.html | head -1); curl -sS -o /dev/null -w "$asset %{http_code}\n" "http://localhost:8147$asset"
```

Assert all four, printing what you got: an ingredient count above zero;
`<h2 class="mb-1">Login</h2>`, the first screen a human sees; `0` from the registration grep, so
signup is closed and this install has one account; a `/static/` path and `200`, where a `404`
means an unstyled site and step 3 at fault. If any misses, stop, run
`docker compose logs --tail 40 web` and `docker compose logs --tail 20 nginx`, and name the
step. On `port is already allocated`, find what holds 8147 with `lsof -nP -iTCP:8147`. A
running container is not success.

STOP: tell the user to read their password with `grep WGER_ADMIN_PASSWORD ~/selfhost/wger/.env`,
put it in their password manager, and log in at http://localhost:8147/en/user/login as `admin`.
Do not continue until they confirm the dashboard loaded.

## 8. First backup and restore

```bash
cd ~/selfhost/wger
docker compose exec -T db pg_dump -U wger -d wger | gzip > ~/selfhost/wger/backups/wger-db-$(date +%F).sql.gz
tar -C ~/selfhost/wger -czf ~/selfhost/wger/backups/wger-config-$(date +%F).tar.gz compose.yml .env media
ls -lh ~/selfhost/wger/backups/
```

Assert: both files exist, both are non-empty, print both sizes. Nothing stops: `pg_dump` takes
a consistent snapshot, and static files are rebuilt on each start.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination off this computer, a sync folder
or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is written
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both files are there.

To restore: `cd ~/selfhost/wger`, untar the config archive first, so .env is back before any
container starts and PostgreSQL can read `POSTGRES_PASSWORD` as it initialises an empty volume.
Then `docker compose down -v`, the one place `-v` belongs because it drops the old volume on
purpose, `docker compose up -d db`, wait 30 seconds for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T db psql -U wger -d wger`, then `docker compose up -d`
and check a workout is there.

## 9. Updating later

New versions are listed at https://github.com/wger-project/wger/releases. Take both backups
first, then edit the `wger/server` image line in ~/selfhost/wger/compose.yml to the new tag and
its digest:

```bash
cd ~/selfhost/wger
docker compose pull
docker compose up -d
docker compose logs --tail 30 web
```

Watch it until the migrations settle, then re-run step 7's checks.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8147 to log breakfast, and got a connection error that
reads like a lost database. It was not: Docker Desktop had not started with the session, so
nothing was listening on 8147. `restart: unless-stopped` acts only once the Docker daemon is
up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/wger && docker compose up -d` and wait a minute before concluding.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8147 to 0.0.0.0 so a phone on the wifi can reach it. That puts a login form on
  every network this computer joins.
- Do not add PowerSync, the celery worker or the beat scheduler. Upstream marks the last two
  optional, and the first only feeds a phone app that cannot reach this machine anyway.
- Do not run `sync-ingredients-bulk` here. Upstream sizes the full dataset at around 1 GB of
  database and hours of work, too much to ask of a laptop.
