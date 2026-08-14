You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install solidtime 0.19.1 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` becomes `APP_URL`, and solidtime rejects every request whose Host is
neither it nor a subdomain of it, so its A record has to point here already. `<ADMIN_EMAIL>`
goes on the first account and into `SUPER_ADMINS`; no mail is configured, so it identifies an
account, not a mailbox.

solidtime needs 2048 MB of RAM available and 10 GB free on /srv: three PHP containers on Laravel
Octane plus a PostgreSQL. Both images have amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
name that does not resolve, and failed attempts hit a rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/solidtime /srv/solidtime/backups
sudo install -d -m 700 /srv/solidtime/postgres
sudo install -d -m 750 -o 1000 -g 1000 /srv/solidtime/storage
ls -la /srv/solidtime
```

Assert: `backups` owned by the login user, `postgres` at mode `700` owned by root, `storage`
owned by uid `1000`. Leave `postgres` alone, the database image chowns it on first start. The
`1000` is the uid the image runs as, and root-owned `storage` cannot be written.

## 3. Secrets

Four secrets end up here. Three are written now: `APP_KEY` for session cookies, the Passport
private key that signs API tokens, and the PostgreSQL password. The image mints the first two
with a command upstream documents, so only the third comes from `openssl`; step 7 has the
application generate the fourth. Print none of them and keep them out of every log. The redirect
on the first line is what keeps the minted keys off the terminal.

```bash
umask 077
docker run --rm solidtime/solidtime:0.19.1@sha256:419ae59a806bcd6b15e9b637b5cee4800f7eb8f4941e20f4c5416d71acd5f1dd php artisan self-host:generate-keys > /srv/solidtime/.env
grep -c -E '^(APP_KEY|PASSPORT_PRIVATE_KEY|PASSPORT_PUBLIC_KEY)=' /srv/solidtime/.env
cat >> /srv/solidtime/.env <<EOF
APP_ENV="production"
APP_DEBUG="false"
APP_URL="https://<DOMAIN>"
APP_FORCE_HTTPS="true"
APP_ENABLE_REGISTRATION="false"
TRUSTED_PROXIES="172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"
SUPER_ADMINS="<ADMIN_EMAIL>"
LOG_CHANNEL="stderr"
LOG_LEVEL="info"
DB_CONNECTION="pgsql"
DB_HOST="postgres"
DB_DATABASE="solidtime"
DB_USERNAME="solidtime"
DB_PASSWORD="$(openssl rand -hex 32)"
QUEUE_CONNECTION="database"
MAIL_MAILER="log"
SCHEDULING_TASK_SELF_HOSTING_CHECK_FOR_UPDATE="false"
SCHEDULING_TASK_SELF_HOSTING_TELEMETRY="false"
EOF
chmod 600 /srv/solidtime/.env
umask 022
ls -l /srv/solidtime/.env
```

Assert both and print both: `grep -c` prints `3`, and the file is mode `-rw-------`. Anything
but `3` means the image wrote something unexpected into the file, so delete it and run the block
again rather than editing around it.

Three lines are decisions. `QUEUE_CONNECTION` matters because Laravel defaults to `sync` and the
queue container exists to drain that table. `MAIL_MAILER="log"` puts invitations and reset links
in the container log instead of throwing, since no SMTP is configured. The last two ship on
upstream and are off here: both post this instance's URL to app.solidtime.io twice a day, and
telemetry adds counts of the users, organisations, projects and time entries in the database.
Tell the user those two lines turn either back on.

## 4. compose.yml

```bash
cat > /srv/solidtime/compose.yml <<'EOF'
# solidtime · the deterministic fallback. Authored by caniselfhostit from the
# upstream self-hosting documentation and the packaging at the pinned tag:
#   docker guide ... https://docs.solidtime.io/self-hosting/guides/docker
#   configuration .. https://docs.solidtime.io/self-hosting/configuration
#   image build .... https://github.com/solidtime-io/solidtime/blob/v0.19.1/docker/prod/Dockerfile
#
# Four services, three of them the same image: CONTAINER_MODE picks HTTP,
# scheduler or queue worker, and there is no combined mode. Upstream's example
# ships a fifth, Gotenberg, only so reports export as PDF. Upstream pins
# postgres:15; their test matrix runs 15, 16 and 17, so this takes the newest.
# Digests read 2026-08-14; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

x-solidtime: &solidtime
  image: solidtime/solidtime:0.19.1@sha256:419ae59a806bcd6b15e9b637b5cee4800f7eb8f4941e20f4c5416d71acd5f1dd
  restart: unless-stopped
  # The image copies the application in as uid 1000 and runs as it.
  user: "1000:1000"
  env_file: /srv/solidtime/.env
  volumes:
    # framework cache, shared; then the half worth keeping: exports/imports.
    - solidtime-storage:/var/www/html/storage
    - /srv/solidtime/storage:/var/www/html/storage/app
  depends_on:
    postgres:
      condition: service_healthy

services:
  postgres:
    image: postgres:17.11-alpine@sha256:5d61573b31c206ae538c85893edeb6e320e1a9ffd838c0f9dca927fb6f765fa4
    container_name: solidtime-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: solidtime
      POSTGRES_USER: solidtime
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/solidtime/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U solidtime -d solidtime"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other containers.

  solidtime:
    <<: *solidtime
    container_name: solidtime
    environment:
      CONTAINER_MODE: http
    ports:
      # Loopback only: the host's Caddy is all that reaches 8184.
      - "127.0.0.1:8184:8000"
    healthcheck:
      test: ["CMD", "curl", "--fail", "http://localhost:8000/health-check/up"]
      start_period: 60s
      interval: 15s
      retries: 10

  scheduler:
    <<: *solidtime
    environment:
      CONTAINER_MODE: scheduler
    healthcheck:
      # Ships with the image: asks supervisord if its process still runs.
      test: ["CMD", "healthcheck"]
      start_period: 60s
      interval: 30s
      retries: 5

  queue:
    <<: *solidtime
    environment:
      CONTAINER_MODE: worker
      # Worker mode refuses to start without this.
      WORKER_COMMAND: "php /var/www/html/artisan queue:work"
    healthcheck:
      test: ["CMD", "healthcheck"]
      start_period: 60s
      interval: 30s
      retries: 5

volumes:
  solidtime-storage:
EOF
cd /srv/solidtime && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Four services, one published port. `x-solidtime` is a
compose extension field the three application services merge in, so the pin is written once. Do
not delete `queue`: every saved time entry queues a job recalculating spent time on its project
and task, so without a worker the install looks fine and reports totals that never move.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy it first: a syntax error takes down every other site here.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-solidtime
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# solidtime · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.solidtime.io/self-hosting/configuration and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# APP_URL in .env, and the app rejects any Host that is neither it nor a
# subdomain of it.

<DOMAIN> {
	# APP_ENABLE_REGISTRATION is already false in the app; this also takes the
	# signup form off the hostname.
	respond /register 404

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy: written untested it blanks a single-page app.
	# No `encode`: the image runs Octane on FrankenPHP, whose own Caddy already
	# compresses. 8184 is the loopback port compose publishes here, not a
	# container port, and not open in the firewall.
	reverse_proxy 127.0.0.1:8184
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-solidtime, reload, and report what it objected to.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8184 stays closed because compose binds it to 127.0.0.1, 5432 because compose never
publishes it. Assert: `ufw status verbose` prints `Status: active` and those three rules, with
none for 8184 or 5432.

## 7. Start and verify

The health endpoint answers before the schema exists, because upstream wrote it to touch neither
the database nor the cache, and sessions live in a database table, so the login page is a 500
until the migration has run.

```bash
cd /srv/solidtime
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health-check/up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health-check/up; echo
docker compose exec -T solidtime php artisan migrate --force
curl -sS https://<DOMAIN>/login | grep -o '<title inertia>[^<]*</title>'
```

Assert all four and print what you received: the loop ends on `200`, the health body is
`{"success":true}`, the migration prints migrations each ending `DONE` with no exception, and
the title prints `<title inertia>solidtime</title>`. If any misses, stop, run
`docker compose logs --tail 40 solidtime`, and name the likely earlier step: `502` is Caddy
reaching nothing on 8184, `SQLSTATE[08006]` is a container that never got step 3's password, and
a `403` on every request means `<DOMAIN>` and `APP_URL` differ. A running container is not
success.

Now create the only account this instance starts with. Registration is off, so there is no
signup form to race: accounts are made on the command line. The command generates a password and
prints it, so the output goes to a file. Ask the user for a display name first if they
want one other than their address.

```bash
umask 077
docker compose exec -T solidtime php artisan admin:user:create "<ADMIN_EMAIL>" "<ADMIN_EMAIL>" --verify-email > /srv/solidtime/first-account.txt
chmod 600 /srv/solidtime/first-account.txt
umask 022
grep -c '^Password: ' /srv/solidtime/first-account.txt
```

Assert: the count prints `1`. `--verify-email` marks the address verified without sending
anything, which is what makes the account usable with no mail.

STOP: tell the user to read their password with
`sudo grep '^Password: ' /srv/solidtime/first-account.txt`, put it in their password manager,
sign in at https://<DOMAIN> as `<ADMIN_EMAIL>`, and confirm the dashboard shows a `This Week`
card. Do not continue until they confirm. The next block destroys that file, so their password
manager has to hold it first.

Once they confirm, close the front door and prove it is closed:

```bash
cd /srv/solidtime
shred -u /srv/solidtime/first-account.txt
docker compose exec -T solidtime printenv APP_ENABLE_REGISTRATION
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/users/me
```

Assert all four and print each value. `shred -u` exits 0, taking the generated password off the
box. `printenv` prints `false`, the application's own answer: its sign-up action refuses to
create a user while that is off. `/register` prints `404`, because step 5 took the form off the
hostname, so both layers agree. The API call prints `401`, the assert that nothing reads time
entries without a token. Anything else stops the install: a `200` on `/register` means step 5
did not land, and `true` from `printenv` needs `docker compose up -d --force-recreate`.

## 8. First backup and restore

Two artifacts: a dump of the database that holds every organisation, project, client, rate and
time entry, and an archive of compose.yml, .env, the live Caddy site block and `storage`.

```bash
cd /srv/solidtime
docker compose exec -T postgres pg_dump -U solidtime -d solidtime | gzip > /srv/solidtime/backups/solidtime-db-$(date +%F).sql.gz
sudo tar -czf /srv/solidtime/backups/solidtime-files-$(date +%F).tar.gz -C /srv/solidtime compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/solidtime/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing goes offline: `pg_dump`
snapshots a running database consistently. A backup on the same disk is not a backup, so run
this on the user's machine:

```bash
mkdir -p ~/backups/solidtime
scp vps:/srv/solidtime/backups/* ~/backups/solidtime/
```

To restore, in this order. Untar the file archive into /srv/solidtime first, so `.env` is back
before any container starts: PostgreSQL takes its password from it the moment it initialises an
empty data directory. Then `docker compose down`, `sudo rm -rf /srv/solidtime/postgres`,
recreate it as in step 2, `docker compose up -d postgres`, wait for healthy, then
`gunzip -c /srv/solidtime/backups/solidtime-db-<date>.sql.gz | docker compose exec -T postgres psql -U solidtime -d solidtime`,
then `docker compose up -d` and re-run step 7's checks. A database restored without that `.env`
signs everyone out for good, because `APP_KEY` is in it.

## 9. Updating later

New versions are at https://github.com/solidtime-io/solidtime/releases. Say the cadence to the
user, it is the load-bearing fact here: the first tag was June 2024, this is still a 0.x
line, and it has shipped roughly two releases a month through 2026, with 0.19.1 landing on 7
August 2026. Read the notes rather than skimming the number, back up, then edit the one
`image:` line in `x-solidtime` to the new tag and digest:

```bash
cd /srv/solidtime
docker compose pull
docker compose up -d
docker compose exec -T solidtime php artisan migrate --force
docker compose logs --tail 30 solidtime
```

The migration is separate on purpose: upstream's `AUTO_DB_MIGRATE` variable runs it at container
start, and leaving that unset means an image pull can never rewrite the schema before there is a
dump of the old one. Re-run step 7's checks before calling it done.

## 10. What will probably go wrong

The first thing I did after `docker compose up -d` was load the site, get a 500, and start
pulling the compose file apart. Nothing was broken. The health endpoint answers `200` from the
moment Octane is listening, because upstream built it to touch neither the database nor the
cache, and sessions live in a table that does not exist until `php artisan migrate` has run, so
for a minute or two the box looks healthy and every page fails. If a page still fails after the
migration, read `docker compose logs --tail 40 solidtime`: step 3's `LOG_CHANNEL` puts the real
exception there rather than in the browser.

## 11. Out of scope

- Do not configure SMTP. The cost of `MAIL_MAILER="log"` is that resets and invitations are read
  out of the container log, not an inbox, and a relay is its own deliverability problem.
- Do not add the Gotenberg container. It exists only so reports export as PDF, and CSV, XLSX and
  ODS exports work without it.
- Do not set `AUTO_DB_MIGRATE`, for the reason step 9 gives.
- Do not turn `APP_ENABLE_REGISTRATION` back on. This host is public, and step 7's closure is
  the only thing between the timesheet and whoever finds the hostname.
