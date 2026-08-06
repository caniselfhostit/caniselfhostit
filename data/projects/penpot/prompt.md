You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Penpot 2.17.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for it once and stop until they answer. Say why: it
becomes `PENPOT_PUBLIC_URI`, and Penpot builds every share link, invitation and export URL from
it, so a board link already in somebody's chat window dies if it changes. Its A record must
point here now.

Penpot needs 4096 MB of RAM available and 20 GB free on /srv; upstream's own answer is 1 to 2
CPUs and 4 GiB. All five images publish amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk under 20 GB, print both and stop. If `dig +short`
prints nothing, print that and stop. Do not install and hope.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/penpot /srv/penpot/backups
sudo install -d -m 700 /srv/penpot/postgres
sudo install -d -m 750 -o 1001 -g 1001 /srv/penpot/assets
ls -la /srv/penpot
```

Assert: `ls -la` shows `backups` owned by the login user, `postgres` at mode `700` owned by
root, `assets` owned by `1001`. Leave all three. PostgreSQL chowns its own data directory on
first start; backend and frontend run as uid 1001 and share `assets`, so chowning that one to
the login user makes uploads fail on a permission error nothing explains.

## 3. Secrets

Two: the master key Penpot derives session and invitation keys from, and the PostgreSQL
password. Generate both on the server, print neither, keep both out of your summary and out of
every log line. Hex not base64: `openssl rand -base64 64` wraps onto two lines and an env file
is read one line at a time.

```bash
umask 077
cat > /srv/penpot/.env <<EOF
PENPOT_PUBLIC_URI=https://<DOMAIN>
PENPOT_FLAGS=enable-registration disable-email-verification enable-prepl-server
PENPOT_SECRET_KEY=$(openssl rand -hex 64)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/penpot/.env
umask 022
ls -l /srv/penpot/.env
```

Assert: mode `-rw-------`. That key is 512 bits, the size upstream asks for; losing it logs
every session out and voids every outstanding invitation, so step 8 gets a copy off the box. The
three flags: registration is open only until step 7 closes it; email verification is off because
this install runs no SMTP and an account nobody verified can still log in; the prepl server is
the local socket the backend's CLI talks to, the one way back in if a password is forgotten.

## 4. compose.yml

```bash
cat > /srv/penpot/compose.yml <<'EOF'
# Penpot · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ... https://help.penpot.app/technical-guide/getting-started/docker/
#   configuration .... https://help.penpot.app/technical-guide/configuration/
#   sizing + valkey .. https://help.penpot.app/technical-guide/getting-started/recommended-settings/
#   flag definitions . https://github.com/penpot/penpot/blob/2.17.0/common/src/app/common/flags.cljc
#
# Five services: nginx plus the browser app, the API and file data, an exporter
# rendering in a headless Chromium inside its own image, PostgreSQL for the
# designs, Valkey for websocket notifications.
#
# Upstream's compose runs two more this file leaves out: an MCP server, routed
# by the frontend only when PENPOT_FLAGS contains enable-mcp, and a mailcatcher,
# a development mailbox. Telemetry is off here; upstream's compose turns it on.
#
# Digests read from Docker Hub on 2026-08-06; all five publish amd64 and arm64.
# Backend and frontend run as uid 1001, which is why /srv/penpot/assets is too.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: penpot

services:
  penpot-postgres:
    image: postgres:15.18@sha256:6eb0add3b77c081df18aa518ce43df58fdcc40f2e6d868a6fd08038dc7acd425
    restart: unless-stopped
    stop_signal: SIGINT
    environment:
      POSTGRES_DB: penpot
      POSTGRES_USER: penpot
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_INITDB_ARGS: --data-checksums
    volumes:
      - /srv/penpot/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U penpot -d penpot"]
      interval: 10s
      retries: 30
    # No `ports:`: 5432 is reachable only from the other containers.

  penpot-valkey:
    image: valkey/valkey:8.1.9-alpine@sha256:a038175878d66b9d274fbf8be73c0305e93798b83917647f167e18cef3c71eec
    restart: unless-stopped
    # Arguments rather than upstream's env var; numbers from their docs.
    command: ["valkey-server", "--maxmemory", "128mb", "--maxmemory-policy", "volatile-lfu"]
    healthcheck:
      test: ["CMD-SHELL", "valkey-cli ping | grep PONG"]
      interval: 5s
      retries: 20

  penpot-backend:
    image: penpotapp/backend:2.17.0@sha256:471cdebf185be899ef7d7593e9cd7994b908ebd7ffb78ca547e3d843bb83536f
    restart: unless-stopped
    volumes:
      - /srv/penpot/assets:/opt/data/assets
    environment:
      PENPOT_FLAGS: ${PENPOT_FLAGS}
      PENPOT_PUBLIC_URI: ${PENPOT_PUBLIC_URI}
      PENPOT_SECRET_KEY: ${PENPOT_SECRET_KEY}
      PENPOT_DATABASE_URI: postgresql://penpot-postgres/penpot
      PENPOT_DATABASE_USERNAME: penpot
      PENPOT_DATABASE_PASSWORD: ${DB_PASSWORD}
      PENPOT_REDIS_URI: redis://penpot-valkey/0
      PENPOT_OBJECTS_STORAGE_BACKEND: fs
      PENPOT_OBJECTS_STORAGE_FS_DIRECTORY: /opt/data/assets
      PENPOT_TELEMETRY_ENABLED: "false"
    depends_on:
      penpot-postgres:
        condition: service_healthy
      penpot-valkey:
        condition: service_healthy

  penpot-exporter:
    image: penpotapp/exporter:2.17.0@sha256:7e8beb6ef2bdb9d778e9bbcbf7feebf8c99a137b2d9eb3969450c0a1a49e41c5
    restart: unless-stopped
    environment:
      PENPOT_PUBLIC_URI: ${PENPOT_PUBLIC_URI}
      PENPOT_SECRET_KEY: ${PENPOT_SECRET_KEY}
      PENPOT_REDIS_URI: redis://penpot-valkey/0
      PENPOT_INTERNAL_URI: http://penpot-frontend:8080
    depends_on:
      penpot-valkey:
        condition: service_healthy

  penpot-frontend:
    image: penpotapp/frontend:2.17.0@sha256:861989dfff50f12b9de1358c6b0f3cc1e601d7a678db2826f3643d0f93438500
    restart: unless-stopped
    volumes:
      - /srv/penpot/assets:/opt/data/assets
    environment:
      PENPOT_FLAGS: ${PENPOT_FLAGS}
      PENPOT_PUBLIC_URI: ${PENPOT_PUBLIC_URI}
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8122.
      - "127.0.0.1:8122:8080"
    depends_on:
      - penpot-backend
      - penpot-exporter
EOF
cd /srv/penpot && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Every `${...}` above is filled from /srv/penpot/.env, which compose reads
because the command runs in that directory.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy first: a syntax error
here takes down every other site.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-penpot
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Penpot · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://help.penpot.app/technical-guide/getting-started/docker/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# PENPOT_PUBLIC_URI in .env; Penpot builds every share and export URL from it.

<DOMAIN> {
	# The frontend image already sends nosniff, Referrer-Policy,
	# Permissions-Policy and X-Frame-Options SAMEORIGIN, so repeating them
	# here would send each twice. HSTS is the one it cannot set: only this
	# block knows the name is served over TLS. No `encode` either, because
	# that nginx gzips its own responses.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		-Server
	}

	# 8122 is the loopback port compose publishes here. Not a container port,
	# not open in the firewall. reverse_proxy passes the /ws/notifications
	# upgrade through untouched, which is how cursors move.
	reverse_proxy 127.0.0.1:8122
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. On failure restore /etc/caddy/Caddyfile.before-penpot, reload, and report
what it objected to. Caddy gets the certificate on the first request and renews it itself.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the way in, 443/udp is HTTP/3. 8122
stays closed because compose binds it to 127.0.0.1; 5432, 6379, 6060, 6061 and the CLI socket on
6063 because nothing publishes them. Assert: `Status: active`, rules for 80, 443/tcp and
443/udp, none for those five.

## 7. Start and verify

The pull is about 1.4 GB, most of it the exporter's browser, and the backend then migrates its
database before it answers anything.

```bash
cd /srv/penpot
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/readyz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/readyz
curl -sS https://<DOMAIN>/ | grep -c 'Penpot | Full-stack design'
curl -sS https://<DOMAIN>/js/config.js
docker compose ps
```

Assert all five, printing what you got. The loop ends on `200`. `/readyz` prints `OK` and earns
it: that handler runs a real query against PostgreSQL, so 200 means backend and database are
both up. The grep prints `1`, from the `<title>` Penpot serves. `config.js` contains
`var penpotFlags = "enable-registration disable-email-verification enable-prepl-server";`, where
the browser reads what this install allows. `ps` shows all five services `Up`. If any
misses, stop, run `docker compose logs --tail 40 penpot-backend`, and name the cause: a backend
that never starts is step 3 and an empty `DB_PASSWORD`; a `502` from Caddy is the frontend still
waiting on its dependencies. A running container is not success.

The first screen at https://<DOMAIN> shows the heading `Log into my account` with a
`Create an account` link under it.

STOP: tell the user to open https://<DOMAIN>, click `Create an account`, register with their
email and a password they save in their password manager first, and wait. Do not continue until
they confirm. No SMTP means no reset mail, so that saved password is the way in.

Once they confirm, close registration and recreate the two containers that read the flag:

```bash
sed -i 's/^PENPOT_FLAGS=enable-registration/PENPOT_FLAGS=disable-registration/' /srv/penpot/.env
cd /srv/penpot && docker compose up -d --force-recreate penpot-backend penpot-frontend
sleep 20
curl -sS https://<DOMAIN>/js/config.js | grep -c 'disable-registration'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/readyz
```

Assert: `1` and `200`.

STOP: tell the user to reload https://<DOMAIN> in a private window and confirm the
`Create an account` link is gone, and wait. Both asserts and that confirmation must pass before
you report success.

## 8. First backup and restore

Two artifacts: the database holds every file, board, comment and account; the config archive
holds the uploaded images and fonts plus the `.env` those sessions depend on.

```bash
cd /srv/penpot
docker compose exec -T penpot-postgres pg_dump -U penpot -d penpot | gzip > /srv/penpot/backups/penpot-db-$(date +%F).sql.gz
sudo tar -czf /srv/penpot/backups/penpot-config-$(date +%F).tar.gz -C /srv/penpot compose.yml .env assets -C /etc/caddy Caddyfile
ls -lh /srv/penpot/backups/
```

Assert: both exist, both non-empty, print both sizes. Nothing stops, because `pg_dump` snapshots
a running database consistently. Valkey holds notifications in flight and nothing that outlives
a restart, so it is not backed up. A backup on the same disk is not a backup, so run this from
the user's machine:

```bash
mkdir -p ~/backups/penpot
scp vps:/srv/penpot/backups/* ~/backups/penpot/
```

To restore: `docker compose down`, `sudo rm -rf /srv/penpot/postgres`, recreate it as in step 2,
untar the config archive into /srv/penpot so `.env` and `assets` are back first,
`docker compose up -d penpot-postgres`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T penpot-postgres psql -U penpot -d penpot`, then `docker compose up -d`.
Say the stakes: those two files are one backup, because a database restored beside a different
`PENPOT_SECRET_KEY` logs everyone out and one restored without `assets` opens every board with
the images missing.

## 9. Updating later

Releases are at https://github.com/penpot/penpot/releases. Back both artifacts up first, then
edit the three `penpotapp/` image lines in compose.yml to the new tag and digest. They move
together: a frontend newer than its backend fails in the browser, not in a log.

```bash
cd /srv/penpot
docker compose pull
docker compose up -d
docker compose logs --tail 40 penpot-backend
```

The backend migrates its database on the way up, so watch that log settle, then re-run step 7's
`/readyz` check before calling the update done.

## 10. What will probably go wrong

The wait, twice over. I ran `docker compose up -d`, watched `/readyz` answer `502` for four
minutes, and went looking for a fault that was not there. The exporter image alone is 641 MB
compressed because it carries a headless Chromium, so on a cold pull the stack is still arriving
while compose claims to have started it, and then the backend runs its migrations before it
answers anything. Let step 7's loop run all forty times before concluding anything is broken;
`docker compose logs -f penpot-backend` is what is worth watching meanwhile.

## 11. Out of scope

- Do not configure SMTP. `disable-email-verification` is what lets this install run without it,
  and invitations still work: the invite link is on screen for the person who sent it.
- Do not add `enable-mcp` or the MCP container. The frontend routes to it only when that flag is
  set, and it is a separate service with its own trust decision.
- Do not switch object storage to S3, and do not enable OIDC, Google, GitHub or GitLab login.
  Each is a second account somewhere else, and this install has none on purpose.
