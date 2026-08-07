You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Weblate 2026.8.1.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until they
answer. `<DOMAIN>` becomes `WEBLATE_SITE_DOMAIN`, which upstream documents as required and which
every link Weblate prints is built out of, so its A record must already point at this server.
`<ADMIN_EMAIL>` goes on the one `admin` account this install creates.

Upstream states 3 GB of RAM as the floor for Weblate, its database and a web server on one host,
so this wants 3072 MB available and 10 GB free on /srv, and all three images run on amd64 and
arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 3072 MB or free disk is under 10 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a name
that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/weblate /srv/weblate/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/weblate/data /srv/weblate/cache
sudo install -d -m 700 /srv/weblate/postgres /srv/weblate/valkey
ls -la /srv/weblate
```

Assert: `ls -la` shows `backups` owned by the login user, `data` and `cache` owned by uid 1000,
and `postgres` and `valkey` at mode `700` owned by root. The Weblate image runs as uid 1000 and
stops with a permissions message when /app/data is not writable; the other two chown their own
data directory at start-up.

## 3. Secrets

Two secrets: the PostgreSQL password and the first password on the `admin` account. Generate both
on the server, print neither, and keep both out of your summary and out of every log line.

```bash
umask 077
cat > /srv/weblate/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
WEBLATE_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/weblate/.env
umask 022
ls -l /srv/weblate/.env
```

Assert: the file exists with mode `-rw-------`. Upstream states that while that admin variable is
set the account is reset to match it on every start, and warns against keeping a password in
configuration, so step 7 removes the line once the user has signed in.

## 4. compose.yml

```bash
cat > /srv/weblate/compose.yml <<'EOF'
# Weblate · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.weblate.org/en/latest/admin/install/docker.html
#   repository access .. https://docs.weblate.org/en/latest/vcs.html
#   image .............. https://github.com/WeblateOrg/docker/blob/main/Dockerfile
#
# Three services: Weblate, the PostgreSQL holding every string and translation,
# and the Valkey carrying its cache and its Celery queue. Upstream runs the same
# three and reaches Valkey through REDIS_HOST, which is why the service is named
# for what it is and the variable is not. The Weblate image runs as uid 1000 and
# refuses to start when /app/data is not writable, so step 2 hands it that
# directory and /app/cache. Digests read on 2026-08-07, amd64 and arm64 both.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: weblate-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: weblate
      POSTGRES_USER: weblate
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/weblate/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U weblate -d weblate"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 only reaches the other containers.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    container_name: weblate-cache
    restart: unless-stopped
    # Upstream's own line: one snapshot 60 seconds after a key changed.
    command: ["valkey-server", "--save", "60", "1", "--loglevel", "warning"]
    read_only: true
    volumes:
      - /srv/weblate/valkey:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:`: 6379 never leaves the compose network.

  weblate:
    image: weblate/weblate:2026.8.1.0@sha256:44cd8cc84c41079fa9559d7f3cb7e9b80990f2b1ef975868423e322a507edc1b
    container_name: weblate
    restart: unless-stopped
    env_file: /srv/weblate/.env
    environment:
      # Required upstream: every link Weblate prints is built out of it.
      WEBLATE_SITE_DOMAIN: <DOMAIN>
      WEBLATE_SITE_TITLE: Weblate
      # localhost is listed because the image health-checks itself over it.
      WEBLATE_ALLOWED_HOSTS: <DOMAIN>,localhost
      WEBLATE_ADMIN_NAME: Weblate admin
      WEBLATE_ADMIN_EMAIL: <ADMIN_EMAIL>
      # Nobody signs themselves up: translators arrive on an invitation link.
      WEBLATE_REGISTRATION_OPEN: "0"
      # Caddy terminates TLS, so Weblate is told the outside is https.
      WEBLATE_ENABLE_HTTPS: "1"
      WEBLATE_SECURE_PROXY_SSL_HEADER: HTTP_X_FORWARDED_PROTO,https
      WEBLATE_IP_PROXY_HEADER: HTTP_X_FORWARDED_FOR
      # Upstream mails tracebacks to the admin by default; no mail here.
      WEBLATE_ADMIN_NOTIFY_ERROR: "0"
      POSTGRES_HOST: postgres
      POSTGRES_PORT: "5432"
      POSTGRES_DB: weblate
      POSTGRES_USER: weblate
      REDIS_HOST: valkey
      REDIS_PORT: "6379"
    volumes:
      - /srv/weblate/data:/app/data
      - /srv/weblate/cache:/app/cache
    # Everything written lands in the two mounts above. Upstream's own shape.
    read_only: true
    tmpfs:
      - /run
      - /tmp
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8173.
      - "127.0.0.1:8173:8080"
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy
EOF
cd /srv/weblate && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Replace `<DOMAIN>` and `<ADMIN_EMAIL>` in the three places they
appear before running it. Compose fills `${POSTGRES_PASSWORD}` from `.env` here and hands the same
file to Weblate, so one value covers both ends of the connection string.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the real
hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-weblate
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Weblate · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.weblate.org/en/latest/admin/install/docker.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also WEBLATE_SITE_DOMAIN in compose.yml: Weblate builds every link it prints
# out of that value, so the two have to say the same thing.

<DOMAIN> {
	encode zstd gzip

	# No frame header here on purpose. Django sets X-Frame-Options itself,
	# and one set at this layer would override the application's answer
	# without the application knowing.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8173 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Caddy sets
	# X-Forwarded-For and X-Forwarded-Proto itself and ignores what the
	# client sent, which is what WEBLATE_IP_PROXY_HEADER and
	# WEBLATE_SECURE_PROXY_SSL_HEADER read. No upstream response timeout,
	# so a first clone of a large repository has as long as it needs.
	reverse_proxy 127.0.0.1:8173
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-weblate, reload, and report what it objected to. Caddy issues the
certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. These commands are idempotent:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8173 is bound to 127.0.0.1 and 5432 and 6379 are never published at all. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule naming
8173, 5432 or 6379.

## 7. Start and verify

Weblate migrates its database, builds its static files and starts a web server, a Celery worker
and a scheduler inside one container. Its image sets a five-minute start period on its own health
check for that reason, which is why the loop below is long.

```bash
cd /srv/weblate
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthz/
curl -sS https://<DOMAIN>/accounts/login/ | grep -c 'Sign in @ Weblate' || true
curl -sS https://<DOMAIN>/accounts/login/ | grep -c 'Register new account' || true
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The health
endpoint answers `ok`. The third prints `1`, so the sign-in page is Weblate's, not Caddy's error
page. The fourth prints `0`, the security assert here: with registration closed the
`Register new account` link is absent, so nobody who finds this hostname can make themselves an
account. If any of the four misses, stop, run
`docker compose logs --tail 40 weblate`, and name the likely cause: a `502` over a log still
showing migrations wants more time, a permissions message about /app/data points at step 2, a
`400` points at `WEBLATE_ALLOWED_HOSTS`. A running container is not success.

The first screen at https://<DOMAIN>/accounts/login/ shows `Sign in to Weblate` over a username
and password form, with no register link.

STOP: tell the user to read their admin password with
`sudo grep WEBLATE_ADMIN_PASSWORD /srv/weblate/.env`, put it in their password manager, sign in at
https://<DOMAIN>/accounts/login/ as `admin`, and wait. Do not continue until they confirm.

Then take that password out of configuration, so a restart cannot reset the account to it:

```bash
sudo sed -i '/^WEBLATE_ADMIN_PASSWORD/d' /srv/weblate/.env
cd /srv/weblate && docker compose up -d --force-recreate weblate
sleep 60
grep -c WEBLATE_ADMIN_PASSWORD /srv/weblate/.env || true
curl -sS https://<DOMAIN>/healthz/
```

Assert: the count prints `0` and the health endpoint answers `ok` again. Both must pass before you
report success. Upstream leaves the account alone once that variable is gone; setting it again is
how a lost password gets reset.

## 8. First backup and restore

Two artifacts. The database holds every project, string, translation and user. The file archive
holds the data directory, where the cloned repositories, the translation memory and the VCS SSH
private key live, plus the files that rebuild the service.

```bash
cd /srv/weblate
docker compose exec -T postgres pg_dump -U weblate -d weblate | gzip > /srv/weblate/backups/weblate-db-$(date +%F).sql.gz
sudo tar -czf /srv/weblate/backups/weblate-files-$(date +%F).tar.gz -C /srv/weblate data compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/weblate/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. The cache directory and Valkey are left out:
one is rebuilt at every start.

A backup on the same disk is not a backup, so run this one from the user's machine:

```bash
mkdir -p ~/backups/weblate
scp vps:/srv/weblate/backups/* ~/backups/weblate/
```

To restore: `docker compose down`, `sudo rm -rf /srv/weblate/postgres /srv/weblate/data`, recreate
both as step 2 does, untar the file archive into /srv/weblate, `docker compose up -d postgres`,
wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U weblate -d weblate`, then `docker compose up -d`. Tell the
user what is in that archive: the SSH private key Weblate pushes with, which upstream says to keep
a backup of, because a lost one has to be re-authorised on every code host.

## 9. Updating later

New versions are listed at https://github.com/WeblateOrg/weblate/releases, and the matching
four-part image tag is on https://hub.docker.com/r/weblate/weblate. Take both backups first, then
edit the image line in /srv/weblate/compose.yml to the new tag and digest:

```bash
cd /srv/weblate
docker compose pull
docker compose up -d
docker compose logs --tail 30 weblate
```

Weblate migrates its own database on the way up, so watch that log until it settles, then re-run
step 7's health check. Upstream supports direct upgrades only from the current or the previous
calendar year, so a box left for three years needs a stop on the way.

## 10. What will probably go wrong

The first boot looks broken for several minutes and is not. I brought this up, watched Caddy answer
`502` for four and a half minutes, and had the Caddy log open before the page appeared. Nothing was
wrong: the container was migrating and collecting static files while its web server was not
listening yet, which is why upstream's image sets a five-minute start period on its health check.
Give step 7's loop its full ten minutes, and read `docker compose logs --tail 40 weblate` before
the proxy log.

## 11. Out of scope

- Do not add a project or component, and do not generate the VCS SSH key. Weblate makes that key
  at https://<DOMAIN>/manage/ssh/, and pushing translations back needs its public half added on
  the code host with write access, on an account the user holds and you do not.
- Do not configure SMTP or set any `WEBLATE_EMAIL_` variable. Registration is closed and the admin
  adds people by copying an invitation link from Manage, so this runs without mail.
- Do not set any `WEBLATE_SOCIAL_AUTH_`, `WEBLATE_SAML_`, `WEBLATE_AUTH_LDAP_` or `WEBLATE_MT_`
  variable. Each one is an account registered with somebody else, and none is needed to sign in
  here or to translate.
