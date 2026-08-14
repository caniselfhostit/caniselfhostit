This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing solidtime 0.19.1 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, replace `<DOMAIN>` with the hostname whose A record already points at the
box, and replace `<ADMIN_EMAIL>` with the address you want on the first account.

Two things to decide before you start. `<DOMAIN>` becomes `APP_URL`, and solidtime rejects every
request whose Host header is neither that name nor a subdomain of it, so it has to be the name
you will actually use. `<ADMIN_EMAIL>` identifies the first account and goes into `SUPER_ADMINS`,
which is the list of people allowed into the server admin panel; this install configures no mail,
so it does not have to be a mailbox that works.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. The RAM floor is the one
to take seriously: this is three PHP containers on Laravel Octane plus a PostgreSQL, and on a
1 GB box the OOM killer arrives during the first migration rather than at a moment that explains
itself.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/solidtime /srv/solidtime/backups
sudo install -d -m 700 /srv/solidtime/postgres
sudo install -d -m 750 -o 1000 -g 1000 /srv/solidtime/storage
ls -la /srv/solidtime
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`storage` owned by uid `1000`.

If you do not: leave `postgres` owned by root on purpose, because the PostgreSQL image chowns its
own data directory the first time it starts. The `1000` on `storage` is not arbitrary either: the
image copies the application in as that uid and runs as it, so a root-owned `storage` gives you
an application that cannot write an export. Finished exports, uploaded imports and profile
photos live in that directory; everything else is in the database.

## 3. Secrets

Four secrets end up on this box. Three are written here: `APP_KEY`, which encrypts session
cookies, the Passport private key, which signs API tokens, and the PostgreSQL password. The image
mints the first two itself with a command upstream documents for exactly this, which is why only
one of the three comes from `openssl`. Step 7 has the application generate the fourth, the
password on the first account.

The `>` on the first line is doing real work: without it the command prints an application key
and a private key onto your screen instead of into the file.

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

You should see: a `3` from the `grep -c`, then a listing whose mode is `-rw-------` with your own
username twice. Replace `<DOMAIN>` and `<ADMIN_EMAIL>` in the block with your real values before
you paste it.

If you do not: anything other than `3` means the first command wrote something unexpected into
the file before the configuration was appended, so `rm /srv/solidtime/.env` and run the block
again rather than editing around it. A mode of `-rw-r--r--` means `umask 077` did not take
effect, which happens when the lines are pasted separately into different shells; run
`chmod 600 /srv/solidtime/.env` and carry on. If the file already existed from an earlier
attempt, this block has now appended a second copy of everything, which PostgreSQL will not
forgive: delete it and start the block from the top.

Do not paste that file, any value from it, or any command output containing one into this chat
window. The agent path never shows those values to anybody; this path will hand them to a third
party unless you keep them out of the box you are typing in.

Three of those lines are decisions rather than defaults. `QUEUE_CONNECTION` matters because
Laravel's default is `sync` and the queue container exists to drain that table. `MAIL_MAILER`
is set to `log` because this install configures no SMTP, so an invitation or a password-reset
link is written into the container log instead of throwing an error. The last two ship switched
on upstream and are switched off here: both post this instance's URL to app.solidtime.io twice a
day, and the telemetry one adds counts of the users, organisations, projects, clients, tasks and
time entries in your database. Those two lines are where you turn either back on.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal, so run `rm /srv/solidtime/compose.yml` and paste again in one go. A warning that
`DB_PASSWORD` is not set means step 3 wrote its file somewhere other than /srv/solidtime, or you
are not in /srv/solidtime: compose reads `.env` from the directory you run it in. Note what is
here. `x-solidtime` is a compose extension field, and the three `<<: *solidtime` lines merge it
into the three application services, so the pinned image and the shared mounts are written once
instead of three times. Do not delete the `queue` service to save memory: every time entry you
save queues a job that recalculates the spent time on its project and its task, so an install
with no worker looks perfectly healthy and reports totals that never move.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-solidtime /etc/caddy/Caddyfile`, reload,
and paste again. The `respond /register 404` line is not decoration. solidtime already refuses to
create accounts through the sign-up form because `APP_ENABLE_REGISTRATION` is false, and this
takes the form off your hostname entirely, so there are two independent answers to anybody who
finds the URL. Step 7 checks both.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8184` or `5432`.

If you do not: delete anything for those two with `sudo ufw delete allow 8184`. 8184 is bound to
127.0.0.1 by the compose file and 5432 is never published at all, so the database has no host
port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and answer the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has switched it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

PostgreSQL initialises first, then the three application containers come up. Read the next
paragraph before you worry about anything you see here: the health endpoint answers before the
database schema exists, because upstream deliberately built it to touch neither the database nor
the cache, and sessions live in a database table, so every page is a 500 until the migration has
run.

```bash
cd /srv/solidtime
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health-check/up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health-check/up; echo
docker compose exec -T solidtime php artisan migrate --force
curl -sS https://<DOMAIN>/login | grep -o '<title inertia>[^<]*</title>'
docker compose ps
```

You should see, in order: the loop reaching `200`, then `{"success":true}`, then a list of
migrations each ending in `DONE`, then `<title inertia>solidtime</title>`, then four services
with `solidtime-db` and `solidtime` reported healthy.

If you do not: a `502` from the loop means Caddy is reaching nothing on 8184, so check
`docker compose ps` and then `docker compose logs --tail 40 solidtime`. An `SQLSTATE[08006]` in
the migration means the application container never received the password from step 3, which is
step 3 written to the wrong directory. A `403` on every request means `<DOMAIN>` and the
`APP_URL` line in `.env` are different strings, and solidtime rejects the Host header it does not
recognise. A running container is not success; all of these have to pass.

In a browser, https://<DOMAIN> redirects to https://<DOMAIN>/login, which shows an `Email` box,
a `Password` box and a `Log in` button.

Now make the only account this instance starts with. There is no signup form to race, because
registration is off, so the account is created on the command line and the command prints a
generated password. That is why the output goes into a file rather than onto your screen. If you
want a display name other than your address, put it in place of the first quoted value.

```bash
cd /srv/solidtime
umask 077
docker compose exec -T solidtime php artisan admin:user:create "<ADMIN_EMAIL>" "<ADMIN_EMAIL>" --verify-email > /srv/solidtime/first-account.txt
chmod 600 /srv/solidtime/first-account.txt
umask 022
grep -c '^Password: ' /srv/solidtime/first-account.txt
```

You should see: `1`.

If you do not: `0` means the command failed and wrote its error into the file instead, so read it
with `sudo cat /srv/solidtime/first-account.txt`. `User with email ... already exists` means you
have run this twice; the first account is fine, and you can skip to reading the password below.

Read your password once and sign in before you go on, because the next block destroys the
server's copy of it:

```bash
sudo grep '^Password: ' /srv/solidtime/first-account.txt
```

You should see: one line beginning `Password: `. Put that value in your password manager now,
then sign in at https://<DOMAIN> with `<ADMIN_EMAIL>` and confirm the dashboard shows a
`This Week` card.

If you do not: an empty result means the block above did not run in this shell. Go back rather
than inventing a password here. Do not paste the value into this chat window.

Now close the front door and prove it is closed:

```bash
cd /srv/solidtime
shred -u /srv/solidtime/first-account.txt
docker compose exec -T solidtime printenv APP_ENABLE_REGISTRATION
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/users/me
```

You should see: no output from `shred`, then `false`, then `404`, then `401`.

If you do not: `true` from `printenv` means the containers are still running on an older copy of
`.env`, so run `docker compose up -d --force-recreate` and check again. A `200` on `/register`
means the Caddy block from step 5 did not land, so re-read `/etc/caddy/Caddyfile` and reload.
Anything other than `401` on the API call is worth stopping for: that call carries no token, and
`401` is the proof that nobody reads your time entries without one. The `false` and the `404`
together are the two independent answers to a stranger who finds your hostname, and the `shred`
is your generated password leaving the box.

## 8. First backup and restore

Two artifacts. The database holds every organisation, project, client, rate and time entry. The
file archive holds compose.yml, .env, the live Caddy site block and `storage`.

```bash
cd /srv/solidtime
docker compose exec -T postgres pg_dump -U solidtime -d solidtime | gzip > /srv/solidtime/backups/solidtime-db-$(date +%F).sql.gz
sudo tar -czf /srv/solidtime/backups/solidtime-files-$(date +%F).tar.gz -C /srv/solidtime compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/solidtime/backups/
```

You should see: two files, the dump a few tens of kilobytes on a fresh install and the archive
larger. Nothing goes offline: `pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error. A `tar`
that complains about `Caddyfile` means the site block from step 5 was never appended.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/solidtime
scp vps:/srv/solidtime/backups/* ~/backups/solidtime/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/solidtime/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty timesheet:

```bash
cd /srv/solidtime
sudo tar -xzf /srv/solidtime/backups/solidtime-files-$(date +%F).tar.gz -C /srv/solidtime compose.yml .env
docker compose down
sudo rm -rf /srv/solidtime/postgres
sudo install -d -m 700 /srv/solidtime/postgres
docker compose up -d postgres
sleep 45
gunzip -c /srv/solidtime/backups/solidtime-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U solidtime -d solidtime
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/login
```

You should see: a stream of `CREATE TABLE` and `COPY` lines from the restore, then `200` from the
last command, then your own account still working when you sign in.

If you do not: `password authentication failed for user "solidtime"` means `.env` was not back
before the database container initialised its empty directory, which is why the untar is the
first line rather than the last. `could not connect to server` means PostgreSQL had not finished
starting, so wait longer and run the `gunzip` line again. Understand what is at stake: an hour
you tracked and cannot produce is an hour you cannot invoice, and `APP_KEY` lives in that same
`.env`, so a database restored without it signs everyone out permanently.

## 9. Updating later

New versions are listed at https://github.com/solidtime-io/solidtime/releases. The cadence is the
load-bearing fact about this project, so read it before you decide how often to look: the first
tag was June 2024, this is still a 0.x line, and it has shipped roughly two releases a month
through 2026, with 0.19.1 landing on 7 August 2026. That is a young project moving quickly, so
read the release notes rather than skimming the version number. Take both backup artifacts first,
then edit the single `image:` line in the `x-solidtime` block of /srv/solidtime/compose.yml to
the new tag and its digest.

```bash
cd /srv/solidtime
docker compose pull
docker compose up -d
docker compose exec -T solidtime php artisan migrate --force
docker compose logs --tail 30 solidtime
```

You should see: the pull finishing, four containers recreated, migration output, and no repeating
restart in the log.

If you do not: put the old tag and digest back and run the same commands. The migration is a
separate command on purpose. Upstream offers an `AUTO_DB_MIGRATE` variable that runs it at
container start; this install leaves it unset, so an image pull can never rewrite your schema
before you have a dump of the old one. Re-run step 7's first two checks before you call the
update done.

## 10. What will probably go wrong

The first thing I did after `docker compose up -d` was load the site, get a 500, and start
pulling the compose file apart. Nothing was broken. The health endpoint answers `200` from the
moment Octane is listening, because upstream built it to touch neither the database nor the
cache, and sessions live in a table that does not exist until `php artisan migrate` has run, so
for a minute or two the box looks healthy and every page fails. Run the migration before you
believe anything. If a page still fails after it, read `docker compose logs --tail 40 solidtime`
rather than the browser: the `LOG_CHANNEL="stderr"` line from step 3 is what puts the real
exception there instead of in a file inside the container.

## 11. Out of scope

- Do not configure SMTP. The cost of `MAIL_MAILER="log"` is that resets and invitations are read
  out of the container log instead of an inbox, and a relay is its own deliverability problem.
- Do not add the Gotenberg container. It exists only so reports export as PDF, and CSV, XLSX and
  ODS exports work without it.
- Do not set `AUTO_DB_MIGRATE`, for the reason step 9 gives.
- Do not turn `APP_ENABLE_REGISTRATION` back on. This host is public, and step 7's closure is the
  only thing between the timesheet and whoever finds the hostname.
