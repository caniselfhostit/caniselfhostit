This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing AdventureLog 0.12.1 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

One thing to understand before you start, because it explains half of what can go wrong here.
AdventureLog is three containers, not one: a SvelteKit frontend, a Django backend and a PostGIS
database. The browser talks to two of them. The backend answers `/media`, `/admin`, `/static` and
`/accounts`, the frontend answers everything else, and Caddy is what splits the traffic between
them on a single hostname. That is why step 4 publishes two loopback ports instead of one.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64`, and your server's IP
on the last line.

If you do not: `amd64` is not negotiable. PostGIS is required by AdventureLog and the
postgis/postgis image publishes amd64 only, so an ARM box stops here. The 2048 MB is not padding
either, because the first boot imports a world geography dataset and gets killed for memory on a
smaller machine. An empty last line means the A record does not exist yet: add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/adventurelog /srv/adventurelog/backups
sudo install -d -m 755 /srv/adventurelog/media
sudo install -d -m 700 /srv/adventurelog/postgres
ls -la /srv/adventurelog
```

You should see: `backups` owned by you, `media` at mode `drwxr-xr-x` owned by root, and
`postgres` at mode `drwx------` owned by root.

If you do not: leave the last two owned by root on purpose. The backend container runs as root
and writes your photographs and the country flags into `media`. The PostgreSQL image chowns its
own data directory the first time it starts, and one you have already chowned to yourself makes
it refuse to initialise.

## 3. Secrets

Three secrets, all generated here on the server: the PostgreSQL password, Django's `SECRET_KEY`,
and the password for the `admin` account the backend creates on first boot. All three go into a
file only you can read. Replace `<DOMAIN>` on four of these lines with your real hostname before
you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path. Read the admin password
once with `sudo grep DJANGO_ADMIN_PASSWORD /srv/adventurelog/.env` and put it in your password
manager. It is the only credential this install has, and no mail server here can send you a reset
link.

Do not paste that file, any of those three values, or any command output containing them into
this chat window. The agent path never sees them; this path will hand them to a third party
unless you keep them out of the box you are typing in.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when
you paste the lines separately in different shells. Run `chmod 600 /srv/adventurelog/.env` and
carry on. Four of these lines are doing real work and are worth understanding.
`PUBLIC_SERVER_URL` is how the frontend reaches the backend inside the Docker network, and
upstream tells you not to change it. `DEBUG` defaults to true in the image, so setting it to
False here is what stops Django serving stack traces to strangers. `DISABLE_REGISTRATION` closes
a sign-up form that would otherwise be open to anyone who finds your hostname.
`ENABLE_RATE_LIMITS` defaults to false and switches on the throttle upstream ships for failed
logins. And if the file already existed from an earlier attempt, this block has now overwritten
all three secrets, which is fine before the database exists and a problem afterwards: the
database keeps the password it was created with, so a changed `POSTGRES_PASSWORD` on an existing
volume shows up as the backend looping on `PostgreSQL is unavailable`.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/adventurelog/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal,
so run `rm /srv/adventurelog/compose.yml` and paste again in one go. A message about
`POSTGRES_DB` being unset means you are not in /srv/adventurelog, which is where compose reads
.env for those substitutions.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-adventurelog /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you replaced in the site line but
not in the comment above it, which is harmless, or one you replaced nowhere, which is not. Caddy
issues and renews the certificate itself, and it sets the `X-Forwarded-Proto` header Django reads
to decide the request arrived over https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8168`, `8268` or `5432`.

If you do not: delete anything for those three with `sudo ufw delete allow 8168`. Both
application ports are bound to 127.0.0.1 by the compose file and 5432 is never published at all,
so the database has no host port a firewall rule could apply to. 80/tcp is there to redirect to
HTTPS and to answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which
Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back before
you go any further.

## 7. Start and verify

The backend waits for PostgreSQL, runs its Django migrations, creates the `admin` account from
the three `DJANGO_ADMIN_` values, then downloads the world country and region dataset and a flag
image for every country before it serves anything. On a fresh box that last part takes minutes
with nothing to look at, which is why the loop below is patient.

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

You should see, in order: the loop reaching `200`, then `<title>AdventureLog</title>`, then `200`
from the Django admin login page, then a small JSON object containing `"is_disabled":true`, then
a number of at least `195`.

If you do not: take them one at a time. If the loop never reaches `200`, run
`docker compose logs --tail 20 db` first, because a database that never reports healthy is step 2
done wrong, then `docker compose logs --tail 40 server`. A log ending in exit code 137 is the OOM
killer stopping the world-data import, and the fix is a bigger box, not a retry. A `502` means
Caddy is reaching nothing on 8168. The `200` from `/admin/login/` is the one worth understanding:
it proves Caddy is routing the four backend paths to 8268, and a `404` in its place means the
`@backend` matcher in step 5 did not land, which is the failure that shows up later as an album
with no photographs in it. `"is_disabled":false` means `DISABLE_REGISTRATION` did not reach the
container, and you should stop and fix that before this hostname is public for another minute. A
count under 195 means the import did not finish.

The first screen at https://<DOMAIN> is the AdventureLog landing page with a `Login` button, and
https://<DOMAIN>/login shows a form with `Username` and `Password` boxes and no sign-up link. Log
in there as `admin` with the password you read in step 3, and confirm the dashboard loads. Three
green containers in `docker compose ps` is not the same thing as a working install.

## 8. First backup and restore

Two artifacts. The database holds every trip, location and visit. The config archive holds your
photographs plus the three files that rebuild the service around them.

```bash
cd /srv/adventurelog
docker compose exec -T db pg_dump -U adventurelog -d adventurelog | gzip > /srv/adventurelog/backups/adventurelog-db-$(date +%F).sql.gz
sudo tar -czf /srv/adventurelog/backups/adventurelog-config-$(date +%F).tar.gz -C /srv/adventurelog compose.yml .env media -C /etc/caddy Caddyfile
ls -lh /srv/adventurelog/backups/
```

You should see: two files. The database dump is small on a fresh install, a few hundred kilobytes
once the world data is in it. The config archive is tens of megabytes, because the country flag
images live in `media`. Nothing goes offline: `pg_dump` snapshots a running database
consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/adventurelog
scp vps:/srv/adventurelog/backups/* ~/backups/adventurelog/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/adventurelog/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/adventurelog
docker compose down
sudo rm -rf /srv/adventurelog/postgres
sudo install -d -m 700 /srv/adventurelog/postgres
docker compose up -d db
sleep 30
gunzip -c /srv/adventurelog/backups/adventurelog-db-$(date +%F).sql.gz | docker compose exec -T db psql -U adventurelog -d adventurelog
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command.

If you do not: `role "adventurelog" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the two archives
are for before you skip this: your photographs are files inside `media` and everything that says
which trip they belong to is rows in the database, so restoring one without the other gives you
a gallery with no trips or a trip with no pictures.

## 9. Updating later

New versions are listed at https://github.com/seanmorley15/AdventureLog/releases. Migrations run
at start-up and upstream asks you to back up before updating, so take both artifacts first, then
edit the two `image:` lines in /srv/adventurelog/compose.yml to the new tags and their digests.

```bash
cd /srv/adventurelog
docker compose pull
docker compose up -d
docker compose logs --tail 30 server
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tags and digests back and run the same three commands. Then re-run all
five checks from step 7 before you call the update done. This project is on 0.x version numbers
and ships a few releases a year, so read the release notes before you move: a minor bump here is
not always a small one.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a hang, and I nearly restarted it. It is not: before
the backend serves one request it downloads a world dataset of countries, regions and cities,
then fetches a flag image for every country in turn, and on a small VPS that took me several
minutes with nothing on screen but a container that would not answer. Let step 7's loop run all
sixty attempts before touching anything. The identical-looking failure is worth checking
afterwards: if `docker compose logs server` ends with exit code 137, the import was killed for
memory, and the fix is a bigger box rather than a retry.

## 11. Out of scope

- Do not set `GOOGLE_MAPS_API_KEY`. Place search falls back to OpenStreetMap's Nominatim without
  it, and the alternative is a Google Cloud project with billing attached.
- Do not configure SMTP or set `EMAIL_BACKEND`. Email verification ships off, the one account
  here is already verified, and mail from a fresh VPS is its own week of work.
- Do not enable social login, the Strava integration or the Immich integration. Each means
  registering an application somewhere else, and none is needed to log a trip.
- Do not remove `DISABLE_REGISTRATION`. On a public hostname that reopens the sign-up form.
