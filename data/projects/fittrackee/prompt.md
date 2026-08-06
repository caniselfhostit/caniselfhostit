You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install FitTrackee 1.3.4 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and it becomes `UI_URL`, the address FitTrackee
writes into the links it generates.

FitTrackee needs 2048 MB of RAM available and 10 GB free on /srv. The application image
publishes amd64 and arm64, but PostGIS is a mandatory prerequisite and the PostGIS image
publishes amd64 only, in upstream's own words, so this install is amd64 only. Measure all four
first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dpkg --print-architecture` prints anything but `amd64`, print it and
stop: there is no PostGIS image for that architecture. If `dig +short` prints nothing, print
that and stop: Caddy cannot get a certificate for a name that does not resolve, and failed
attempts count against a rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/fittrackee /srv/fittrackee/backups
sudo install -d -m 755 -o 1000 -g 1000 /srv/fittrackee/uploads /srv/fittrackee/staticmap_cache
sudo install -d -m 700 /srv/fittrackee/postgres
ls -la /srv/fittrackee
```

Assert: `ls -la` shows `backups` owned by the login user, `uploads` and `staticmap_cache` owned
by uid `1000`, and `postgres` at mode `drwx------` owned by root. The image runs as uid 1000 and
upstream requires both of those directories writable by it, which is why they are chowned to a
number rather than to whoever is logged in. Leave `postgres` to root: the database image chowns
its own data directory on first start.

## 3. Secrets

Two secrets, both generated here: the PostgreSQL password and `APP_SECRET_KEY`, which upstream
documents as the key used in JWT generation. Do not print either, do not repeat them in your
summary, and keep them out of every log line. Hex, not base64: one travels inside a database
connection string.

```bash
umask 077
cat > /srv/fittrackee/.env <<EOF
UI_URL=https://<DOMAIN>
POSTGRES_PASSWORD=$(openssl rand -hex 32)
APP_SECRET_KEY=$(openssl rand -hex 48)
EOF
chmod 600 /srv/fittrackee/.env
umask 022
ls -l /srv/fittrackee/.env
```

Assert: the file exists with mode `-rw-------`. Docker Compose reads it for the `${...}`
substitutions in compose.yml whenever it runs from /srv/fittrackee and passes it to the
application container, so one password reaches both the database and the connection string.

## 4. compose.yml

```bash
cat > /srv/fittrackee/compose.yml <<'EOF'
# FitTrackee · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install . https://docs.fittrackee.org/en/installation/installation.html
#   variables ...... https://docs.fittrackee.org/en/installation/environments_variables.html
#   emails ......... https://docs.fittrackee.org/en/installation/emails.html
#
# Two services. PostGIS 3.4+ is a mandatory prerequisite, so the database image
# is postgis/postgis, which enables the extension in POSTGRES_DB on first start
# and publishes linux/amd64 only, in upstream's own words. PostgreSQL 18 moved
# PGDATA, so the mount is /var/lib/postgresql. Digests read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  fittrackee-db:
    image: postgis/postgis:18-3.6-alpine@sha256:22e5371710d26bae9b4f3b28f962bcfddecbf8ba8c9e8357ece4ca18858ede28
    platform: linux/amd64
    container_name: fittrackee-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: fittrackee
      POSTGRES_USER: fittrackee
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/fittrackee/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U fittrackee -d fittrackee"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  fittrackee:
    image: fittrackee/fittrackee:v1.3.4@sha256:87ebf6879eccad561e84b257eb1ec825030030d6b0142fbaef0048c7d8cc29ba
    container_name: fittrackee
    restart: unless-stopped
    env_file: /srv/fittrackee/.env
    environment:
      FLASK_APP: fittrackee
      FLASK_SKIP_DOTENV: "1"
      DATABASE_URL: postgresql://fittrackee:${POSTGRES_PASSWORD}@fittrackee-db:5432/fittrackee
      UPLOAD_FOLDER: /usr/src/app/uploads
      STATICMAP_CACHE_DIR: /usr/src/app/.staticmap_cache
      # Console logging, so /usr/src/app/logs never has to exist.
      GUNICORN_LOG: "-"
      # Empty on purpose: no mail server, so no Redis and no worker.
      EMAIL_URL: ""
    command: sh docker-entrypoint.sh
    volumes:
      - /srv/fittrackee/uploads:/usr/src/app/uploads
      - /srv/fittrackee/staticmap_cache:/usr/src/app/.staticmap_cache
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8129.
      - "127.0.0.1:8129:5000"
    depends_on:
      fittrackee-db:
        condition: service_healthy
EOF
cd /srv/fittrackee && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, two bind mounts, no Redis:
upstream documents Redis and a worker for rate limits, email and data-export archives, and this
install runs neither.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-fittrackee
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# FitTrackee · the Caddy site block for this service. Authored by caniselfhostit
# from https://docs.fittrackee.org/en/installation/deployment.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. It is also UI_URL in
# .env, so the two have to stay the same string.

<DOMAIN> {
	# The workout list is a JavaScript bundle and the API answers JSON.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy: every workout map pulls tiles from
	# tile.openstreetmap.org, and one written without testing that breaks
	# the maps. Caddy sets no request body limit either, so an upload
	# ceiling raised in FitTrackee's Administration page needs nothing here.

	# 8129 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8129
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-fittrackee, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it itself. Nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3. 8129 stays closed because compose binds it to 127.0.0.1, and 5432 because compose
never publishes it at all. Assert: `ufw status verbose` prints `Status: active`, shows 80,
443/tcp and 443/udp, and no rule mentioning 8129 or 5432.

## 7. Start and verify

FitTrackee runs its migrations on the way up, which takes longer on the first start than on any
later one. Registration also ships open, because upstream's active-users limit is 0 and 0 means
no limit, so this block starts the service and sets that limit to one in the same pass. There is
no environment variable and no CLI command for the limit, and the API that changes it needs an
administrator who does not exist yet, so it goes into the row directly and the container is
restarted to pick it up.

```bash
cd /srv/fittrackee
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/check-db
curl -sS https://<DOMAIN>/ | grep -o '<title>[^<]*</title>'
docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee -c "UPDATE app_config SET max_users = 1;"
docker compose restart fittrackee
sleep 20
curl -sS https://<DOMAIN>/api/config
```

Assert all five, and print what you received for each: the loop ends on `200`; `/api/check-db`
returns `"db available"`; the title line prints `<title>FitTrackee</title>`; psql prints
`UPDATE 1`; the config JSON contains `"version":"1.3.4"`, `"max_users":1` and
`"is_registration_enabled":true`. That last pair is correct, not contradictory: FitTrackee
allows a registration while the account count is under the limit, so exactly one person can
still sign up, and that person is the user. If anything misses, stop, run
`docker compose logs --tail 40 fittrackee` and `docker compose logs --tail 20 fittrackee-db`,
and name the likely earlier step: a database that never reports healthy points at step 2, `502`
means Caddy reaches nothing on 8129, `"db unavailable"` points at the password in step 3.

STOP: tell the user to open https://<DOMAIN>/register, create their account with a username,
their email address and a password of at least 8 characters, and wait. Do not continue until
they confirm. Warn them first that FitTrackee will say the account needs confirming by email,
that this server sends no mail, and that they cannot sign in until the next command runs.

```bash
cd /srv/fittrackee
FTUSER=$(docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee -tAc "SELECT username FROM users ORDER BY id LIMIT 1")
echo "account: $FTUSER"
docker compose exec -T fittrackee ftcli users update "$FTUSER" --set-role owner
curl -sS https://<DOMAIN>/api/config
```

Assert all three: `account:` prints the username the user typed, the CLI exits 0, and the config
JSON now reads `"is_registration_enabled":false`. That last one is the security assert in this
block: with one account against a limit of one, FitTrackee closes its own registration form and
an unauthenticated endpoint says so. If it still reads `true`, stop and say so plainly rather
than reporting success. The owner role also activates the account, upstream's documented answer
on an instance with no mail.

The first screen at https://<DOMAIN> shows a `Login` heading over an `Email` box and a
`Password` box, with `Forgot password?` beneath them and no `Register` link.
https://<DOMAIN>/register now answers `Sorry, registration is disabled.`

STOP: tell the user to sign in at https://<DOMAIN> and confirm their dashboard loads, and wait.
Do not continue until they confirm. A running container is not success.

## 8. First backup and restore

Two artifacts: the database holds every workout and everything computed from it, and the config
archive holds the uploaded track files plus the three files that rebuild the service.

```bash
cd /srv/fittrackee
docker compose exec -T fittrackee-db pg_dump -U fittrackee -d fittrackee | gzip > /srv/fittrackee/backups/fittrackee-db-$(date +%F).sql.gz
sudo tar -czf /srv/fittrackee/backups/fittrackee-config-$(date +%F).tar.gz -C /srv/fittrackee compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/fittrackee/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. A backup on the same disk is not a backup, so run
this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/fittrackee
scp vps:/srv/fittrackee/backups/* ~/backups/fittrackee/
```

To restore: `docker compose down`, `sudo rm -rf /srv/fittrackee/postgres`, recreate it as in
step 2, `docker compose up -d fittrackee-db`, wait for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee`, untar
the config archive into /srv/fittrackee, then `docker compose up -d`. Tell the user what matters
at 2am: the tracks are in `uploads`, everything computed from them is in the database, and the
two archives are only useful together.

## 9. Updating later

New versions are listed at https://github.com/SamR1/FitTrackee/releases. Migrations run at
start-up, so upstream asks you to back up before changing the image. Take both artifacts, then
edit the image line in /srv/fittrackee/compose.yml to the new tag and digest:

```bash
cd /srv/fittrackee
docker compose pull
docker compose up -d
docker compose logs --tail 30 fittrackee
```

Watch that log until the migrations settle, then re-run the `/api/config` check from step 7 and
confirm `version` matches the pinned tag.

## 10. What will probably go wrong

The user will register, get told to check their email, find nothing, and conclude the install is
broken. I did. It is not: FitTrackee creates every account inactive and mails a confirmation
link, this server sends no mail on purpose, and the sign-in screen answers an inactive account
with a message that reads exactly like a wrong password. The `ftcli users update` command in
step 7 clears it, and it has to run after the account exists. The same command activates anyone
the user adds later, and that is the whole account system here.

## 11. Out of scope

- Do not configure SMTP, and do not add Redis or the Dramatiq worker. Upstream states a
  single-user instance runs with an empty `EMAIL_URL` and needs neither; adding them is two more
  services for mail one CLI command already replaces.
- Do not set `WEATHER_API_PROVIDER` or `WEATHER_API_KEY`. Weather on a workout needs an account
  with a third-party forecast service, a signup this install exists to avoid.
- Do not set `TILE_SERVER_URL` to a keyed provider. The default OpenStreetMap tile server needs
  no account, and its usage policy is the user's decision, not yours.
- Do not enable OAuth 2.0 applications. That connects third-party clients later, and it is not
  part of getting the first workout onto this server.
