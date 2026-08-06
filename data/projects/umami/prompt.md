You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Umami 3.2.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname ends up
inside the tracking snippet pasted into every page they measure, so moving it later means
editing every one of those pages.

Umami needs 1024 MB of RAM available and 5 GB free on /srv. Both images publish amd64 and
arm64. Measure all four before anything else:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve, and failed attempts count against a rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/umami /srv/umami/backups
sudo install -d -m 700 /srv/umami/postgres
ls -la /srv/umami
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `drwx------`
owned by root. The PostgreSQL image chowns its own data directory the first time it starts, so
leave that one alone. Umami keeps nothing on disk: every account, website and pageview is a row
in that database.

## 3. Secrets

Three secrets, all generated here on the server. `DB_PASSWORD` is the PostgreSQL password,
`APP_SECRET` signs the login tokens, and `ADMIN_PASSWORD` is what step 7 puts on the built-in
admin account in place of the password the image ships with. Hex rather than base64: two of
them travel inside a URL and the third inside a JSON body, and hex needs no escaping in
either. Do not print any of them, do not repeat them in your summary, and keep them out of
every log line.

```bash
umask 077
cat > /srv/umami/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
APP_SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/umami/.env
umask 022
ls -l /srv/umami/.env
```

Assert: the file exists with mode `-rw-------` and the login user's name twice. Docker Compose
reads it for the `${...}` substitutions in compose.yml whenever it runs from /srv/umami, so
the first two values reach the containers as environment variables and the file itself is
never mounted. `ADMIN_PASSWORD` is not an Umami setting and no container sees it: step 7 hands
it to the running API, and it stays here as the user's copy.

## 4. compose.yml

```bash
cat > /srv/umami/compose.yml <<'EOF'
# Umami · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install ............ https://docs.umami.is/docs/install
#   variable reference . https://docs.umami.is/docs/environment-variables
#   hosting shapes ..... https://docs.umami.is/docs/guides/hosting
#   heartbeat route .... https://github.com/umami-software/umami/blob/v3.2.0/src/app/api/heartbeat/route.ts
#
# Two services: Umami and the PostgreSQL holding every account, website and
# pageview. Version 3 is a PostgreSQL-only build, so the tag carries no database
# flavour and DATABASE_URL is a postgresql:// string. Umami writes nothing to
# disk, which is why only the database has a volume. Tags and digests were read
# from the registries on 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: umami-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: umami
      POSTGRES_USER: umami
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/umami/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U umami -d umami"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  umami:
    image: ghcr.io/umami-software/umami:3.2.0@sha256:8edfe4beaef13f9d1300619fa264ef250a3688df9cc54d24ca830ca31cb475ec
    container_name: umami
    restart: unless-stopped
    # init reaps the child processes the migration step leaves behind.
    init: true
    environment:
      # Docker Compose substitutes both values from /srv/umami/.env, which is
      # mode 600 and is never mounted into the container.
      DATABASE_URL: postgresql://umami:${DB_PASSWORD}@postgres:5432/umami
      APP_SECRET: ${APP_SECRET}
      # No anonymous usage pings leave this box.
      DISABLE_TELEMETRY: "1"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/api/heartbeat || exit 1"]
      interval: 10s
      retries: 18
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8105.
      - "127.0.0.1:8105:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/umami && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Version 3 dropped the MySQL build, so the tag reads `3.2.0`
with no database prefix, which is not what the older `postgresql-v2` guides show. The container
listens on 3000 and compose publishes it on 8105, loopback only.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-umami
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Umami · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.umami.is/docs/guides/hosting and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also the address inside the tracking snippet on every page you measure, so
# changing it later means editing every site you track.

<DOMAIN> {
	# The dashboard is a JavaScript bundle worth compressing. The tracker
	# script and /api/send ride the same site block; Umami sets its own
	# Access-Control-Allow-Origin on both, so there is no CORS work here.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy here: Umami sends its own on every response,
	# and a second one would be intersected with it rather than replace it.

	# 8105 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8105
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-umami, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it on its own. Nothing to schedule.

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
443/udp is HTTP/3. 8105 stays closed because compose binds it to 127.0.0.1, and 5432 stays
closed because compose never publishes it at all. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8105 or 5432.

## 7. Start and verify

Umami applies its own schema migrations on the way up, which is also what creates the built-in
admin account. First bring it up and prove it answers:

```bash
cd /srv/umami
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/heartbeat); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/heartbeat
curl -sS https://<DOMAIN>/login | grep -o '<title>[^<]*</title>'
```

Assert all three, and print what you received for each: the loop ends on `200`, the heartbeat
prints `{"ok":true}`, and the last command prints `<title>Login | Umami</title>`. If any of the
three misses, stop, run `docker compose logs --tail 40 umami` and
`docker compose logs --tail 20 postgres`, and name the likely earlier step: a database that
never reports healthy points at step 2, and a `502` where a `200` was expected means Caddy is
reaching nothing on 8105. One miss is soft: if both heartbeat checks passed and only the title
line printed nothing, the framework streamed the title later into the page body, so print the
start of `curl -sS https://<DOMAIN>/login`, confirm HTML is coming back, say so, and carry on:
the login checks below prove the page for real. A running container is not success.

Now close the account the image ships with. Upstream documents it as username `admin` with a
fixed published password, so it is a known credential on a public hostname until this runs:

```bash
cd /srv/umami
login=$(curl -sS -X POST https://<DOMAIN>/api/auth/login -H 'Content-Type: application/json' --data '{"username":"admin","password":"umami"}')
token=$(printf '%s' "$login" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
userid=$(printf '%s' "$login" | sed -n 's/.*"user":{"id":"\([^"]*\)".*/\1/p')
[ -n "$token" ] && [ -n "$userid" ] && echo "logged in"
printf '{"password":"%s"}' "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' /srv/umami/.env)" | curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://<DOMAIN>/api/users/${userid}" -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' --data-binary @-
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/auth/login -H 'Content-Type: application/json' --data '{"username":"admin","password":"umami"}'
unset login token userid
```

Assert all three: `logged in`, then `200` from the update, then `401` from the second login.
That `401` is the security assert in this block and it decides whether this install is safe to
leave running. If the first line does not print `logged in`, the response shape changed and
nothing below it ran correctly, so stop there. If the last line prints anything other than
`401`, the shipped password still works: stop, say so plainly, and do not report success.
Neither the new password nor the token goes into your output, and the password was piped into
curl from the file rather than written on a command line so it never reaches the process list.

The first screen at https://<DOMAIN>/login shows the wordmark `umami` over a `Username` box, a
`Password` box and a `Login` button.

STOP: tell the user to read their password with `grep ADMIN_PASSWORD /srv/umami/.env`, put it
in their password manager, sign in at https://<DOMAIN>/login as `admin`, and confirm they see
the dashboard. Wait. Do not continue until they confirm.

## 8. First backup and restore

Two artifacts. The database holds the accounts, the websites and every pageview. The config
archive holds the files that rebuild the service around it.

```bash
cd /srv/umami
docker compose exec -T postgres pg_dump -U umami -d umami | gzip > /srv/umami/backups/umami-db-$(date +%F).sql.gz
sudo tar -czf /srv/umami/backups/umami-config-$(date +%F).tar.gz -C /srv/umami compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/umami/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently.

A backup on the same disk as the data is not a backup. Run this one from the user's machine,
not the server:

```bash
mkdir -p ~/backups/umami
scp vps:/srv/umami/backups/* ~/backups/umami/
```

To restore: `docker compose down`, `sudo rm -rf /srv/umami/postgres`, recreate that directory
as in step 2, untar the config archive into /srv/umami so .env is back before anything starts,
`docker compose up -d postgres`, wait about 30 seconds for it to report healthy, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U umami -d umami`,
then `docker compose up -d`. Tell the user why the order matters: PostgreSQL takes its password
from .env the moment it initialises an empty directory, so an archive restored second leaves
them a database with a blank password that will not start.

## 9. Updating later

New versions are listed at https://github.com/umami-software/umami/releases. Take both backup
artifacts first, then edit the image line in /srv/umami/compose.yml to the new tag and its
digest:

```bash
cd /srv/umami
docker compose pull
docker compose up -d
docker compose logs --tail 30 umami
```

Umami migrates its own schema on the way up, so watch that log until it settles, then re-run
the heartbeat check from step 7 before calling the update done. After a major version jump,
upstream tells you to run `ANALYZE;` against the database: the migration leaves the query
planner with stale statistics and the dashboard stays slow until it does not.

## 10. What will probably go wrong

The first `docker compose up -d` looked hung to me. The container runs every schema migration
before it answers anything, and on a small VPS that took over a minute during which
https://<DOMAIN> returned a Caddy `502` and the log printed nothing I recognised. I had already
started re-reading the compose file for a mistake that was not there. The health loop in step 7
exists for this: give it the full 30 attempts before touching anything, and start reading logs
only once the loop has run out.

## 11. Out of scope

- Do not configure SMTP. Umami sends no mail here, and scheduled email reports are a
  hosted-service feature rather than something a mail server would switch on.
- Do not set `TRACKER_SCRIPT_NAME` or `COLLECT_API_ENDPOINT` to dodge ad blockers. Those
  rename the script and the collector, so the snippet on every tracked page has to be rewritten
  to match, and the user has not tracked anything yet.
- Do not add Redis. Umami runs without it, and the extra container buys session caching this
  install has no traffic to need.
- Do not create additional users or teams. The user signs in as `admin` and decides that.
