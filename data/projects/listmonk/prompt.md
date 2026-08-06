You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install listmonk 6.2.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. It goes inside every campaign they send, in the
unsubscribe link and the archive URL, and a hostname swapped out later starts its sending
reputation from zero.

Ask a second question in the same breath and wait for both answers: do they have an SMTP relay
account, with a host, a port, a username and a password. listmonk delivers nothing itself. It
hands finished messages to someone else's mail server, and step 7 waits on those four.

listmonk needs 1024 MB of RAM available and 5 GB free on /srv. Both images publish amd64 and
arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/listmonk /srv/listmonk/backups
sudo install -d -m 700 /srv/listmonk/postgres
sudo install -d -m 755 /srv/listmonk/uploads
ls -la /srv/listmonk
```

Assert: `ls -la` shows `backups` owned by the login user, `postgres` at mode `700` owned by
root, and `uploads` at `755`. Leave the last two alone: both images claim their own directory
on first start, PostgreSQL chowning its data to the uid it runs as and the listmonk entrypoint
chowning /listmonk to PUID:PGID, default 0:0.

## 3. Secrets

Two secrets: the PostgreSQL password and the Super Admin password, both generated here. Do not
print either, do not repeat them in your summary, and do not put them in any log line.

```bash
umask 077
cat > /srv/listmonk/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
LISTMONK_ADMIN_USER=admin
LISTMONK_ADMIN_PASSWORD=$(openssl rand -base64 30)
EOF
chmod 600 /srv/listmonk/.env
umask 022
ls -l /srv/listmonk/.env
```

Assert: the file exists with mode `-rw-------`. Hex for the database password, which travels
inside a connection string; base64 for the admin one, which a human pastes into a login form.
Upstream reads `LISTMONK_ADMIN_USER` and `LISTMONK_ADMIN_PASSWORD` during the one-time install
pass, so the Super Admin exists the first time the container starts. Without them, the first
person to load the admin URL on a public hostname is handed a form that creates the Super
Admin. Step 7 says how to read the password.

## 4. compose.yml

```bash
cat > /srv/listmonk/compose.yml <<'EOF'
# listmonk · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://listmonk.app/docs/installation/
#   variable reference . https://listmonk.app/docs/configuration/
#   upgrade path ....... https://listmonk.app/docs/upgrade/
#   health route ....... https://github.com/knadh/listmonk/blob/v6.2.0/cmd/handlers.go
#
# Two services: listmonk and the PostgreSQL it keeps subscribers, campaigns and
# click records in. Upstream states Postgres 12 or newer is the only dependency.
# The three-phase command is upstream's own: --install --idempotent lays the
# schema down once on an empty database, --upgrade applies migrations when the
# image moves, the third invocation runs the server, and --config '' means "no
# TOML file, read the LISTMONK_ environment variables". The root URL and the
# SMTP relay are settings rows a human fills in from the admin UI. Digests read
# on 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: listmonk-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: listmonk
      POSTGRES_USER: listmonk
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/listmonk/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U listmonk -d listmonk"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  app:
    image: listmonk/listmonk:v6.2.0@sha256:f535d59e14991337a9f2d570273685378ae86b0d7698c3e00da444e3bc205286
    container_name: listmonk-app
    restart: unless-stopped
    env_file: /srv/listmonk/.env
    command: [sh, -c, "./listmonk --install --idempotent --yes --config '' && ./listmonk --upgrade --yes --config '' && ./listmonk --config ''"]
    environment:
      # Every interface inside the container; the way in is the port below.
      LISTMONK_app__address: 0.0.0.0:9000
      LISTMONK_db__host: db
      LISTMONK_db__port: 5432
      LISTMONK_db__user: listmonk
      LISTMONK_db__database: listmonk
      LISTMONK_db__password: ${POSTGRES_PASSWORD}
      LISTMONK_db__ssl_mode: disable
      LISTMONK_db__max_open: 25
      LISTMONK_db__max_idle: 25
      LISTMONK_db__max_lifetime: 300s
      TZ: Etc/UTC
    volumes:
      # Images uploaded through Admin -> Media. The entrypoint chowns /listmonk
      # to PUID:PGID, default 0:0, so this ends up root-owned on the host.
      - /srv/listmonk/uploads:/listmonk/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8096.
      - "127.0.0.1:8096:9000"
    depends_on:
      db:
        condition: service_healthy
EOF
cd /srv/listmonk && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The `command:` line is upstream's three-phase form: pass one
creates the schema and is idempotent, a no-op on later boots; pass two applies migrations,
which is what makes step 9 three commands; pass three runs the server.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. The copy on line one matters: a syntax error takes down every other site.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-listmonk
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# listmonk · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://listmonk.app/docs/configuration/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That same hostname goes
# into listmonk's Root URL setting after the first login: unsubscribe links and
# archive URLs are built from that setting, not from the request. Upstream splits
# its routes into private admin paths (/admin/*, /api/*) and public ones
# (/subscription/*, /link/*, /campaign/*, /archive) that subscribers have to
# reach; both halves answer on this one hostname.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# SAMEORIGIN rather than DENY: the campaign editor previews a campaign
		# in an iframe served from this same origin.
		X-Frame-Options "SAMEORIGIN"
		# A subscription URL carries the subscriber's UUID in the path, so a
		# full Referer on an outbound click hands that UUID to a third party.
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8096 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8096
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-listmonk, reload, and report what it objected to. Caddy issues the
certificate on the first request and renews it, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's, and idempotent on a box Prompt Zero already configured.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the only way in, 443/udp is
HTTP/3. 8096 stays closed because compose binds it to 127.0.0.1, and 5432 because compose
publishes no host port at all. Nothing opens for mail: the relay connection is outbound, which
ufw already allows. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8096 or 5432.

## 7. Start and verify

```bash
cd /srv/listmonk
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/admin/login | grep -o '<h2>Login</h2>'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/lists
```

Assert all four, and print what you received for each. The loop ends on `200`. The health call
prints `{"data":true}`. The grep prints `<h2>Login</h2>`, the first screen. The unauthenticated
API call prints `403`, the security assert here: the admin API is answering and refusing a
caller with no session. If any of the four misses, stop, run
`docker compose logs --tail 40 app` and `docker compose logs --tail 20 db`, and name the likely
cause. A grep printing nothing while the page contains `New user` means the database was not
empty when the app first started, so step 3's Super Admin was never created: run
`docker compose down`, `sudo rm -rf /srv/listmonk/postgres`, recreate it as in step 2, and run
this block again. A running container is not success.

STOP: tell the user to do these three things and wait. Do not continue until they confirm.

- Read the admin password with `sudo grep LISTMONK_ADMIN_PASSWORD /srv/listmonk/.env`, put it
  in their password manager, and log in at https://<DOMAIN>/admin/login as `admin`.
- Settings -> General: set Root URL to `https://<DOMAIN>` and the default from-address to one
  on a domain they control. Both ship as examples and both end up inside every message that
  leaves this server.
- Settings -> SMTP: the seeded first entry is switched on and points at `smtp.yoursite.com`
  with placeholder credentials. Replace its host, port, username and password with the relay's
  and use the Test connection button before saving.

listmonk reloads itself when settings are saved. Once the user confirms, check the three
values actually moved:

```bash
cd /srv/listmonk
docker compose exec -T db psql -U listmonk -d listmonk -tAc "SELECT key, value FROM settings WHERE key IN ('app.root_url', 'app.from_email')"
docker compose exec -T db psql -U listmonk -d listmonk -tAc "SELECT count(*) FROM settings, jsonb_array_elements(value) AS s WHERE key = 'smtp' AND (s->>'enabled')::boolean AND s->>'host' = 'smtp.yoursite.com'"
curl -sS https://<DOMAIN>/health
```

Assert: the first prints a root URL of `"https://<DOMAIN>"` and a from-address with no
`listmonk.yoursite.com` in it, the second prints `0`, the third prints `{"data":true}`.
Anything above `0` means an enabled SMTP entry still points at the placeholder host and every
campaign fails on send: a step-7 failure, not a step-10 mystery.

## 8. First backup and restore

Two artifacts: the database holds subscribers, lists, campaigns, settings and click history;
the file archive holds compose.yml, .env, uploads and the host's Caddyfile.

```bash
cd /srv/listmonk
docker compose exec -T db pg_dump -U listmonk -d listmonk | gzip > /srv/listmonk/backups/listmonk-db-$(date +%F).sql.gz
sudo tar -czf /srv/listmonk/backups/listmonk-files-$(date +%F).tar.gz -C /srv/listmonk compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/listmonk/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Tell the user what they will not guess:
both carry live credentials. The archive holds .env; the dump holds the settings table, where
the SMTP relay's credential lives. Treat both like a password-manager export.

A backup on the same disk is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/listmonk
scp vps:/srv/listmonk/backups/* ~/backups/listmonk/
```

To restore: `docker compose down`, `sudo rm -rf /srv/listmonk/postgres`, recreate it as in step
2, untar the file archive back into /srv/listmonk, start the database with
`docker compose up -d db`, wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db psql -U listmonk -d listmonk`, then `docker compose up -d`. Say what
is at stake: the consent record for every subscriber, who opted in and when, is in that
database, and a list restored from nothing is a list they may no longer mail.

## 9. Updating later

New versions are listed at https://github.com/knadh/listmonk/releases. Upstream's instruction
is to back up the database before every upgrade, so run step 8 first, then edit the image line
in /srv/listmonk/compose.yml to the new tag and its digest:

```bash
cd /srv/listmonk
docker compose pull
docker compose up -d
docker compose logs --tail 30 app
```

The `--upgrade` pass applies migrations on the way up. Watch that log until it settles, then
re-run step 7's health check.

## 10. What will probably go wrong

Mail, and not listmonk. I had the app up, a list made and a test campaign written inside half
an hour, then watched the send sit at zero delivered behind a green container and a cheerful
dashboard. The relay was refusing the connection and the campaign screen never says so: the
error is in Settings -> Logs, several screens from where the problem looks like it is. Upstream
warns that some hosting providers block outbound SMTP ports 25 and 465, which is a support
ticket rather than a setting. Send one campaign to a list holding only the user's own address
before anyone else is imported, and read Settings -> Logs when nothing arrives.

## 11. Out of scope

- Do not import a subscriber list until a test campaign has arrived. A list imported into an
  instance that cannot send is a list that gets imported twice.
- Do not configure bounce processing or a bounce mailbox. That wants a second mailbox with its
  own POP credentials and is an install-sized job of its own.
- Do not enable OIDC single sign-on. It needs an identity provider registered somewhere else.
- Do not move media uploads to S3. The uploads directory from step 2 is the choice here and it
  is inside the backup.
