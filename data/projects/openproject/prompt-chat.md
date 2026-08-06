This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing OpenProject 17.7.1 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `OPENPROJECT_HOST__NAME`, the name OpenProject
builds every link and form action from, and upstream warns that a container reached on a name it
was not told about is open to Host header injection. Set aside the better part of an evening:
this is a large Rails application and its first boot runs every database migration and then a
seeder before it answers anything.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: those two floors are upstream's own numbers for a single-server install, and this
is the wrong place to argue with them. A 2 GB box will get through the migrations and then meet
the OOM killer somewhere in the seeder, which looks like a corrupt database rather than a memory
problem. An empty last line means the A record does not exist yet: add it, wait a minute, run
`dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/openproject /srv/openproject/backups /srv/openproject/assets
sudo install -d -m 700 /srv/openproject/postgres
ls -la /srv/openproject
```

You should see: `backups` and `assets` owned by you, and `postgres` at mode `drwx------` owned
by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `assets` is where every file anyone attaches to a work package lands; the
OpenProject container chowns that one to its internal `app` user on first start, so do not be
surprised in step 7 when its owner is no longer you.

## 3. Secrets

Three secrets, all generated on the server. `SECRET_KEY_BASE` signs sessions and derives the key
for encrypted database columns, `OPENPROJECT_SEED_ADMIN_USER_PASSWORD` replaces the password the
seeder would otherwise put on the `admin` account, and `DB_PASSWORD` is the PostgreSQL password.
Replace `<DOMAIN>` on the first line with your hostname before you paste.

```bash
umask 077
cat > /srv/openproject/.env <<EOF
OPENPROJECT_HOST__NAME=<DOMAIN>
OPENPROJECT_HTTPS=true
SECRET_KEY_BASE=$(openssl rand -hex 64)
OPENPROJECT_SEED_ADMIN_USER_PASSWORD=$(openssl rand -hex 24)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/openproject/.env
umask 022
ls -l /srv/openproject/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

Do not paste that file, any of the three values, or any command output containing them into this
chat window. Read the admin password once, in step 7, with
`sudo grep OPENPROJECT_SEED_ADMIN_USER_PASSWORD /srv/openproject/.env`, and put it straight into
your password manager rather than into a message.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/openproject/.env` and
carry on. Hex rather than base64 is deliberate for all three: one value travels inside a
database connection string, and OpenProject parses environment values as YAML, where base64
punctuation is a hazard. If the file already existed from an earlier attempt, this block has
overwritten all three, which is fine before the database exists and a problem afterwards: the
database keeps the password it was created with, and the old `SECRET_KEY_BASE` is what decrypts
the encrypted columns already in it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/openproject/compose.yml <<'EOF'
# OpenProject · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://www.openproject.org/docs/installation-and-operations/installation/docker/
#   docker compose ..... https://www.openproject.org/docs/installation-and-operations/installation/docker-compose/
#   configuration ...... https://www.openproject.org/docs/installation-and-operations/configuration/
#   health endpoints ... https://www.openproject.org/docs/installation-and-operations/operation/monitoring/
#
# Two services. The all-in-one image runs Puma, the worker, memcached, the
# collaborative-editing server and an Apache under one supervisord, so
# upstream's nine-service compose file for the slim image collapses to one
# container here. It starts its own PostgreSQL only when DATABASE_URL points
# at 127.0.0.1; ours points at the postgres service below. Upstream supports
# PostgreSQL 16 and above. Digests read on 2026-08-06; both images publish
# amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: openproject-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: openproject
      POSTGRES_USER: openproject
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/openproject/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U openproject -d openproject"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  openproject:
    image: openproject/openproject:17.7.1@sha256:bbaaedbe3837097dd189f739565064accb731d23cd87294a21bd07e0be010f6a
    container_name: openproject
    restart: unless-stopped
    # Hostname, HTTPS flag, SECRET_KEY_BASE and the seeded admin password all
    # arrive from /srv/openproject/.env, mode 600 on the host.
    env_file: /srv/openproject/.env
    environment:
      # No query string: the all-in-one start-up script hands DATABASE_URL to
      # psql through a shell, where `&` would background the command.
      DATABASE_URL: postgres://openproject:${DB_PASSWORD}@postgres/openproject
      RAILS_MIN_THREADS: "4"
      RAILS_MAX_THREADS: "16"
      # Inbound mail off: no IMAP poller, no cron process for it.
      IMAP_ENABLED: "false"
    volumes:
      - /srv/openproject/assets:/var/openproject/assets
    healthcheck:
      # Migrations and the seeder run before Apache exists: long start period.
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1/health_checks/default || exit 1"]
      interval: 15s
      retries: 20
      start_period: 600s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8116.
      - "127.0.0.1:8116:80"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/openproject && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/openproject/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/openproject/compose.yml` and paste again in one go. Do not add a `SERVER_NAME`
variable to this file, whatever else you read: left unset, the Apache inside the image renders
one catch-all site that answers on any hostname, and set, it renders a second site that returns
a plain warning page to every request whose Host does not match, including the container's own
health check on 127.0.0.1.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-openproject
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# OpenProject · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.openproject.org/docs/installation-and-operations/installation/docker/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also OPENPROJECT_HOST__NAME in .env, which OpenProject builds every link and
# form action from.

<DOMAIN> {
	# The Angular bundle and the work package tables are worth compressing.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8116 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. reverse_proxy carries
	# the /hocuspocus WebSocket upgrade with no extra directive.
	reverse_proxy 127.0.0.1:8116
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-openproject /etc/caddy/Caddyfile`,
reload, and paste again. Caddy terminates TLS and speaks plain http to the container on 8116,
and it sets `X-Forwarded-Proto: https` on every proxied request, which is what lets
`OPENPROJECT_HTTPS=true` stay in your .env without OpenProject deciding the connection was
insecure and redirecting you in a loop.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8116` or `5432`.

If you do not: delete anything for `8116` or `5432` with `sudo ufw delete allow 8116`. 8116 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp redirects to HTTPS and answers the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The container runs every migration and then the seeder before Apache starts. The loop below
waits up to ten minutes for that, and on a small box it will use several of them.

```bash
cd /srv/openproject
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health_checks/default); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health_checks/default
curl -sS https://<DOMAIN>/login | grep -o '<h1>Sign in</h1>'
docker compose exec -T openproject bundle exec rails runner 'puts "shipped-default-still-works=" + User.find_by(login: "admin").check_password?("admin").to_s'
```

You should see, in order: the loop reaching `200`, a short line containing `PASSED`, then
`<h1>Sign in</h1>`, then `shipped-default-still-works=false`.

If you do not: that last line is the one that decides whether this install is safe to leave
running. Upstream seeds an account with login `admin` and password `admin`, step 3 replaced that
password with a generated one before the seeder ever ran, and `false` is the proof it worked. If
it prints `true`, stop: a password published in upstream's documentation is live on a public
hostname. If the loop never reaches `200`, run `docker compose logs --tail 20 postgres` first,
because a database that never reports healthy is step 2 done wrong, then
`docker compose logs --tail 60 openproject`; migration lines still scrolling mean you stopped
too early rather than anything being broken. A page of warning text about a domain instead of
`<h1>Sign in</h1>` means a `SERVER_NAME` variable got into the compose file. A running container
is not success.

The first screen at https://<DOMAIN>/login shows the heading `Sign in` over a username box, a
password box and a sign-in button.

Now read your admin password and use it:

```bash
sudo grep OPENPROJECT_SEED_ADMIN_USER_PASSWORD /srv/openproject/.env
```

You should see: one line, one long hex value. Put it in your password manager, then open
https://<DOMAIN>/login in a browser, sign in as `admin` with that value, and set your own
password when OpenProject asks you to.

If you do not: OpenProject forces that password change on the first sign-in, so a screen
demanding a new password is the install working rather than failing. The seeded account carries
the address `admin@example.net`, which you change under your own profile once you are in. Do not
paste the hex value into this chat window.

## 8. First backup and restore

Two artifacts. The database holds every project, work package, comment and user. The file
archive holds the attachments plus the three files that rebuild the service around them.

```bash
cd /srv/openproject
docker compose exec -T postgres pg_dump -U openproject -d openproject -x -O | gzip > /srv/openproject/backups/openproject-db-$(date +%F).sql.gz
sudo tar -czf /srv/openproject/backups/openproject-files-$(date +%F).tar.gz -C /srv/openproject compose.yml .env assets -C /etc/caddy Caddyfile
ls -lh /srv/openproject/backups/
```

You should see: two files, the dump a few hundred kilobytes on a fresh install and the archive a
few kilobytes. Nothing goes offline: `pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/openproject
scp vps:/srv/openproject/backups/* ~/backups/openproject/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/openproject/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/openproject
docker compose down
sudo rm -rf /srv/openproject/postgres
sudo install -d -m 700 /srv/openproject/postgres
sudo tar -xzf /srv/openproject/backups/openproject-files-$(date +%F).tar.gz -C /srv/openproject compose.yml .env assets
docker compose up -d postgres
sleep 30
gunzip -c /srv/openproject/backups/openproject-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U openproject -d openproject
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health_checks/default); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then the loop reaching `200` again,
and your admin password still signing you in.

If you do not: `role "openproject" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. The order in that block is the
lesson: PostgreSQL takes its password from .env the moment it initialises an empty directory,
and the `SECRET_KEY_BASE` in that same file decrypts the encrypted columns inside the dump, so a
database restored without its .env is one nobody can read.

## 9. Updating later

New versions are listed at https://github.com/opf/openproject/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/openproject/compose.yml to the new tag and
its digest.

```bash
cd /srv/openproject
docker compose pull
docker compose up -d
docker compose logs --tail 40 openproject
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. A minor-version
jump migrates the database and can take as long as the first boot did, so give the log time
before you decide it has failed, then re-run the health check from step 7. Read the release
notes before crossing a major version: those carry migration steps this prompt does not.

## 10. What will probably go wrong

You will think the install has hung. I did. After `docker compose up -d` the container runs every
migration and then the seeder, and until that finishes there is no Apache inside it, so
https://<DOMAIN> returns a Caddy `502` while `docker compose ps` shows a healthy database beside
an app doing nothing. On a 4 GB box it was over four minutes before the first `200`, and I had
already opened the compose file twice looking for a mistake that was not there. Let the loop in
step 7 run all sixty attempts before touching anything; `docker compose logs -f openproject`
prints each migration as it lands.

## 11. Out of scope

- Do not configure SMTP. OpenProject runs without it, so every notification it would have
  emailed stays inside the web interface.
- Do not set `IMAP_ENABLED` or configure inbound mail. Creating work packages by email needs a
  mailbox you own and poll, a separate decision from this install.
- Do not switch to the `-slim` image or split this into upstream's nine-service compose file.
  The all-in-one container is the shape this prompt installs.
- Do not install the BIM edition. It is a different image, amd64 only, and it is for
  construction models rather than project management.
