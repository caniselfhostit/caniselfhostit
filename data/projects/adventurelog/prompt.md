You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install AdventureLog 0.12.1 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. That hostname becomes `ORIGIN`, `PUBLIC_URL`,
`FRONTEND_URL` and `CSRF_TRUSTED_ORIGINS` in one .env file and fronts every image URL, so
changing it later is an edit in four places.

AdventureLog needs 2048 MB of RAM available and 10 GB free on /srv. Upstream asks for 2 GB on the
first boot, which imports the world geography dataset, and about 1 GB after. Both AdventureLog
images publish amd64 and arm64, but PostGIS is required and postgis/postgis publishes amd64 only,
so this install is amd64 only. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope: on a smaller box the OOM killer ends the world-data import and the
container exits 137. If `dpkg --print-architecture` prints anything but `amd64`, print it and
stop, because there is no PostGIS image for that architecture. If `dig +short` prints nothing,
print that and stop, because Caddy cannot get a certificate for a name that does not resolve and
failed attempts count against a rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/adventurelog /srv/adventurelog/backups
sudo install -d -m 755 /srv/adventurelog/media
sudo install -d -m 700 /srv/adventurelog/postgres
ls -la /srv/adventurelog
```

Assert: `ls -la` shows `backups` owned by the login user, `media` at mode `drwxr-xr-x` and
`postgres` at mode `drwx------`, the last two owned by root. Leave both to root: the backend
container runs as root and writes photographs and flags into `media`, and the database image
chowns its own data directory on first start, so one already chowned to yourself makes it refuse
to initialise.

## 3. Secrets

Three secrets, all generated here: the PostgreSQL password, Django's `SECRET_KEY`, and the
password for the `admin` account the backend creates on first boot. Do not print any of them, do
not repeat them in your summary, and keep them out of every log line. Hex, not base64: one
travels inside a database connection string.

```bash
umask 077
cat > /srv/adventurelog/.env <<EOF
PUBLIC_SERVER_URL=http://server:8000
ORIGIN=https://<DOMAIN>
BODY_SIZE_LIMIT=Infinity
PGHOST=db
POSTGRES_DB=adventurelog
POSTGRES_USER=adventurelog
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SECRET_KEY=$(openssl rand -hex 48)
DJANGO_ADMIN_USERNAME=admin
DJANGO_ADMIN_PASSWORD=$(openssl rand -hex 24)
DJANGO_ADMIN_EMAIL=admin@<DOMAIN>
PUBLIC_URL=https://<DOMAIN>
FRONTEND_URL=https://<DOMAIN>
CSRF_TRUSTED_ORIGINS=https://<DOMAIN>
DEBUG=False
DISABLE_REGISTRATION=True
ENABLE_RATE_LIMITS=True
EOF
chmod 600 /srv/adventurelog/.env
umask 022
ls -l /srv/adventurelog/.env
```

Assert: the file exists with mode `-rw-------`. Four lines matter. `PUBLIC_SERVER_URL` is how
the frontend reaches the backend inside the network, and upstream says not to change it.
`DEBUG` defaults to true in the image, so False here stops Django serving stack traces to
strangers. `DISABLE_REGISTRATION` closes a sign-up form otherwise open on a public hostname.
`ENABLE_RATE_LIMITS` defaults to false and turns on upstream's throttle for failed logins. No
mail is configured, so `DJANGO_ADMIN_EMAIL` is a label, not a mailbox.

## 4. compose.yml

```bash
cat > /srv/adventurelog/compose.yml <<'EOF'
# AdventureLog · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install .. https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/documentation/docs/install/docker.md
#   variables ....... https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/.env.example
#
# Three services, and the names are load bearing: PUBLIC_SERVER_URL defaults to
# http://server:8000 and PGHOST is db. Two host ports, because the browser talks
# to both containers: the Django backend answers /media, /admin, /static and
# /accounts, the frontend answers the rest, the split upstream's Caddy guide
# documents. PostGIS is required and postgis/postgis publishes linux/amd64 only.
# Digests read from the registries on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgis/postgis:16-3.5@sha256:7d7925e334fceb6079c0a5d150e925f192cde2cf1dd78767ca843e2996d39829
    platform: linux/amd64
    container_name: adventurelog-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/adventurelog/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U adventurelog -d adventurelog"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  server:
    image: ghcr.io/seanmorley15/adventurelog-backend:v0.12.1@sha256:7c759efab1476841f7319776666e527bedd481cd71dbb08e51aaa5959f2a28eb
    container_name: adventurelog-backend
    restart: unless-stopped
    env_file: /srv/adventurelog/.env
    volumes:
      # Photographs, and the country flags the first boot downloads.
      - /srv/adventurelog/media:/code/media
    ports:
      # Loopback only: Caddy sends /media, /admin, /static and /accounts here.
      - "127.0.0.1:8268:80"
    depends_on:
      db:
        condition: service_healthy

  web:
    image: ghcr.io/seanmorley15/adventurelog-frontend:v0.12.1@sha256:edd79220f0def1dbea5b5d56636621f6cfdb454db9c00a8ce436a8ab489c5e99
    container_name: adventurelog-frontend
    restart: unless-stopped
    env_file: /srv/adventurelog/.env
    ports:
      # Loopback only: Caddy sends everything else here.
      - "127.0.0.1:8168:3000"
    depends_on:
      - server
EOF
cd /srv/adventurelog && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, two published ports, two bind mounts.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-adventurelog
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# AdventureLog · the Caddy site block for this service. Authored by
# caniselfhostit from
# https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/documentation/docs/install/caddy.md
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# ORIGIN, PUBLIC_URL, FRONTEND_URL and CSRF_TRUSTED_ORIGINS in .env, so all five
# stay the same string or the login form answers 403.
#
# One hostname, two upstreams, the split upstream's Caddy guide documents: the
# Django backend answers /media, /admin, /static and /accounts, the frontend
# answers everything else. Send it all to the frontend and every photograph
# goes missing.

<DOMAIN> {
	# The app is a JavaScript bundle and the API answers JSON.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy: the map draws tiles from basemaps.cartocdn.com
	# and the flags come from flagcdn.com, so one written untested breaks maps.

	# 8268 and 8168 are loopback ports compose publishes, closed in the firewall.
	@backend path /media* /admin* /static* /accounts*
	reverse_proxy @backend 127.0.0.1:8268

	reverse_proxy 127.0.0.1:8168
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-adventurelog, reload, and report what it objected to. Caddy issues
and renews the certificate itself, and sets the `X-Forwarded-Proto` Django reads for https.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8168 and 8268 stay closed because compose binds both to 127.0.0.1, 5432 because compose
never publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8168, 8268 or 5432.

## 7. Start and verify

The backend waits for PostgreSQL, runs its migrations, creates the `admin` account from the three
`DJANGO_ADMIN_` values, then downloads the world country and region dataset and a flag for every
country before it serves anything. On a fresh box that last part is minutes, so the loop below is
patient.

```bash
cd /srv/adventurelog
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/ | grep -o '<title>[^<]*</title>'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/admin/login/
curl -sS http://127.0.0.1:8268/auth/is-registration-disabled/
docker compose exec -T db psql -U adventurelog -d adventurelog -tAc "SELECT count(*) FROM worldtravel_country;"
```

Assert all five, and print what you received for each: the loop ends on `200`; the title line
prints `<title>AdventureLog</title>`; the Django admin login page answers `200`, which proves
Caddy routes the four backend paths to 8268 rather than sending everything to the frontend; the
registration endpoint prints `"is_disabled":true`, the security assert; the count is at least
`195`, meaning the world-data import finished rather than being killed. If any of the five
misses, stop, run `docker compose logs --tail 40 server` and `docker compose logs --tail 20 db`,
and name the likely earlier step: a database that never reports healthy points at step 2, `502`
means Caddy reaches nothing on 8168, `404` on the admin page means step 5's `@backend` matcher
did not land, exit code 137 is the OOM killer during the import and step 1's floor being wrong.
A running container is not success.

The first screen at https://<DOMAIN> is the AdventureLog landing page with a `Login` button.
https://<DOMAIN>/login shows a form with `Username` and `Password` boxes and no sign-up link.

STOP: tell the user to read their admin password with
`sudo grep DJANGO_ADMIN_PASSWORD /srv/adventurelog/.env`, put it in their password manager, sign
in at https://<DOMAIN>/login as `admin`, confirm the dashboard loads, and wait.
Do not continue until they confirm. It is the only credential here, and no mail server can send
a reset link.

## 8. First backup and restore

Two artifacts: the database holds every trip, location and visit, the config archive holds the
photographs and the three files that rebuild the service around them.

```bash
cd /srv/adventurelog
docker compose exec -T db pg_dump -U adventurelog -d adventurelog | gzip > /srv/adventurelog/backups/adventurelog-db-$(date +%F).sql.gz
sudo tar -czf /srv/adventurelog/backups/adventurelog-config-$(date +%F).tar.gz -C /srv/adventurelog compose.yml .env media -C /etc/caddy Caddyfile
ls -lh /srv/adventurelog/backups/
```

Assert: both exist and both are non-empty. Print both sizes. The config archive is tens of
megabytes on a fresh install because the flags are in it. Nothing is stopped: `pg_dump` snapshots
a running database consistently. A backup on the same disk is not a backup, so run this one from
the user's machine, not the server:

```bash
mkdir -p ~/backups/adventurelog
scp vps:/srv/adventurelog/backups/* ~/backups/adventurelog/
```

To restore: `docker compose down`, `sudo rm -rf /srv/adventurelog/postgres`, recreate it as in
step 2, untar the config archive into /srv/adventurelog so .env is back before anything starts,
`docker compose up -d db`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db psql -U adventurelog -d adventurelog`, then `docker compose up -d`.
Tell the user what matters at 2am: the photographs are files in `media`, what says which trip
they belong to is rows in the database, and the two archives are worth something only together.

## 9. Updating later

New versions are listed at https://github.com/seanmorley15/AdventureLog/releases. Migrations run
at start-up and upstream asks you to back up first, so take both artifacts, then edit the two
image lines in /srv/adventurelog/compose.yml to the new tags and digests:

```bash
cd /srv/adventurelog
docker compose pull
docker compose up -d
docker compose logs --tail 30 server
```

Watch that log until the migrations settle, then re-run all five checks from step 7. This project
is on 0.x numbers and ships a few releases a year, so read the release notes first: a minor bump
here is not always a small one.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a hang, and I nearly restarted it. It is not: before
the backend serves one request it downloads a world dataset of countries, regions and cities,
then fetches a flag for every country in turn, and on a small VPS that took me several minutes
with nothing on screen but a container that would not answer. Let step 7's loop run all sixty
attempts before touching anything. The identical-looking failure is worth checking afterwards: if
`docker compose logs server` ends with exit code 137, the import was killed for memory, and the
fix is a bigger box rather than a retry.

## 11. Out of scope

- Do not set `GOOGLE_MAPS_API_KEY`. Place search falls back to OpenStreetMap's Nominatim without
  it, and the alternative is a Google Cloud project with billing attached.
- Do not configure SMTP or set `EMAIL_BACKEND`. Email verification ships off, the one account
  here is already verified, and mail from a fresh VPS is its own week of work.
- Do not enable social login, the Strava integration or the Immich integration. Each means
  registering an application somewhere else, and none is needed to log a trip.
- Do not remove `DISABLE_REGISTRATION`. On a public hostname that reopens the sign-up form.
