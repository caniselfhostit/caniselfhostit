This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Automatisch 0.15.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `API_URL`, and every webhook address this instance
hands a third-party service is built from it. Move it later and the flows already published keep
pointing at a name that no longer answers. Pick the hostname you intend to keep.

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
resolve, and failed attempts count against a rate limit you cannot see. On the memory line,
upstream publishes no sizing figure at all; 2048 MB is this install's own floor, covering two
Node processes from one 800 MB image plus PostgreSQL and Redis. A 1 GB box will start and then
get one of the four killed under load, which reads as random.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/automatisch /srv/automatisch/backups
sudo install -d -m 700 /srv/automatisch/postgres /srv/automatisch/redis
ls -la /srv/automatisch
```

You should see: `backups` owned by you, and `postgres` and `redis` at mode `drwx------` owned by
root.

If you do not: leave those two owned by root on purpose. Both images chown their own data
directory the first time they start, and a directory you have already chowned to yourself makes
PostgreSQL refuse to initialise with a message about permissions that does not mention you.

## 3. Secrets

Four secrets, all generated here on the server, all going into one file only you can read: the
key that encrypts every stored third-party credential, the key that verifies inbound webhooks,
the app secret key upstream documents as required, and the PostgreSQL password. Hex rather than
base64, because one of them rides inside a database connection string.

```bash
umask 077
cat > /srv/automatisch/.env <<EOF
API_URL=https://<DOMAIN>
ENCRYPTION_KEY=$(openssl rand -hex 32)
WEBHOOK_SECRET_KEY=$(openssl rand -hex 32)
APP_SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/automatisch/.env
umask 022
ls -l /srv/automatisch/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/automatisch/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all four,
which is fine before the database exists and a problem afterwards: PostgreSQL keeps the password
it was created with, so a changed `POSTGRES_PASSWORD` on an existing volume shows up as an
authentication failure in the Automatisch log rather than anything about passwords.

Do not paste that file, any of those four values, or any command output containing them into this
chat window. Upstream's own warning is worth reading twice: the first two encrypt your
third-party credentials and verify webhook requests, and if they change, your existing
connections and flows stop working. Read `ENCRYPTION_KEY` once with
`sudo grep ENCRYPTION_KEY /srv/automatisch/.env` and put it in your password manager.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/automatisch/compose.yml <<'EOF'
# Automatisch · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installation ....... https://automatisch.io/docs/guide/installation
#   variable reference . https://automatisch.io/docs/advanced/configuration
#   credentials ........ https://automatisch.io/docs/advanced/credentials
#   url resolution ..... https://github.com/automatisch/automatisch/blob/v0.15.0/packages/backend/src/config/app.js
#
# Four services. One image runs twice: as the web and API process, and with
# WORKER=true as the queue worker, the split upstream documents for Docker.
# PostgreSQL holds the flows, the connections and the run history; Redis holds
# the BullMQ queues and the schedule of every published flow. Upstream's own
# compose file builds from a git checkout; this one runs the image their release
# workflow publishes to ghcr.io.
#
# API_URL is the one address variable that matters: config/app.js derives the
# API base, the web app URL and the webhook URL from it, where the documented
# HOST and PORT pair would build https://host:3000 and break the app icons in
# the editor. Digests read 2026-08-07; all images publish arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# The web process and the worker share an image; compose ignores x- keys.
x-automatisch-env: &automatisch-env
  APP_ENV: production
  POSTGRES_HOST: postgres
  POSTGRES_DATABASE: automatisch
  POSTGRES_USERNAME: automatisch
  REDIS_HOST: redis
  # No seeded admin: the first account is typed on the installation screen.
  DISABLE_SEED_USER: "true"
  TELEMETRY_ENABLED: "false"

x-automatisch: &automatisch
  image: ghcr.io/automatisch/automatisch:0.15.0@sha256:3bace7a12d5fb3f5b1305a6a52232270e0e0abd8465a8b78baacb07f6ea89594
  restart: unless-stopped
  env_file: /srv/automatisch/.env
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: automatisch-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: automatisch
      POSTGRES_USER: automatisch
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/automatisch/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U automatisch -d automatisch"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: automatisch-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/automatisch/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  automatisch:
    <<: *automatisch
    container_name: automatisch
    environment: *automatisch-env
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8171.
      - "127.0.0.1:8171:3000"

  worker:
    <<: *automatisch
    container_name: automatisch-worker
    environment:
      <<: *automatisch-env
      # The one difference: this copy runs the queue, not the web process.
      WORKER: "true"
EOF
cd /srv/automatisch && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/automatisch/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal;
run `rm /srv/automatisch/compose.yml` and paste again in one go. The image is written once, under
a YAML anchor both application services share, so the version and digest live on one line rather
than two. The second copy adds `WORKER=true` and runs the job queue instead of the web process,
which is the split upstream documents for a Docker install.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-automatisch
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Automatisch · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://automatisch.io/docs/guide/installation and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also API_URL in .env, and every webhook address Automatisch hands a third
# party is built from it, so it is the value here you cannot change once
# published flows are running. The app sends its own frame headers, so there is
# no frame directive below.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting an app sends the user out to a third-party
		# consent screen and back, and some providers check the origin.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8171 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8171
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-automatisch /etc/caddy/Caddyfile`, reload,
and paste again. Caddy requests the certificate on the first request to the hostname and renews
it on its own, so there is nothing to schedule and nothing to renew by hand.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8171`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8171`. 8171 is bound
to 127.0.0.1 by the compose file, and PostgreSQL and Redis publish no host port at all, so
neither has a port a firewall rule could apply to. 80/tcp redirects to HTTPS and answers the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The main container runs its own database migrations on the way up, so the first boot takes
minutes and Caddy answers `502` through most of them.

```bash
cd /srv/automatisch
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/internal/api/v1/automatisch/version
curl -sS https://<DOMAIN>/internal/api/v1/automatisch/info
docker compose logs --tail 20 worker | grep -c 'Workers are ready'
```

You should see, in order: the loop climbing and ending on `200`, a JSON object containing
`"version":"0.15.0"`, a second JSON object containing `"installationCompleted":false`, and then
`1`.

If you do not: the version string is the one worth checking carefully, because it is how you know
the pinned release is what answered rather than something already on the box. A `502` that never
clears after ten minutes means the container is not listening: run
`docker compose logs --tail 40 automatisch`. If the loop never starts climbing, run
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy is
step 2 done wrong. A `0` from the last line means the worker is not running, which is a Redis
problem rather than an Automatisch one, and nothing you publish later will ever execute.

Now open a browser. https://<DOMAIN>/ redirects to https://<DOMAIN>/installation while the
instance has no account, and that screen shows the heading `Installation` over a form asking for
a full name, an email and a password twice, above a button reading `Create admin`. Fill it in.
That account is the admin of this instance. Then confirm the door shut behind you:

```bash
curl -sS https://<DOMAIN>/internal/api/v1/automatisch/info | grep -o '"installationCompleted":true'
```

You should see: `"installationCompleted":true`.

If you do not: the form did not submit. Reload https://<DOMAIN>/installation and look for a red
alert under the fields; a password under six characters and two passwords that do not match are
both rejected in the browser without reaching the server. Once this prints `true`, the endpoint
that creates the first admin answers `403` to everyone forever. This install also sets
`DISABLE_SEED_USER`, so the default account upstream's entrypoint would otherwise create never
existed on your box at all.

## 8. First backup and restore

Two artifacts. The database holds the flows, the connections and the run history. The config
archive holds the files that rebuild the service around them, encryption key included.

```bash
cd /srv/automatisch
docker compose exec -T postgres pg_dump -U automatisch -d automatisch | gzip > /srv/automatisch/backups/automatisch-db-$(date +%F).sql.gz
sudo tar -C /srv/automatisch -czf /srv/automatisch/backups/automatisch-config-$(date +%F).tar.gz compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/automatisch/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline;
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/automatisch
scp vps:/srv/automatisch/backups/* ~/backups/automatisch/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/automatisch/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty instance:

```bash
cd /srv/automatisch
docker compose down
sudo rm -rf /srv/automatisch/postgres
sudo install -d -m 700 /srv/automatisch/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/automatisch/backups/automatisch-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U automatisch -d automatisch
docker compose exec -T postgres psql -U automatisch -d automatisch -c "UPDATE flows SET active = false;"
docker compose up -d
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `UPDATE 0` from the second
command, then the containers coming back.

If you do not: `role "automatisch" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. That `UPDATE flows` line is the
step people miss, and on a real restore it will not print `UPDATE 0`. The repeating schedule of
every published flow lives in Redis, not in PostgreSQL, so a restored database describes flows
that nothing is scheduled to run. Clearing the flag lets you switch each one back on in the
browser, which is what re-registers its schedule. Understand the other stake too: a database
restored without the matching `ENCRYPTION_KEY` comes back with every flow intact and every stored
credential unreadable, so the two artifacts travel together or neither is worth keeping.

## 9. Updating later

New versions are listed at https://github.com/automatisch/automatisch/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/automatisch/compose.yml to the new tag and
its digest.

```bash
cd /srv/automatisch
docker compose pull
docker compose up -d
docker compose logs --tail 30 automatisch
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
step 7's first three checks before you call the update done, because a service that answers on
/healthcheck can still be a half-finished migration.

## 10. What will probably go wrong

Nothing will happen for fifteen minutes and it will look like the worker is dead. I published my
first flow, watched the executions page stay empty, and restarted the whole stack twice before I
read the code. Without an enterprise licence Automatisch pins every polling trigger to a
fifteen-minute cron, and the interval selector is put back to fifteen when you save it lower. The
first run is up to a quarter of an hour after publishing, every time. Before touching anything,
run `docker compose logs --tail 20 worker` and look for `Workers are ready!`. If that line is
there, the install is fine and the clock is what you are waiting for.

## 11. Out of scope

- Do not configure SMTP. No `SMTP_` variable is set here: the first admin account is made in the
  browser in step 7, and the password-reset screens live in files marked `.ee.`.
- Do not set `ENABLE_BULLMQ_DASHBOARD` or its two credential variables. That publishes the raw
  job queue on the same hostname, and this install has no reason to.
- Do not set `LICENSE_KEY`, and do not enable SAML, roles, templates or the public REST API under
  /api/v1. Those read files marked `.ee.`, which carry a separate commercial licence.
- Do not connect a third-party app yet and do not add any client id or secret to `.env`. Each
  connector needs its own developer registration in that company's portal, done from the Apps
  screen after login.
