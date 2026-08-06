This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing FitTrackee 1.3.4 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. FitTrackee needs PostGIS, and PostGIS publishes no ARM image, which
upstream says in those words. This install therefore runs on an amd64 server only. If your VPS
is an Ampere or Graviton instance, stop here: nothing below will work, and building a PostGIS
image yourself is a different afternoon.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, the word `amd64`, and your
server's IP on the last line.

If you do not: `arm64` means this install stops here, for the reason in the paragraph above. An
empty last line means the A record does not exist yet, so add it, wait a minute and run
`dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB is the
one to take seriously: this runs a Python application server next to a PostgreSQL with the
PostGIS extension loaded, and the OOM killer arriving during your first import looks like a
random failure rather than a decision you made at checkout.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/fittrackee /srv/fittrackee/backups
sudo install -d -m 755 -o 1000 -g 1000 /srv/fittrackee/uploads /srv/fittrackee/staticmap_cache
sudo install -d -m 700 /srv/fittrackee/postgres
ls -la /srv/fittrackee
```

You should see: `backups` owned by you, `uploads` and `staticmap_cache` owned by `1000`, and
`postgres` at mode `drwx------` owned by root.

If you do not: leave those ownerships alone rather than tidying them. The FitTrackee image runs
as uid 1000 and upstream requires both of those directories writable by it, so a directory
owned by you instead produces a permission error the first time a track file is uploaded, which
is hours after the thing that caused it. `postgres` stays root-owned because the database image
chowns its own data directory the first time it starts.

## 3. Secrets

Two secrets: the PostgreSQL password and `APP_SECRET_KEY`, upstream's key for JWT generation.
Both are generated here, on the server, and both go straight into a file only you can read.
Replace `<DOMAIN>` on the first line with your real hostname before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/fittrackee/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
both values, which is harmless before the database exists and a problem afterwards: PostgreSQL
keeps the password it was created with, so a changed `POSTGRES_PASSWORD` against an existing
data directory shows up as a connection failure in the FitTrackee log rather than as anything
mentioning passwords.

Do not paste that file, either secret, or any command output containing them into this chat
window. Nothing below needs you to read them out: Docker Compose reads the file itself.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/fittrackee/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal,
so run `rm /srv/fittrackee/compose.yml` and paste again in one go. Two things in that file are
worth knowing before you change anything. The database image is `postgis/postgis` rather than
plain `postgres`, because PostGIS 3.4 or later is a mandatory prerequisite and the extension is
created by that image on first start. And there is no Redis and no worker container, because
upstream states that a single-user instance turns email sending off with an empty `EMAIL_URL`
and then needs neither.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-fittrackee /etc/caddy/Caddyfile`,
reload, and paste again. Caddy requests the certificate the first time somebody asks for the
hostname and renews it on its own, so there is nothing to schedule and no path to hardcode.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8129` or `5432`.

If you do not: delete anything for `8129` with `sudo ufw delete allow 8129`. 8129 is bound to
127.0.0.1 by the compose file and 5432 is never published at all, so the database has no host
port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer the
ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

FitTrackee runs its migrations on the way up, which takes longer on the first start than on any
later one. Registration also ships open, because upstream's active-users limit is 0 and 0 means
no limit, so this block starts the service and sets that limit to one in the same pass. There is
no environment variable and no CLI command for that limit, and the API that changes it needs an
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

You should see, in order: the loop reaching `200`, then `"db available"`, then
`<title>FitTrackee</title>`, then `UPDATE 1`, then a JSON object containing `"version":"1.3.4"`,
`"max_users":1` and `"is_registration_enabled":true`.

If you do not: that last pair is not a contradiction. FitTrackee allows a registration while the
account count is under the limit, so exactly one person can still sign up, and that person is
you. A `502` where you expected `200` means Caddy is reaching nothing on 8129, so check
`docker compose ps`. If the loop never reaches `200`, run
`docker compose logs --tail 20 fittrackee-db` first, because a database that never reports
healthy is step 2 done wrong, and `docker compose logs --tail 40 fittrackee` second, where the
migrations print as they run. `"db unavailable"` from a database that is healthy points back at
step 3.

Now open https://<DOMAIN>/register in a browser and create your account: a username, your email
address, and a password of at least 8 characters.

You should see: a message telling you to check your email to confirm the account.

If you do not: read that message rather than acting on it. This server sends no mail, so no
confirmation email is coming and you cannot sign in yet. That is expected, and the next block
fixes it. Do not register a second account trying to get past it.

```bash
cd /srv/fittrackee
FTUSER=$(docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee -tAc "SELECT username FROM users ORDER BY id LIMIT 1")
echo "account: $FTUSER"
docker compose exec -T fittrackee ftcli users update "$FTUSER" --set-role owner
curl -sS https://<DOMAIN>/api/config
```

You should see: `account:` followed by the username you typed into the browser a minute ago,
CLI reporting the change, then a JSON object in which `"is_registration_enabled"` now reads
`false`.

If you do not: an empty `account:` means the registration did not go through, so go back and do
it before running this again. That `false` is the assert that matters in this whole file, and it
decides whether this install is safe to leave running: with one account against a limit of one,
FitTrackee has closed its own registration form, and an endpoint that needs no credential says
so. If it still reads `true`, stop and work out why before you put anything into this server.

Now sign in at https://<DOMAIN>.

You should see: a `Login` heading over an `Email` box and a `Password` box, with
`Forgot password?` beneath them and no `Register` link, and after signing in, your dashboard.
Opening https://<DOMAIN>/register now answers `Sorry, registration is disabled.`

If you do not: an account that still refuses your password after the CLI ran means the CLI acted
on a different username, so re-read what `account:` printed. A running container is not success;
signing in is.

## 8. First backup and restore

Two artifacts: the database holds every workout and everything computed from it, and the config
archive holds the uploaded track files plus the three files that rebuild the service.

```bash
cd /srv/fittrackee
docker compose exec -T fittrackee-db pg_dump -U fittrackee -d fittrackee | gzip > /srv/fittrackee/backups/fittrackee-db-$(date +%F).sql.gz
sudo tar -czf /srv/fittrackee/backups/fittrackee-config-$(date +%F).tar.gz -C /srv/fittrackee compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/fittrackee/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/fittrackee
scp vps:/srv/fittrackee/backups/* ~/backups/fittrackee/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/fittrackee/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty account:

```bash
cd /srv/fittrackee
docker compose down
sudo rm -rf /srv/fittrackee/postgres
sudo install -d -m 700 /srv/fittrackee/postgres
docker compose up -d fittrackee-db
sleep 40
gunzip -c /srv/fittrackee/backups/fittrackee-db-$(date +%F).sql.gz | docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/api/config
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then a config object still reading
`"is_registration_enabled":false`, which means your account survived a database that was deleted
and rebuilt.

If you do not: `role "fittrackee" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what you are proving:
the tracks live in `uploads` and everything computed from them lives in the database, so the two
archives are only useful together, and a restore that skips one of them is not a restore.

## 9. Updating later

New versions are listed at https://github.com/SamR1/FitTrackee/releases. Migrations run at
start-up, so upstream asks you to back up before changing the image. Take both artifacts, then
edit the `image:` line in /srv/fittrackee/compose.yml to the new tag and its digest.

```bash
cd /srv/fittrackee
docker compose pull
docker compose up -d
docker compose logs --tail 30 fittrackee
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/api/config` check from step 7 and confirm `version` matches the tag you pinned, because a
container that answers on the health endpoint can still have stopped halfway through a
migration.

## 10. What will probably go wrong

You will register, get told to check your email, find nothing, and conclude the install is
broken. I did. It is not: FitTrackee creates every account inactive and mails a confirmation
link, this server sends no mail on purpose, and the sign-in screen answers an inactive account
with a message that reads exactly like a wrong password. The `ftcli users update` command in
step 7 clears it, and it has to run after the account exists rather than before. The same
command activates anyone you add later, and that is the whole account system here.

## 11. Out of scope

- Do not configure SMTP, and do not add Redis or the Dramatiq worker. Upstream states a
  single-user instance runs with an empty `EMAIL_URL` and needs neither; adding them is two more
  services for mail one CLI command already replaces.
- Do not set `WEATHER_API_PROVIDER` or `WEATHER_API_KEY`. Weather on a workout needs an account
  with a third-party forecast service, a signup this install exists to avoid.
- Do not set `TILE_SERVER_URL` to a keyed provider. The default OpenStreetMap tile server needs
  no account, and its usage policy is your decision.
- Do not enable OAuth 2.0 applications. That connects third-party clients later, and it is not
  part of getting the first workout onto this server.
