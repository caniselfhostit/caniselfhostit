You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Zipline 4.6.5 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Tell them why it matters while you ask: `<DOMAIN>` is the front of every share link this server
hands out, so a screenshot they paste into a ticket today carries that hostname for as long as
the link matters. Its A record must already point at this server.

Zipline needs 2048 MB of RAM available and 10 GB free on /srv. That floor is the thumbnail
workers rather than the web server: the image ships ffmpeg and renders video thumbnails on four
threads. Both images publish amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/zipline /srv/zipline/uploads /srv/zipline/backups
sudo install -d -m 700 /srv/zipline/postgres
ls -la /srv/zipline
```

Assert: `ls -la` shows `uploads` and `backups` owned by the login user, and `postgres` at mode
`700` owned by root. Leave that one alone: the PostgreSQL image chowns its own data directory on
first start, and one already chowned elsewhere makes it refuse to initialise. The Zipline
container runs as root, so files it writes under `uploads` belong to root.

## 3. Secrets

Two secrets, both generated here on the server: the PostgreSQL password and `CORE_SECRET`, which
signs session cookies. Do not print either, do not repeat them in your summary, and do not put
them in any log line. Hex rather than base64 for both: one travels inside a connection string,
and upstream refuses to start on a secret under 32 characters, which 32 hex bytes clears.

```bash
umask 077
cat > /srv/zipline/.env <<EOF
CORE_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/zipline/.env
umask 022
ls -l /srv/zipline/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user that changing `CORE_SECRET` later
logs every session out, including their own, so it is a value to leave alone once the install
works. They never have to read it: the only credential they type is the password they choose in
step 7.

## 4. compose.yml

```bash
cat > /srv/zipline/compose.yml <<'EOF'
# Zipline · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://zipline.diced.sh/docs/get-started/docker
#   variable reference . https://zipline.diced.sh/docs/config
#   core variables ..... https://zipline.diced.sh/docs/config/core
#   hardening guide .... https://zipline.diced.sh/docs/guides/hardening
#   reverse proxy ...... https://zipline.diced.sh/docs/guides/reverse-proxy
#
# Two services: Zipline and the PostgreSQL that holds accounts, tokens, short
# links and one row per uploaded file. The files themselves sit on disk under
# /srv/zipline/uploads, so a restore needs both halves or you get an index of
# things that are not there. Upstream's own compose file runs postgres 16, so
# this one stays on that major and pins a patch of it. Digests were read from
# the registries on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: zipline-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: zipline
      POSTGRES_USER: zipline
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/zipline/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zipline -d zipline"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  zipline:
    image: ghcr.io/diced/zipline:4.6.5@sha256:bfd5b0f7b5b8b3ed058a81667c78a14a7f997115d8433bec273620ec81be51d4
    container_name: zipline
    restart: unless-stopped
    env_file: /srv/zipline/.env
    environment:
      DATABASE_URL: postgres://zipline:${DB_PASSWORD}@postgres:5432/zipline
      # Caddy terminates TLS and speaks plain http here. Upstream asks for both
      # of these behind a proxy: without the first, every request looks like it
      # came from 127.0.0.1; without the second, the links handed back start
      # with http:// on a site only reachable over https.
      CORE_TRUST_PROXY: "true"
      CORE_RETURN_HTTPS_URLS: "true"
      # Registration is off upstream by default and this pins it off, so the
      # only account ever made is the first one, through the setup wizard.
      FEATURES_USER_REGISTRATION: "false"
      # Read the type off the file instead of believing the uploader, and serve
      # the two that execute in a browser as a download rather than inline.
      FILES_ASSUME_MIMETYPES: "true"
      FILES_DISABLED_TYPES: text/html,application/javascript
      FILES_DISABLED_TYPES_DEFAULT: application/octet-stream
    volumes:
      - /srv/zipline/uploads:/zipline/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8156.
      - "127.0.0.1:8156:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/zipline && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port. Uploaded files live on the
host under /srv/zipline/uploads; everything else about them, the owner, the short code, the view
count, is a row in PostgreSQL. That is why step 8 takes two artifacts rather than one. The six
settings under `DATABASE_URL` are pinned here rather than left to the dashboard: every start
re-applies them, so a change made in the web settings will not survive a restart.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-zipline
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Zipline · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://zipline.diced.sh/docs/guides/reverse-proxy,
# https://caddyserver.com/docs/caddyfile/directives/request_body and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# the front of every share link this server hands out, so it is the value here
# worth choosing once and keeping.

<DOMAIN> {
	# Uploads are mostly already-compressed image and video formats, so there
	# is nothing to gain by compressing them again. These four headers are the
	# part worth having: a file host serves other people's bytes to strangers.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# Zipline's own default file size limit is 100 MB and it cuts anything
	# larger into 25 MB chunks, so 128 MB of request body covers both with room
	# to spare. Caddy answers 413 above this. Raise Zipline's limit and this
	# number together or the proxy will refuse what the app would have taken.
	request_body {
		max_size 128MB
	}

	# 8156 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8156
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-zipline, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it alone, so nothing needs scheduling. It
terminates TLS and speaks plain http to the container, which is why `CORE_TRUST_PROXY` and
`CORE_RETURN_HTTPS_URLS` are both true in compose.yml: without them Zipline treats every request
as coming from 127.0.0.1 and hands back `http://` links for a site that only answers on https.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp is
HTTP/3. 8156 stays closed because compose binds it to 127.0.0.1, and 5432 stays closed because
compose never publishes it: the database has no host port a rule could apply to. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for
8156 or 5432.

## 7. Start and verify

Zipline runs its own database migrations on the way up, so the first start is slower than the
ones after it.

```bash
cd /srv/zipline
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/healthcheck
curl -sS https://<DOMAIN>/api/setup
```

Assert, all three. The loop ends printing `200`. The health call prints `{"pass":true}`, which
upstream documents as the server and the database both answering. The setup call prints
`{"firstSetup":true}`, which is this instance saying it has no accounts yet. Print what you
received for each. If any of the three misses, stop, run
`docker compose logs --tail 40 zipline` and `docker compose logs --tail 20 postgres`, and say
which earlier step is the likely cause: a database that never reports healthy points at step 2,
and a `502` where a `200` was expected means the container is still migrating. A running
container is not success.

The first screen is at https://<DOMAIN>/auth/setup and its heading reads `Welcome to Zipline!`,
above a stepper with a `Username` and a `Password` field.

STOP: tell the user to open https://<DOMAIN>/auth/setup, create the first account, then, still
logged in, open Settings from the user menu at the top right, scroll to `Generate Uploaders`,
and download the `ShareX` config on Windows or the `Flameshot` script on Linux and macOS. That
download is the point of this install: it aims the screenshot tool they already have at this
server. Wait. Do not continue until they confirm both.

Once they confirm, prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/setup
curl -sS https://<DOMAIN>/api/server/public | grep -oE '"(userRegistration|firstSetup)":[a-z]+'
```

Assert: the first prints `403`, upstream's answer once the setup wizard has been claimed, so no
second superadmin can be made through it. The second prints `"userRegistration":false` and
`"firstSetup":false`. Both asserts must pass before you report success.

## 8. First backup and restore

Two artifacts, and neither one is worth anything alone. The database holds the accounts, the
tokens, the short links and one row per file. The archive holds the files themselves plus the
three configuration files that rebuild the service around them.

```bash
cd /srv/zipline
docker compose exec -T postgres pg_dump -U zipline -d zipline | gzip > /srv/zipline/backups/zipline-db-$(date +%F).sql.gz
sudo tar -czf /srv/zipline/backups/zipline-files-$(date +%F).tar.gz -C /srv/zipline compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/zipline/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. The second archive is kilobytes today and
every file they ever uploaded a year from now, so the nightly job they write later wants `rsync`
on uploads, not a growing tarball.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/zipline
scp vps:/srv/zipline/backups/* ~/backups/zipline/
```

To restore: `docker compose down`, `sudo rm -rf /srv/zipline/postgres /srv/zipline/uploads`,
recreate both directories as in step 2, untar the files archive into /srv/zipline,
`docker compose up -d postgres`, wait about 30 seconds for it to report healthy, then pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U zipline -d zipline`,
then `docker compose up -d`. Open one old link and check the file comes back. Tell the user the
stakes plainly: every link they have pasted into a ticket or a chat points at this box, and a
database restored without its uploads directory answers all of them with a missing file.

## 9. Updating later

New versions are listed at https://github.com/diced/zipline/releases. Take both backups first,
then edit the image line in /srv/zipline/compose.yml to the new tag and its digest:

```bash
cd /srv/zipline
docker compose pull
docker compose up -d
docker compose logs --tail 30 zipline
```

Zipline migrates its own database on the way up, so watch that log until it settles, then re-run
step 7's health check before calling the update done.

## 10. What will probably go wrong

You will open https://<DOMAIN> in a browser, see a screen reading `404` and `Page not found`,
and conclude Caddy is pointed at nothing. I did, and I spent ten minutes re-reading the site
block. It was fine: Zipline has no home page, the root path falls through to its own not-found
screen, and the only thing at the bare hostname is a `Go home` button back to the login page.
The address that tells the truth on a fresh install is https://<DOMAIN>/auth/setup. Check
that, not the root.

## 11. Out of scope

- Do not configure SMTP. Zipline sends no mail at all, so there is nothing for it to do.
- Do not register an OAuth application with Discord, GitHub, Google or an OIDC provider. A
  password login with registration closed is the whole account model this install commits to.
- Do not switch the datasource to S3. Local storage under /srv/zipline/uploads is the choice
  here, and it is the one step 8 knows how to back up.
- Do not raise `FILES_MAX_FILE_SIZE` without raising `max_size` in the Caddy block by the same
  amount. Raise one alone and the other returns `413` on uploads the app would have taken.
