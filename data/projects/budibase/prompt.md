You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Budibase 3.41.3 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until they
answer. `<DOMAIN>` is the hostname whose A record already points at this server.
`<ADMIN_EMAIL>` matters more here than usual: this prompt creates the administrator
from the environment during the first boot, so nobody who finds the hostname first can claim it.
Take it in lowercase and repeat it back.

Budibase needs 6144 MB of RAM available and 20 GB free on /srv. That is upstream's own figure.
This is the all-in-one image: one container runs CouchDB, the Clouseau search indexer, a
Structured Query Server, Redis, MinIO, an internal PostgreSQL and a LiteLLM proxy alongside the
server and worker. The image publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 6144 MB or free disk is under 20 GB, print both numbers and stop. The
pull alone is over a gigabyte, and the OOM killer arrives partway through the first boot, which
reads as random rather than as a decision made at checkout. If `dig +short` prints nothing,
print that and stop too.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/budibase /srv/budibase/backups
sudo install -d -m 755 /srv/budibase/data
ls -la /srv/budibase
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by root at mode `755`.
Leave both alone. The container starts as root and then chowns `data/couch` to its CouchDB uid
and `data/litellm` to its PostgreSQL uid, and those processes have to traverse the parent, so a
tighter mode stops the database from starting. Everything the instance keeps lands in there,
including a `.env` of secrets it writes for itself.

## 3. Secrets

Four secrets, all generated on the server. Do not print any of them, do not repeat them in your
summary, and do not put them in a log line. Hex rather than base64: a human types one of them
into a login form.

```bash
umask 077
cat > /srv/budibase/.env <<EOF
BB_ADMIN_USER_EMAIL=<ADMIN_EMAIL>
PLATFORM_URL=https://<DOMAIN>
BB_ADMIN_USER_PASSWORD=$(openssl rand -hex 24)
COUCHDB_PASSWORD=$(openssl rand -hex 32)
INTERNAL_API_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/budibase/.env
umask 022
ls -l /srv/budibase/.env
```

Assert: the file exists with mode `-rw-------`. Three of the four close a door rather than open
one. `BB_ADMIN_USER_PASSWORD` is the initial administrator password: the server creates that
account at start-up when both `BB_ADMIN_USER_` values are set on a self-hosted single-tenant
instance. That removes the window where a stranger reaches the hostname and fills in the setup
form first. `COUCHDB_PASSWORD` replaces a credential the base image bakes in as the literal word
`admin`, left alone by the start-up script precisely because it is not empty. `INTERNAL_API_KEY`
rides in the `x-budibase-api-key` header the server and worker call each other with.
`JWT_SECRET` signs session cookies and, with `API_ENCRYPTION_KEY` unset on this shape, is also
the key the platform encrypts stored API keys with.

Tell the user their password is readable with
`sudo grep BB_ADMIN_USER_PASSWORD /srv/budibase/.env` and belongs in their password manager
tonight. Keep the file: compose will not start without it, and step 8 archives it.

## 4. compose.yml

```bash
cat > /srv/budibase/compose.yml <<'EOF'
# Budibase · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ... https://docs.budibase.com/docs/docker
#   start-up script .. https://github.com/Budibase/budibase/blob/3.41.3/hosting/single/runner.sh
#
# One service, and it is a crowded one. Upstream's all-in-one image runs
# CouchDB, the Clouseau search indexer, a Structured Query Server, Redis,
# MinIO, an internal PostgreSQL and a LiteLLM proxy alongside the Budibase
# server and worker, all under pm2 behind an nginx inside the container. That
# is why no database service appears below, why the RAM floor is 6 GB, and
# why everything the instance keeps, including the .env of generated secrets
# it writes on first boot, lives under the one /data mount.
#
# CUSTOM_DOMAIN is deliberately never set: it makes the container run certbot
# for a certificate of its own, and the host's Caddy already terminates TLS.
# The container's 443 is never published, only its plain-http 80. The image
# ships its own HEALTHCHECK, so none is declared here. Tag and digest read
# from the registry on 2026-08-12; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  budibase:
    image: budibase/budibase:3.41.3@sha256:f05b90c2b8afc951feb99931bb4646d2c94af37d9c576ef3c4e01d4fdc296dc1
    container_name: budibase
    restart: unless-stopped
    env_file: /srv/budibase/.env
    environment:
      # Upstream ships product analytics on for self-hosted instances. The
      # string "0" is the off switch: backend-core coerces "0" and "false"
      # to a disabled value before anything reads it.
      ENABLE_ANALYTICS: "0"
    volumes:
      - /srv/budibase/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8187.
      - "127.0.0.1:8187:80"
EOF
cd /srv/budibase && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, one mount.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site here.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-budibase
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Budibase · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.budibase.com/docs/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also PLATFORM_URL in .env, the address
# Budibase builds app and invitation links against, so the two have to agree.

<DOMAIN> {
	# The nginx inside the container proxies /db/ straight into the CouchDB
	# that holds every table, row and app here. Upstream documents that path
	# as an operator's route to Fauxton, CouchDB's own admin client:
	# https://docs.budibase.com/docs/accessing-couchdb . That is a tool for
	# whoever runs this box, not a page for the internet, so this refuses it.
	@couchdb path /db/*
	respond @couchdb 403

	# HSTS is the one the container cannot send for itself, because nothing
	# inside it knows it is served over https. No `encode`: the inner nginx
	# already gzips. No X-Frame-Options either, because the application sets
	# frame-ancestors itself from the workspace embed allowlist.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8187 is the loopback port compose publishes on this host. It is not
	# open in the firewall. The builder holds a WebSocket open to /socket/,
	# and reverse_proxy carries that upgrade with no extra configuration.
	reverse_proxy 127.0.0.1:8187
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-budibase, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it itself, so nothing needs scheduling.

## 6. Firewall

Two ports open, both Caddy's, and idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8187 stays closed because it is bound to 127.0.0.1. CouchDB, Redis, MinIO,
PostgreSQL and LiteLLM listen inside the container and are never published, so they have no host
port to firewall. Assert: `ufw status verbose` prints `Status: active`, shows 80,
443/tcp and 443/udp, and no rule for 8187, 5984, 6379, 9000 or 5432.

## 7. Start and verify

The first boot is slow and meant to be: over a gigabyte to pull, then CouchDB's system
databases, PostgreSQL's `initdb` and LiteLLM's migrations before the server and worker start.
Fifteen minutes on a small box is normal.

```bash
cd /srv/budibase
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/system/status
curl -sS https://<DOMAIN>/api/global/configs/checklist | grep -o '"adminUser":{"checked":[a-z]*'
docker compose exec -T budibase curl -sS -o /dev/null -w '%{http_code}\n' -u admin:admin http://127.0.0.1:5984/_all_dbs
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/db/_all_dbs
docker compose exec -T budibase sh -c 'chmod 600 /data/.env && stat -c %a /data/.env'
```

Assert, all six, and print what you received for each. The loop ends printing `200`. The status
response contains `"version":"3.41.3"`, the running build agreeing with the pinned tag, not
with whatever a cached layer held. The checklist prints `"adminUser":{"checked":true`, the
security assert here: the administrator existed before the port ever answered a stranger, so
there was no setup form to walk into. The fourth prints `401`, so the CouchDB credential the
base image bakes in is dead. The fifth prints `403`, so Caddy refuses the path that would reach
that database from the internet. The last prints `600`: the container writes that file with its
own umask, and CouchDB and PostgreSQL run in there as uids of their own.

If any of the six misses, stop, run `docker compose logs --tail 80 budibase`, and name the
likely cause: a `502` past fifteen minutes is step 4 or memory, a certificate error is step 5,
and `"adminUser":{"checked":false` means the `BB_ADMIN_USER_` lines never reached the container,
which is step 3. On a `false`, do not open the site and do not create an account by hand. Reset
while nothing is at stake: `docker compose down`, `sudo rm -rf /srv/budibase/data`,
`sudo install -d -m 755 /srv/budibase/data`, confirm both lines are in `.env`, then
`docker compose up -d` and run this block again. A running container is not success.

The first screen at https://<DOMAIN> is the sign-in form, headed `Log in to Budibase`, not the
`Create an admin user` screen. That difference is the whole point of step 3.

STOP: tell the user to read their password with
`sudo grep BB_ADMIN_USER_PASSWORD /srv/budibase/.env`, sign in at https://<DOMAIN> with
`<ADMIN_EMAIL>`, change the password in their account settings, and wait.
Do not continue until they confirm they are signed in. There is no mail server here, so there is
no reset link: the password they set now is the only way back in.

## 8. First backup and restore

One archive, taken with the container stopped. Several storage engines write in there, and a
tar of a live CouchDB is not a backup but a file that resembles one.

```bash
cd /srv/budibase
docker compose stop
sudo tar -czf /srv/budibase/backups/budibase-$(date +%F).tar.gz -C /srv/budibase compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/budibase/backups/
```

Assert: the archive exists and is non-empty. Print its size. The stop and start cost several
minutes while the container brings every engine back up. Upstream sells in-product workspace
backups as a licensed feature, so this archive is the backup here.

A backup on the same disk is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/budibase
scp vps:/srv/budibase/backups/*.tar.gz ~/backups/budibase/
```

To restore: `docker compose down`, `sudo rm -rf /srv/budibase/data`,
`sudo tar -xzf /srv/budibase/backups/<archive> -C /srv/budibase`, `docker compose up -d`, then
re-run step 7's checks. Untar with sudo, always: the archive carries the uids CouchDB and
PostgreSQL own their directories as, and flattening those owners gives a container that starts
and databases that do not. `.env` is in the archive on purpose and goes back before the first
start: data restored beside a fresh `JWT_SECRET` signs every session out and cannot decrypt the
API keys the old one encrypted. Those four commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/Budibase/budibase/releases. 3.41.3 was the newest
stable release on the day this was pinned. Take step 8's backup first, then edit the image line
in /srv/budibase/compose.yml to the new tag and digest:

```bash
cd /srv/budibase
docker compose pull
docker compose up -d
docker compose logs --tail 60 budibase
```

Budibase migrates its own databases on the way up: watch that log until it settles, then
re-run step 7's checks before calling the update done. Releases land often, sometimes several
times a week: pick a cadence rather than chasing every tag.

## 10. What will probably go wrong

The first boot log. I tailed the container, read a block of capital letters saying `did not
exist; generated fresh secrets for` and a warning about data being lost on restart, and took
it all down assuming the volume was wrong. It was not.
The start-up script prints that whenever `/data/.env` is absent, which on a correct install
happens exactly once, a moment before it writes the file. To tell it from the real failure,
restart the container and look again: if it reappears, `/data` is not persisting and step 2 is
where to look. If it does not, that line is history.

## 11. Out of scope

- Do not set `CUSTOM_DOMAIN`. It makes the container run certbot for its own certificate on
  port 443, which fights the Caddy that already holds the hostname.
- Do not configure SMTP. Budibase runs without it; what it costs is invitation and
  password-reset email, a trade the user makes later, not a step here.
- Do not point `COUCH_DB_URL`, `REDIS_URL` or `DATABASE_URL` outside the container. The embedded
  engines are the shape of this install and moving them is a migration.
- Do not remove the `/db/` rule from the Caddy block, and do not enter a Budibase licence key.
  This installs the community edition on its free self-hosted licence.
