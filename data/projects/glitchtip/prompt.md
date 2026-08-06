You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install GlitchTip 6.2.3 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say why when you ask: `<DOMAIN>` becomes `GLITCHTIP_DOMAIN`, and every DSN this server hands out
is built from it, so changing it later means editing every application that reports here. Its A
record must already point at this server.

GlitchTip needs 2048 MB of RAM available and 20 GB free on /srv. Upstream recommends 512 MB for
GlitchTip alone; this install runs PostgreSQL 18 and Valkey beside it, and upstream's start
script lets the web worker reach 1024 MB before recycling it. Both architectures are published.
Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop. Disk is what bites
later: upstream puts a million events a month at roughly 30 GB, at the default 90-day retention.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/glitchtip /srv/glitchtip/backups
sudo install -d -m 700 /srv/glitchtip/postgres
sudo install -d -m 750 -o 5000 -g 5000 /srv/glitchtip/uploads
ls -la /srv/glitchtip
```

Assert: `ls -la` shows `backups` owned by the login user, `postgres` at mode `700` owned by
root, and `uploads` owned by uid `5000`. Leave the last two alone: the PostgreSQL image chowns
its own data directory on first start, and the GlitchTip image runs as uid 5000, which is the
account that writes source maps into `uploads`.

## 3. Secrets

Two secrets: the Django `SECRET_KEY` and the PostgreSQL password. Generate both on the server.
Do not print either, do not repeat them in your summary, and do not put them in any log line.

```bash
umask 077
cat > /srv/glitchtip/.env <<EOF
GLITCHTIP_DOMAIN=https://<DOMAIN>
ALLOWED_HOSTS=<DOMAIN>,localhost
CSRF_TRUSTED_ORIGINS=https://<DOMAIN>
SECRET_KEY=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/glitchtip/.env
umask 022
ls -l /srv/glitchtip/.env
```

Assert: the file exists with mode `-rw-------`. `SECRET_KEY` signs the session cookies, and
upstream logs a warning when it is left at its shipped placeholder. `ALLOWED_HOSTS` names the
one hostname Django will answer on, plus `localhost`, because the container health check calls
`http://localhost:8000/_health/` from inside itself and Django returns 400 to a Host header it
was not told about. `CSRF_TRUSTED_ORIGINS` is documented as required behind a reverse
proxy; without it the login form is rejected.

## 4. compose.yml

```bash
cat > /srv/glitchtip/compose.yml <<'EOF'
# GlitchTip · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install guide ....... https://glitchtip.com/documentation/install
#   sample compose ...... https://glitchtip.com/assets/compose.sample.yml
#   backend at v6.2.3 ... https://gitlab.com/glitchtip/glitchtip-backend/-/tree/v6.2.3
#
# Three services. SERVER_ROLE all_in_one is upstream's own sample shape: one
# container applies the migrations, maintains the Postgres partitions, then
# serves with the background worker inside it. No separate worker, no migrate
# job. PostgreSQL 18 keeps its data under /var/lib/postgresql, where the
# official image declares its volume. Valkey gets no volume, matching
# upstream's sample: cache and task queue, worth having available rather than
# worth keeping. Digests read 2026-08-06; all three are multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: glitchtip

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    restart: unless-stopped
    environment:
      POSTGRES_DB: glitchtip
      POSTGRES_USER: glitchtip
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/glitchtip/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U glitchtip -d glitchtip"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the web container.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 12
    # No volume and no ports: cache and queue, reachable in-network only.

  web:
    image: glitchtip/glitchtip:6.2.3@sha256:95e0e2d6b1bc18446902ae0cb47910cc55d7c0d6756ee901b0cd8dce9f8ef5a9
    restart: unless-stopped
    env_file: /srv/glitchtip/.env
    environment:
      SERVER_ROLE: all_in_one
      DATABASE_URL: postgres://glitchtip:${DB_PASSWORD}@postgres:5432/glitchtip
      VALKEY_URL: redis://valkey:6379
      # One account can be created while the user table is empty, then
      # self-signup closes. Step 7 asserts the door shut.
      ENABLE_USER_REGISTRATION: "False"
      # Django Admin and the OpenAPI schema default to on in the code and to
      # off in upstream's sample. Off here too: neither is needed to use this.
      ENABLE_ADMIN: "False"
      ENABLE_OPENAPI: "False"
    volumes:
      - /srv/glitchtip/uploads:/code/uploads
    healthcheck:
      test: ["CMD", "python", "healthcheck.py"]
      interval: 15s
      retries: 20
      start_period: 90s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8123.
      - "127.0.0.1:8123:8000"
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy
EOF
cd /srv/glitchtip && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port. `SERVER_ROLE: all_in_one`
is upstream's own sample shape for a single server: the web container runs the migrations and
the partition maintenance itself, then serves with the worker embedded, so there is no fourth
container and nothing to run by hand after an upgrade.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-glitchtip
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# GlitchTip · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://glitchtip.com/documentation/install and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also GLITCHTIP_DOMAIN and ALLOWED_HOSTS in .env, and every DSN this server
# hands out is built from it, so changing it later means editing every
# application that reports here.

<DOMAIN> {
	# GlitchTip sends its own Content-Security-Policy, so nothing here
	# touches that header. HSTS, nosniff and a same-origin frame rule are
	# the additions.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# Upstream's nginx example raises client_max_body_size to 40M because
	# nginx caps a body at 1M. Caddy has no such cap, so nothing to raise.
	#
	# 8123 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8123
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. On failure restore /etc/caddy/Caddyfile.before-glitchtip, reload, and
report what it objected to. Caddy gets the certificate on the first request and renews it
itself, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8123 stays closed because compose binds it to 127.0.0.1; 5432 and 6379 stay
closed because compose publishes neither, so they have no host port to firewall. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for
8123, 5432 or 6379.

## 7. Start and verify

On a cold start the web container applies every migration and builds the event partitions
before it binds a port, so this takes minutes rather than seconds.

```bash
cd /srv/glitchtip
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_health/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/_health/; echo
curl -sS https://<DOMAIN>/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/0/organizations/
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/admin/
```

Assert all five, printing what you received for each. The loop ends on `200`. The health
endpoint prints `ok`. The settings line prints `"enableUserRegistration":true`, the door
standing open only because the user table is still empty. The organizations call prints `401`,
the answer to an API request carrying no credential, and the security assert here. `/admin/`
prints `404`, because `ENABLE_ADMIN` is False and Django Admin is not routed at all. If any of
the five misses, stop, run `docker compose logs --tail 40 web` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a `502` from Caddy while
the loop still runs is the migrations, a database that never reports healthy points at step 2,
and a `400` where a `200` was expected is `ALLOWED_HOSTS` in step 3 not matching the hostname. A
running container is not success.

The first screen at https://<DOMAIN> is a login card headed `Login`, with a `New to GlitchTip?`
line and a `Sign Up` link under the form.

STOP: tell the user to open https://<DOMAIN>, follow `Sign Up`, create their account with an
email address and a password they have saved in a password manager first, then the organization
GlitchTip asks for next, then a first project inside it, and wait.
Do not continue until they confirm. This is the only moment that account can be made, and this
install sends no mail, so a lost password has no reset link. The project's settings show its
DSN, and the first real event can only come from the user's own application with its sentry-sdk
pointed at that string, which is why this prompt does not send one.

Then prove the door shut:

```bash
curl -sS https://<DOMAIN>/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
```

Assert: `"enableUserRegistration":false`, and the user reloads https://<DOMAIN> and confirms the
`Sign Up` link is gone. Both must pass before you report success.

## 8. First backup and restore

Two artifacts: the database holds every account, project, issue and event; the config archive
holds what rebuilds the service around them.

```bash
cd /srv/glitchtip
docker compose exec -T postgres pg_dump -U glitchtip -d glitchtip | gzip > /srv/glitchtip/backups/glitchtip-db-$(date +%F).sql.gz
sudo tar -czf /srv/glitchtip/backups/glitchtip-config-$(date +%F).tar.gz -C /srv/glitchtip compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/glitchtip/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Valkey is not backed up: cache and queue,
not data. A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/glitchtip
scp vps:/srv/glitchtip/backups/* ~/backups/glitchtip/
```

To restore: `docker compose down`, `sudo rm -rf /srv/glitchtip/postgres`, recreate the
directories from step 2, untar the config archive into /srv/glitchtip so .env is back before
anything starts, `docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U glitchtip -d glitchtip`, then
`docker compose up -d`. Say why the two files travel together: the database was created with the
credential in that .env, so a dump restored without it is a database the new container cannot
open.

## 9. Updating later

GlitchTip develops on GitLab, and releases are tagged at
https://gitlab.com/glitchtip/glitchtip-backend/-/tags. The Docker Hub tag drops the leading `v`,
so `v6.2.4` there is `6.2.4` in the image line. Back up first, then edit the image line in
/srv/glitchtip/compose.yml to the new tag and its digest:

```bash
cd /srv/glitchtip
docker compose pull
docker compose up -d
docker compose logs --tail 40 web
```

The web container migrates on the way up, so watch that log until it settles, then re-run
step 7's health check before calling the update done.

## 10. What will probably go wrong

The wait on the first start. I saw the web container sit at `starting`, opened https://<DOMAIN>,
got a `502` from Caddy, and went to read the Caddyfile looking for what I had typed wrong.
Nothing was wrong. The container was still applying migrations and building event partitions
against an empty database, and it binds its port only after that finishes. It took about four
minutes. Let the loop in step 7 run all forty times before concluding anything is broken.

## 11. Out of scope

- Do not configure SMTP and do not set `EMAIL_URL` or `DEFAULT_FROM_EMAIL`. With no mail
  transport GlitchTip turns email off on purpose: account verification and password reset leave
  the interface, and alerts go to a webhook recipient instead. That is the trade here, not an
  oversight to fix.
- Do not set `GLITCHTIP_ENABLE_DUCKDB` or configure S3 cold storage. That is a second storage
  backend and a bucket on another host, and PostgreSQL holds everything at this size.
- Do not set `ENABLE_ADMIN` back to True and do not run `manage.py createsuperuser`. The account
  made in step 7 administers this instance from the normal interface.
- Do not split the worker into its own container. `SERVER_ROLE: all_in_one` runs it inside the
  web process, which is upstream's own shape for a single server.
