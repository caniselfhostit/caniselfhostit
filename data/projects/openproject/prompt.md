You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install OpenProject 17.7.1 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say this when you ask: `<DOMAIN>` becomes `OPENPROJECT_HOST__NAME`, which every link and form
action is built from, and upstream warns that a container reached on a name it was not told
about is open to Host header injection. Its A record must already point at this server.

Upstream publishes a floor of 4096 MB of RAM and 20 GB of disk, and this Rails application holds
itself in memory twice, for the web process and for the worker. Both images publish amd64 and
arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop: the
first boot runs every migration and then the seeder, and an OOM kill in the middle leaves a
half-seeded database. If `dig +short` prints nothing, print that and stop, because Caddy cannot
get a certificate for a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/openproject /srv/openproject/backups /srv/openproject/assets
sudo install -d -m 700 /srv/openproject/postgres
ls -la /srv/openproject
```

Assert: `ls -la` shows `backups` and `assets` owned by the login user and `postgres` at mode
`drwx------` owned by root. The PostgreSQL image chowns its own data directory on first start,
so leave that one alone. `assets` holds every file attached to a work package; the container
chowns it to its internal `app` user, so its owner changing in step 7 is expected.

## 3. Secrets

Three secrets, all generated here on the server. `SECRET_KEY_BASE` signs sessions and derives
the key for encrypted database columns, `OPENPROJECT_SEED_ADMIN_USER_PASSWORD` replaces the
password the seeder would otherwise put on the `admin` account, and `DB_PASSWORD` is the
PostgreSQL password. Hex rather than base64: one travels inside a connection string, and
OpenProject parses environment values as YAML, where base64 punctuation is a hazard. Do not
print any of them and keep them out of your summary and every log line.

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

Assert: the file exists with mode `-rw-------` and the login user's name twice. Replace
`<DOMAIN>` on the first line with the real hostname before writing. Docker Compose reads this
same file for the `${DB_PASSWORD}` substitution in compose.yml. Upstream states OpenProject
refuses to start on a weak `SECRET_KEY_BASE`, and that it must stay the same across restarts or
sessions and encrypted columns become unreadable: that is why step 8 archives it with the dump.

## 4. compose.yml

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

Assert: that prints `compose OK`. Do not set `SERVER_NAME` on the container. Left unset, the
Apache inside the image renders one catch-all site that answers on any hostname; set, it renders
a second site that returns a warning page to every request whose Host does not match, including
the health check on 127.0.0.1.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-openproject, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it on its own, and it sets
`X-Forwarded-Proto: https` on every proxied request, which lets OpenProject keep
`OPENPROJECT_HTTPS=true` while speaking plain http on 8116.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8116 stays closed because compose binds it to 127.0.0.1, and 5432 because
compose never publishes it at all. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8116 or 5432.

## 7. Start and verify

The container runs every migration and then the seeder before Apache starts, so the first boot
takes minutes, not seconds. The loop below allows ten of them.

```bash
cd /srv/openproject
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health_checks/default); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health_checks/default
curl -sS https://<DOMAIN>/login | grep -o '<h1>Sign in</h1>'
docker compose exec -T openproject bundle exec rails runner 'puts "shipped-default-still-works=" + User.find_by(login: "admin").check_password?("admin").to_s'
```

Assert all four, and print what you received for each. The loop ends printing `200`. The health
response contains `PASSED`. The third command prints `<h1>Sign in</h1>`, the heading on the
first screen a human sees. The fourth prints `shipped-default-still-works=false`, the security
assert here: upstream seeds an account with login `admin` and password `admin`, and step 3
replaced that password before the seeder ran. If it prints `true`, stop and do not report
success, because a known password is sitting on a public hostname.

If any of the four misses, stop, run `docker compose logs --tail 60 openproject` and
`docker compose logs --tail 20 postgres`, and name the likely earlier step: a database that
never reports healthy points at step 2; a `502` while the log still prints migration output
wants more time, not a fix; a page of warning text about a domain means `SERVER_NAME` was set in
step 4. A running container is not success.

STOP: tell the user to read the seeded password with
`sudo grep OPENPROJECT_SEED_ADMIN_USER_PASSWORD /srv/openproject/.env`, put it in their password
manager, then sign in at https://<DOMAIN>/login as `admin`, and wait. Do not continue until they
confirm. OpenProject forces a password change on that first sign-in, so the seeded value exists
only so that no account here answers to a password printed in upstream's documentation. The
account carries `admin@example.net`, which they change under their own profile.

## 8. First backup and restore

Two artifacts. The database holds every project, work package, comment and user. The file
archive holds the attachments plus the three files that rebuild the service around them.

```bash
cd /srv/openproject
docker compose exec -T postgres pg_dump -U openproject -d openproject -x -O | gzip > /srv/openproject/backups/openproject-db-$(date +%F).sql.gz
sudo tar -czf /srv/openproject/backups/openproject-files-$(date +%F).tar.gz -C /srv/openproject compose.yml .env assets -C /etc/caddy Caddyfile
ls -lh /srv/openproject/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. A backup on the same disk is not a backup,
so run this from the user's machine:

```bash
mkdir -p ~/backups/openproject
scp vps:/srv/openproject/backups/* ~/backups/openproject/
```

To restore: `docker compose down`, `sudo rm -rf /srv/openproject/postgres`, recreate it as in
step 2, untar the file archive into /srv/openproject so .env is back before anything starts,
`docker compose up -d postgres`, wait about 30 seconds for it to report healthy, pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U openproject -d openproject`, then `docker compose up -d`.
The order matters twice: PostgreSQL takes its password from .env the moment it initialises
an empty directory, and the `SECRET_KEY_BASE` in that file decrypts the encrypted columns in the
dump, so a database restored without its .env is one nobody can read.

## 9. Updating later

New versions are listed at https://github.com/opf/openproject/releases. Take both backup
artifacts first, then edit the image line in /srv/openproject/compose.yml to the new tag and its
digest:

```bash
cd /srv/openproject
docker compose pull
docker compose up -d
docker compose logs --tail 40 openproject
```

OpenProject migrates its own database on the way up, and a minor-version jump can take as long
as the first boot. Watch that log until it settles, then re-run the health check from step 7
before calling the update done. Read the release notes before crossing a major version: those
carry migration steps this prompt does not.

## 10. What will probably go wrong

You will think the install has hung. I did. After `docker compose up -d` the container runs
every migration and then the seeder, and until that finishes there is no Apache inside it, so
https://<DOMAIN> returns a Caddy `502` while `docker compose ps` shows a healthy database beside
an app doing nothing. On a 4 GB box it was over four minutes before the first `200`, and
I had already opened the compose file twice looking for a mistake that was not there. Let the
loop in step 7 run all sixty attempts before touching anything; `docker compose logs -f
openproject` prints each migration as it lands.

## 11. Out of scope

- Do not configure SMTP. OpenProject runs without it, so every notification it would have
  emailed stays inside the web interface.
- Do not set `IMAP_ENABLED` or configure inbound mail. Creating work packages by email needs a
  mailbox the user owns and polls, a separate decision from this install.
- Do not switch to the `-slim` image or split this into upstream's nine-service compose file.
  The all-in-one container is the shape this prompt installs.
- Do not install the BIM edition. It is a different image, amd64 only, and it is for
  construction models rather than project management.
