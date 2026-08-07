This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing wger 2.6.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box. wger has to live on a hostname of its own, because upstream states the application does
not work in a subdirectory.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
docker compose version
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, a
compose version of `2.23` or newer, and your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does
not resolve. A compose version below 2.23 is the one that stops you here: step 4's file carries
its nginx configuration inline, which older versions cannot read, and the fix is to install the
compose plugin from download.docker.com rather than the distribution's older package. Under
2048 MB, wger will start and then be killed during the ingredient load in step 7.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wger /srv/wger/backups
sudo install -d -m 700 /srv/wger/postgres
sudo install -d -m 755 -o 1000 -g 1000 /srv/wger/static /srv/wger/media
ls -la /srv/wger
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`static` and `media` at `drwxr-xr-x` owned by `1000`.

If you do not: leave `postgres` owned by root on purpose, because the PostgreSQL image chowns
its own data directory the first time it starts and one you have already chowned makes it
refuse to initialise. The `1000` on the other two is upstream's instruction: the container
writes its processed CSS there as uid 1000, and if that fails you get a site with no styling
and no error message anywhere.

## 3. Secrets

Four secrets, all generated on the server, three of them here and the fourth by wger itself.
Replace `<DOMAIN>` on the first two lines with your hostname before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/wger/.env` and carry
on. If the file already existed from an earlier attempt, this block has now replaced all three
values, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed one produces an authentication error in the wger log
rather than anything mentioning passwords.

Do not paste that file, any of those values, or any command output containing them into this
chat window. The agent path never sees them; a chat window will keep them.

Now the fourth secret, the RSA keypair that signs API tokens. This pulls the image, so give it
a few minutes:

```bash
docker run --rm wger/server:2.6.0@sha256:e7f58e15d380d8f5edc055c8a1ed11199e7eb5649138670703401b0c9c407c01 python3 manage.py generate-jwt-keys | grep -E '^JWT_(PRIVATE|PUBLIC)_KEY=' >> /srv/wger/.env
grep -c '^JWT_' /srv/wger/.env
```

You should see: the image download, then `2`.

If you do not: `0` means the command printed nothing, usually because the image failed to pull;
run it again and watch for the error. Upstream ships a default keypair in its public repository
and says to replace it, which is what this does. The two lines are long base64 blobs, and they
are secrets like the rest of the file.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal; run `rm /srv/wger/compose.yml` and paste again in one go. An error mentioning
`configs` means your compose plugin predates 2.23 and cannot read the inline nginx
configuration. `env file /srv/wger/.env not found` means step 3 did not write the file.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-wger /etc/caddy/Caddyfile`, reload, and
paste again. The hostname in this block, in `SITE_URL` and in `CSRF_TRUSTED_ORIGINS` all have
to be the same string, or the login form returns a CSRF error that says nothing useful about
which of the three is wrong.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8147`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8147`. 8147 is bound
to 127.0.0.1 by the compose file and the database and cache are never published at all, so
there is no host port for a rule to apply to. `Status: inactive` is a different problem:
Prompt Zero left this firewall enabled, so something turned it off, and `sudo ufw enable` puts
it back before you go further.

## 7. Start and verify

The first start is slow. The web container migrates the database, loads the exercise fixtures,
creates its admin account and processes every static file before gunicorn answers anything.

```bash
cd /srv/wger
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v2/version/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v2/version/
```

You should see: the loop printing `502` for several minutes and then `200`, and the last
command printing `"2.6.0"` with the quotes.

If you do not: run `docker compose logs --tail 40 web`. `connection refused` from the database
means it never became healthy, which points back at step 2. A `502` that never clears after
fifteen minutes usually means collectstatic failed on the ownership of /srv/wger/static, and
the log line names the directory.

The image creates an account named `admin` with a password upstream publishes in its own
install guide. This gives it the password step 3 generated and then proves the published one no
longer works. It prints neither.

```bash
docker compose exec -T web python3 manage.py shell -c "import os;from django.contrib.auth.models import User;u=User.objects.get(username='admin');u.set_password(os.environ['WGER_ADMIN_PASSWORD']);u.save();u.refresh_from_db();print('default rejected' if not u.check_password('adminadmin') else 'DEFAULT STILL ACCEPTED')"
```

You should see: `default rejected`.

If you do not: `DEFAULT STILL ACCEPTED` means the password did not change and your server is on
the internet with a credential printed in a public document. Stop and fix that before anything
else. `KeyError` means `WGER_ADMIN_PASSWORD` is not in the container's environment, so step 3's
file was written after the container started: run `docker compose up -d --force-recreate web`
and try again.

Now load a food database to start from, and check the whole path end to end:

```bash
docker compose exec -T web wger load-online-fixtures
curl -sS 'https://<DOMAIN>/api/v2/ingredient/?limit=1' | head -c 100
curl -sS https://<DOMAIN>/en/user/login > /tmp/wger-login.html
grep -o '<h2 class="mb-1">Login</h2>' /tmp/wger-login.html; grep -c 'user/registration' /tmp/wger-login.html
asset=$(grep -oE '/static/[^"]+\.css' /tmp/wger-login.html | head -1); curl -sS -o /dev/null -w "$asset %{http_code}\n" "https://<DOMAIN>$asset"
```

You should see, in order: a progress bar while the fixture downloads, then a JSON object whose
`count` is a number above zero, then `<h2 class="mb-1">Login</h2>`, then `0`, then a
`/static/...css` path followed by `200`.

If you do not: the `0` is the one people misread. It means the registration link is absent,
which is correct here, because this install has one account and open signup on a fitness diary
is an invitation. A `404` on the last line is the failure that matters: the page loaded but its
stylesheet did not, so the site will look like unformatted text, and the cause is the ownership
of /srv/wger/static from step 2. An empty ingredient count means the fixture load failed; run
it again and read the error rather than continuing.

Open https://<DOMAIN>/en/user/login in a browser. The first screen shows the heading `Login`
and no register button. Read your password with `grep WGER_ADMIN_PASSWORD /srv/wger/.env`, put
it in your password manager, and log in as `admin`. A running container is not success; a
dashboard is.

## 8. First backup and restore

Two artifacts. PostgreSQL holds every workout, every meal and the ingredient table; the config
archive holds what rebuilds the service around it.

```bash
cd /srv/wger
docker compose exec -T db pg_dump -U wger -d wger | gzip > /srv/wger/backups/wger-db-$(date +%F).sql.gz
sudo tar -czf /srv/wger/backups/wger-config-$(date +%F).tar.gz -C /srv/wger compose.yml .env media -C /etc/caddy Caddyfile
ls -lh /srv/wger/backups/
```

You should see: two files, the database dump a few megabytes after the fixture load and the
config archive a few kilobytes. Nothing goes offline: `pg_dump` takes a consistent snapshot.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/wger
scp vps:/srv/wger/backups/* ~/backups/wger/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/wger/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty diary:

```bash
cd /srv/wger
docker compose down
sudo rm -rf /srv/wger/postgres
sudo install -d -m 700 /srv/wger/postgres
docker compose up -d db
sleep 30
gunzip -c /srv/wger/backups/wger-db-$(date +%F).sql.gz | docker compose exec -T db psql -U wger -d wger
docker compose up -d
sleep 60
curl -sS 'https://<DOMAIN>/api/v2/ingredient/?limit=1' | head -c 100
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then the same ingredient count as
before, which means the database survived being deleted and rebuilt.

If you do not: `role "wger" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Static files are in neither
archive on purpose, because upstream rebuilds them on every container start.

## 9. Updating later

New versions are listed at https://github.com/wger-project/wger/releases. Take both backup
artifacts first, then edit the `wger/server` image line in /srv/wger/compose.yml to the new tag
and its digest.

```bash
cd /srv/wger
docker compose pull
docker compose up -d
docker compose logs --tail 30 web
```

You should see: migration output, then the line about gunicorn on port 8000, and no repeating
restart.

If you do not: put the old tag and digest back and run the same three commands. If the
interface comes back half-styled, set `DJANGO_CLEAR_STATIC_FIRST` to `True` in compose.yml for
one restart, which makes collectstatic rebuild the directory instead of adding to it.

## 10. What will probably go wrong

For the first several minutes https://<DOMAIN> answers `502` and reads like a failed install. I
sat through it twice before I believed it: on an empty database that container runs migrations,
loads the exercise fixtures and processes every static file before gunicorn binds a port, and
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
  1 GB of database and hours of work: your decision, later.
- Do not configure SMTP. Nothing here needs mail, and on a one-account instance the password
  reset is a file on the server.
