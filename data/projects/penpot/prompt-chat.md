This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Penpot 2.17.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read this before step 1. `<DOMAIN>` becomes `PENPOT_PUBLIC_URI`, and Penpot builds every share
link, team invitation and export URL from it. Change it later and a board link already sitting
in somebody's chat window stops working. Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line. Upstream's own answer to what Penpot needs is 1 to 2 CPUs and
4 GiB, and all five images publish both architectures.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve and failed attempts count against a rate limit you cannot see. Under 4096 MB is the one
number not to argue with: this is five services, one of them a JVM and one of them a browser,
and the OOM killer arrives during your first export rather than during the install.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/penpot /srv/penpot/backups
sudo install -d -m 700 /srv/penpot/postgres
sudo install -d -m 750 -o 1001 -g 1001 /srv/penpot/assets
ls -la /srv/penpot
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`assets` owned by `1001`.

If you do not: leave all three as they are, on purpose. The PostgreSQL image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. The Penpot backend and frontend both run as uid 1001 and share `assets` between
them, so if you chown that one to yourself every image upload fails with a permission error and
nothing in the interface tells you why.

## 3. Secrets

Two: the master key Penpot derives session and invitation keys from, and the PostgreSQL
password. Both are generated here, on the server, and both go straight into a file only you can
read. Hex rather than base64, because `openssl rand -base64 64` wraps onto two lines and an env
file is read one line at a time.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

Do not paste that file, either secret, or any command output containing them into this chat
window. The agent path never sees those values; this one hands them to a third party unless you
keep them out.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines in separate shells. Run `chmod 600 /srv/penpot/.env` and carry on. If the
file already existed from an earlier attempt, this block has now replaced both secrets, which is
fine before the database exists and a problem afterwards: PostgreSQL keeps the password it was
created with, so a changed `DB_PASSWORD` against an existing volume shows up as an
authentication failure in the backend log rather than as anything about passwords.

Those three flags are the security shape of this install. Registration is open only until step 7
closes it. Email verification is off because there is no SMTP server here, and an account nobody
verified can still log in. The prepl server is a socket on localhost inside the backend
container, which is what its own command-line tool talks to, and it is your way back in if you
ever lose the password.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal, so run `rm /srv/penpot/compose.yml` and paste again in one go. A warning that
`PENPOT_SECRET_KEY` is not set means step 3 did not write the file, or you are not in
/srv/penpot: compose fills every `${...}` from the `.env` in the directory you run it from.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-penpot /etc/caddy/Caddyfile`, reload,
and paste again. The block deliberately sets only two headers, because Penpot's own frontend
already sends nosniff, Referrer-Policy, Permissions-Policy and X-Frame-Options on every
response, and adding them here would send each one twice.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8122`, `5432`, `6379`, `6060`, `6061` or `6063`.

If you do not: delete anything for those with `sudo ufw delete allow 8122`. 8122 is bound to
127.0.0.1 by the compose file, the database and Valkey publish no host port at all, the backend
and exporter are reachable only over the container network, and 6063 is the backend's own
command-line socket bound to localhost inside its container. 80/tcp is there to redirect to
HTTPS and answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which
Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

About 1.4 GB of images arrive here, most of it the exporter's headless Chromium, and the backend
runs its own database migrations before it answers anything. The loop below waits ten minutes.

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

You should see, in order: the loop reaching `200`; the word `OK`; the number `1`; a short file
containing
`var penpotFlags = "enable-registration disable-email-verification enable-prepl-server";`; and
five services listed as `Up`.

If you do not: `OK` is the one worth understanding. That endpoint runs a real query against
PostgreSQL before it answers, so a `200` there means the backend and the database are both up
and talking to each other, which is most of this install. A `502` from Caddy while the loop is
still running is normal and means the frontend has not finished waiting on its own dependencies;
run `docker compose logs --tail 40 penpot-backend` if the loop reaches forty without a `200`. An
empty result from the `config.js` line means the frontend started before `.env` existed, so
`docker compose up -d --force-recreate penpot-frontend` and look again.

Now open https://<DOMAIN> in a browser. The first screen shows the heading
`Log into my account` with a `Create an account` link under it. Click it, register with your
email address, and save the password in your password manager before you submit: there is no
SMTP server here, so no reset email will ever arrive.

Then close registration behind you:

```bash
sed -i 's/^PENPOT_FLAGS=enable-registration/PENPOT_FLAGS=disable-registration/' /srv/penpot/.env
cd /srv/penpot && docker compose up -d --force-recreate penpot-backend penpot-frontend
sleep 20
curl -sS https://<DOMAIN>/js/config.js | grep -c 'disable-registration'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/readyz
```

You should see: `1`, then `200`. Reload https://<DOMAIN> in a private window and confirm the
`Create an account` link is gone.

If you do not: a `0` from the grep means the frontend was not recreated, so run the second line
again and check `docker compose ps` shows a fresh created time. Do not skip this step because
the box is new and nobody knows the hostname yet. An open registration page on a public name is
found by scanners in hours, and everyone who registers lands in your instance. From here, new
people arrive by team invitation instead.

## 8. First backup and restore

Two artifacts. The database holds every file, board, comment and account. The config archive
holds the images and fonts you upload, plus the `.env` whose key those sessions depend on.

```bash
cd /srv/penpot
docker compose exec -T penpot-postgres pg_dump -U penpot -d penpot | gzip > /srv/penpot/backups/penpot-db-$(date +%F).sql.gz
sudo tar -czf /srv/penpot/backups/penpot-config-$(date +%F).tar.gz -C /srv/penpot compose.yml .env assets -C /etc/caddy Caddyfile
ls -lh /srv/penpot/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently. Valkey is not backed up, because it holds
notifications in flight and nothing that outlives a restart.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/penpot
scp vps:/srv/penpot/backups/* ~/backups/penpot/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/penpot/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty account:

```bash
cd /srv/penpot
docker compose down
sudo rm -rf /srv/penpot/postgres
sudo install -d -m 700 /srv/penpot/postgres
docker compose up -d penpot-postgres
sleep 30
gunzip -c /srv/penpot/backups/penpot-db-$(date +%F).sql.gz | docker compose exec -T penpot-postgres psql -U penpot -d penpot
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/readyz
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200`, then your own login
working in the browser with the password you already have.

If you do not: `role "penpot" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the two files are
before you skip this. They are one backup: a database restored beside a different
`PENPOT_SECRET_KEY` logs everyone out, and one restored without `assets` opens every board with
the images missing.

## 9. Updating later

New versions are listed at https://github.com/penpot/penpot/releases. Take both backup artifacts
first, then edit the three `penpotapp/` image lines in /srv/penpot/compose.yml to the new tag and
its digest. All three move together.

```bash
cd /srv/penpot
docker compose pull
docker compose up -d
docker compose logs --tail 40 penpot-backend
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tags and digests back and run the same three commands. A frontend
newer than its backend does not fail in a log, it fails in the browser, so re-run step 7's
`/readyz` check and then open a real file before you call the update done.

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
