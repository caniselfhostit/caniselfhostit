You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Seafile Community Edition 13.0.25 on that server, reachable at https://<DOMAIN>, behind
the existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until they
answer. Say this when you ask: `<DOMAIN>` becomes `SEAFILE_SERVER_HOSTNAME`, and Seahub rebuilds
every share link and upload address out of it at every start, so it is expensive to change later.
Its A record must already point here. `<ADMIN_EMAIL>` is the address the one administrator account
is created under; no SMTP is configured, so it never receives mail.

Seafile needs 2048 MB of RAM available and 10 GB free on /srv, upstream's floor for the community
edition, and that 10 GB is the install rather than the files. All three images are multi-arch.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both and stop. Do not install
and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a certificate for a
name that does not resolve, and failed attempts count against a rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/seafile /srv/seafile/backups
sudo install -d -m 750 /srv/seafile/data
sudo install -d -m 700 /srv/seafile/mysql
ls -la /srv/seafile
```

Assert: `backups` owned by the login user, `data` and `mysql` by root. Leave those two alone and
read them with `sudo ls`. The Seafile container runs as root and fills `data` with `conf`,
`seafile-data`, `seahub-data` and `logs` on first boot; MariaDB chowns `mysql` to its own uid, and
one already chowned makes it refuse to initialise.

## 3. Secrets

Five secrets, all generated here on the server. Do not print any of them, do not repeat them in your
summary, and keep them out of every log line. Hex rather than base64 for all five: two travel inside
database connection strings and one is typed into a login form by a human.

```bash
umask 077
cat > /srv/seafile/.env <<EOF
SEAFILE_SERVER_HOSTNAME=<DOMAIN>
INIT_SEAFILE_ADMIN_EMAIL=<ADMIN_EMAIL>
TIME_ZONE=Etc/UTC
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
SEAFILE_MYSQL_DB_PASSWORD=$(openssl rand -hex 32)
JWT_PRIVATE_KEY=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
INIT_SEAFILE_ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/seafile/.env
umask 022
ls -l /srv/seafile/.env
```

Assert: mode `-rw-------` and the login user's name twice. Compose reads this file for the `${...}`
substitutions in compose.yml whenever it runs from /srv/seafile, so the values reach the containers
without it being mounted. Upstream wants `JWT_PRIVATE_KEY` at 32 characters or more and it gets 64;
changing it later invalidates every session. The `INIT_` values are read on the first start only.

## 4. compose.yml

```bash
cat > /srv/seafile/compose.yml <<'EOF'
# Seafile Community Edition · the deterministic fallback. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://manual.seafile.com/13.0/setup/setup_ce_by_docker/
#   variable reference . https://manual.seafile.com/13.0/config/env/
#   reverse proxy ...... https://manual.seafile.com/13.0/setup/use_other_reverse_proxy/
#
# Three services. Upstream's own deployment starts five, adding a Caddy and the
# SeaDoc editor; this box already runs Caddy, and ENABLE_SEADOC false is
# upstream's documented way to drop the editor. SEAFILE_SERVER_PROTOCOL is https
# because Caddy terminates TLS here: Seahub rebuilds SERVICE_URL and
# FILE_SERVER_ROOT from it at every start, so http would put an http upload
# address on an https page. Only 8140 is published, on loopback. Digests read
# 2026-08-06; all three publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:10.11.18@sha256:de61fed4a40d3842f3ee09944ba52792156cfd9adf489b2cc670fc6ded28df8d
    container_name: seafile-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/seafile/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      start_period: 30s
      timeout: 5s
      retries: 10
    # No `ports:` at all: 3306 only exists on the compose network.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: seafile-redis
    restart: unless-stopped
    # A password, which upstream leaves off; $$ defers expansion to the container.
    command:
      - /bin/sh
      - -c
      - exec redis-server --requirepass "$$REDIS_PASSWORD" --save "" --appendonly no
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    # No `ports:` at all: 6379 never leaves the compose network.

  seafile:
    image: seafileltd/seafile-mc:13.0.25@sha256:90c1aaa08731116750cd7ce16cbc6afe0c26006433002d3c7215a5f4254ec244
    container_name: seafile
    restart: unless-stopped
    volumes:
      - /srv/seafile/data:/shared
    environment:
      SEAFILE_MYSQL_DB_HOST: db
      SEAFILE_MYSQL_DB_USER: seafile
      SEAFILE_MYSQL_DB_PASSWORD: ${SEAFILE_MYSQL_DB_PASSWORD}
      INIT_SEAFILE_MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      SEAFILE_MYSQL_DB_CCNET_DB_NAME: ccnet_db
      SEAFILE_MYSQL_DB_SEAFILE_DB_NAME: seafile_db
      SEAFILE_MYSQL_DB_SEAHUB_DB_NAME: seahub_db
      # Redis, because Seafile 13 stopped shipping memcached in Docker.
      CACHE_PROVIDER: redis
      REDIS_HOST: redis
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      JWT_PRIVATE_KEY: ${JWT_PRIVATE_KEY}
      SEAFILE_SERVER_HOSTNAME: ${SEAFILE_SERVER_HOSTNAME}
      SEAFILE_SERVER_PROTOCOL: https
      TIME_ZONE: ${TIME_ZONE}
      # Read on the first start only, to create the one account there is.
      INIT_SEAFILE_ADMIN_EMAIL: ${INIT_SEAFILE_ADMIN_EMAIL}
      INIT_SEAFILE_ADMIN_PASSWORD: ${INIT_SEAFILE_ADMIN_PASSWORD}
      # Upstream's editor extension, which would need a container of its own.
      ENABLE_SEADOC: "false"
    ports:
      - "127.0.0.1:8140:80"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
EOF
cd /srv/seafile && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port, two data mounts.

## 5. Caddy and TLS

Append the block below, with `<DOMAIN>` replaced by the real hostname, to the Caddyfile Prompt Zero
installed. Copy that file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-seafile
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Seafile · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://manual.seafile.com/13.0/setup/use_other_reverse_proxy/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. It is also
# SEAFILE_SERVER_HOSTNAME in .env, so the two stay the same string.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# No `encode`: these bytes are stored file blocks on /seafhttp.
	# Upstream's nginx sample drops the body limit, the request buffering
	# and the read timeout here; Caddy already streams and caps nothing
	# unless told to, so do not add `request_body max_size`.
	#
	# 8140 is the loopback port compose publishes, not a container port,
	# and not open in the firewall.
	reverse_proxy 127.0.0.1:8140
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-seafile, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. The desktop and mobile clients need nothing more: uploads and downloads ride /seafhttp on
the same hostname and the same 443. 8140 stays closed because compose binds it to loopback, 3306 and
6379 because neither container publishes a host port. Assert: `Status: active`, rules for 80,
443/tcp and 443/udp, and no rule mentioning 8140, 3306 or 6379.

## 7. Start and verify

First boot initialises MariaDB, creates the three databases, migrates them and seeds the one
account. That takes minutes and prints nothing for long stretches.

```bash
cd /srv/seafile
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api2/ping/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api2/ping/
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api2/auth/ping/
docker compose exec -T seafile printenv SEAFILE_VERSION SEAFILE_SERVER_PROTOCOL
curl -sSL https://<DOMAIN>/accounts/login/ | grep -o '<h1 class="login-panel-hd">[^<]*</h1>'
```

Assert all five and print what you received for each. The loop ends on `200`. The ping prints
`"pong"`. `/api2/auth/ping/` prints `401`, the security assert here: the API is up and refusing a
request carrying no token. `printenv` prints `13.0.25` then `https`, the first proving the container
is the pinned tag, the second that Seahub generates https addresses. The last command prints
`<h1 class="login-panel-hd">Log In</h1>`.

If any of the five misses, stop, run `docker compose logs --tail 60 seafile` and
`docker compose logs --tail 20 db`, and name the likely earlier step: a database that never reports
healthy points at step 2, a `502` means Caddy reaches nothing on 8140. A running container is not
success.

Registration is closed: upstream ships `ENABLE_SIGNUP` off, so the account created from
`INIT_SEAFILE_ADMIN_EMAIL` is the only way in and nobody can make a second one.

STOP: tell the user to read their password with
`grep INIT_SEAFILE_ADMIN_PASSWORD /srv/seafile/.env`, put it in their password manager, sign in at
https://<DOMAIN> as `<ADMIN_EMAIL>`, create a library and upload one file. Wait. Do not continue
until they confirm the file is listed: that upload is the check that matters, because the web
interface loads fine even when the file server behind /seafhttp does not.

## 8. First backup and restore

Two artifacts: a dump of the databases, and an archive of the blocks, the generated configuration
and the files that rebuild the service around them.

```bash
cd /srv/seafile
docker compose exec -T db sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb-dump -uroot --opt --all-databases' | gzip > /srv/seafile/backups/seafile-db-$(date +%F).sql.gz
sudo tar -czf /srv/seafile/backups/seafile-files-$(date +%F).tar.gz -C /srv/seafile data compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/seafile/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `mariadb-dump`
locks each table only while it reads it, and the password is expanded inside the container, so it
never reaches the host's process list. `--all-databases` carries the `seafile` MySQL user and its
grants, without which a restore onto an empty MariaDB gives a database Seafile cannot log in to.

A backup on the same disk as the data is not a backup, so run this one from the user's machine:

```bash
mkdir -p ~/backups/seafile
scp vps:/srv/seafile/backups/* ~/backups/seafile/
```

To restore: `docker compose down`, `sudo rm -rf /srv/seafile/data /srv/seafile/mysql`, recreate both
as in step 2, untar the files archive into /srv/seafile, `docker compose up -d db`, wait a minute for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb -uroot'`,
`docker compose restart db` so the grants take effect, then `docker compose up -d`. What matters at
2am: Seafile keeps deduplicated blocks under `data/seafile/seafile-data` and the names and library
structure in the database, so restoring one without the other gives blocks with no names or names
with no blocks.

## 9. Updating later

Image tags are listed at https://hub.docker.com/r/seafileltd/seafile-mc/tags. Take both backups
first, then edit the image line in /srv/seafile/compose.yml to the new tag and its digest:

```bash
cd /srv/seafile
docker compose pull
docker compose up -d
docker compose logs --tail 40 seafile
```

The schema upgrade runs on the way up and can take minutes. Watch that log until it settles, then
re-run the step 7 checks. Do not skip a major version; upstream writes its upgrade notes one major
at a time.

## 10. What will probably go wrong

An upload that fails silently, looking like a broken file server rather than a configuration
mistake. Seahub does not read the protocol off the request: it builds SERVICE_URL and
FILE_SERVER_ROOT at container start from `SEAFILE_SERVER_PROTOCOL` and `SEAFILE_SERVER_HOSTNAME`, so
if either is wrong the login page loads, the library list loads, and then the browser is handed an
upload address on the wrong scheme or host and refuses it. I lost twenty minutes reading file server
logs that had nothing in them, because nothing ever reached the file server. That is why step 7
asserts `printenv` prints `https`. If uploads fail later, check those two values first.

## 11. Out of scope

- Do not add the SeaDoc editor or set `ENABLE_SEADOC` to true. It is a second container on a second
  route, and this prompt installs the file server it would plug into.
- Do not configure SMTP. Seafile works without it; the cost is invitation and password-reset mail,
  and the administrator can create accounts by hand instead.
- Do not enable the notification server or the metadata server. Each is another upstream extension
  container, and neither is needed to sync files.
- Do not switch the image to seafile-pro-mc. That edition needs a licence file and brings
  Elasticsearch with it, a different install on a bigger box.
