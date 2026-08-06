This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing PeerTube 8.2.4 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box, and `<ADMIN_EMAIL>` with the address you want on the administrator account.

Read this before step 1. `<DOMAIN>` becomes `PEERTUBE_WEBSERVER_HOSTNAME`, which is written into
every embed code and every federated video URL this instance publishes. Change it later and every
one of those breaks. Read step 10 too, before you upload anything: transcoding is why this feels
slow, and it is not a fault.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `40` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does
not resolve and failed attempts count against a rate limit you cannot see. If the disk figure is
short, stop and resize now rather than later: 40 GB is the floor before a single video, and HLS
keeps every upload as segments on top of whatever else lives on that disk. Upstream's own floor
is 1.5 GB of RAM for PeerTube alone; the rest of the 2048 is PostgreSQL and Redis.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/peertube /srv/peertube/backups
sudo install -d -m 750 -o 999 -g 999 /srv/peertube/data /srv/peertube/config
sudo install -d -m 700 /srv/peertube/postgres /srv/peertube/redis
ls -la /srv/peertube
```

You should see: five entries. `backups` owned by you, `data` and `config` owned by uid `999`,
and `postgres` and `redis` at mode `drwx------` owned by root.

If you do not: leave `postgres` and `redis` owned by root on purpose. Both images chown their own
data directory the first time they start, and one you have already chowned to yourself makes
PostgreSQL refuse to initialise. The 999 on the other two is the PeerTube image's own service
account: its entrypoint walks /data at every start and chowns anything it does not own, so doing
it once here keeps that walk short forever.

## 3. Secrets

Three secrets, all generated here on the server: the PostgreSQL password, the key PeerTube signs
tokens and TOTP with, and the password its built-in `root` account gets created with. Hex rather
than base64, because Docker Compose reads this same file for variable interpolation and a `$` in
a value would be expanded.

```bash
umask 077
cat > /srv/peertube/.env <<EOF
PEERTUBE_WEBSERVER_HOSTNAME=<DOMAIN>
PEERTUBE_ADMIN_EMAIL=<ADMIN_EMAIL>
POSTGRES_PASSWORD=$(openssl rand -hex 32)
PEERTUBE_SECRET=$(openssl rand -hex 32)
PT_INITIAL_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/peertube/.env
umask 022
ls -l /srv/peertube/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` and
`<ADMIN_EMAIL>` on the first two lines with your real values before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/peertube/.env` and carry on.
If the file already existed from an earlier attempt, this block has now overwritten all three
secrets, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed one on an existing directory shows up as an
authentication failure in the PeerTube log rather than as anything about passwords.

Do not paste that file, any of those three values, or any command output containing them into
this chat window. Read your own password once with
`grep PT_INITIAL_ROOT_PASSWORD /srv/peertube/.env` and put it straight into your password
manager. That third line is the whole reason this install does not follow upstream's own
instruction to read the root password out of the container log: setting it yourself means you
already have it. PeerTube does still write it to its own log once at first boot, and anyone who
can read that log can read this file too, so on a one-admin box it is the same boundary.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/peertube/compose.yml <<'EOF'
# PeerTube · the deterministic fallback. Authored by caniselfhostit from the
# upstream docs, not copied from a repository:
#   https://docs.joinpeertube.org/install/docker
#   https://github.com/Chocobozzz/PeerTube/tree/v8.2.4/support/docker/production
#
# Three services. Upstream's compose ships seven: nginx, certbot and a reload
# loop in front, a postfix relay behind. Caddy replaces the first three. No
# postfix means no mail: one admin, closed signup, a password reset from a
# shell. PeerTube connects as the superuser the PostgreSQL image creates,
# because it runs CREATE EXTENSION for pg_trgm and unaccent at first boot.
# Digests read 2026-08-06; all three are multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    restart: unless-stopped
    environment:
      POSTGRES_DB: peertube
      POSTGRES_USER: peertube
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/peertube/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U peertube -d peertube"]
      interval: 10s
      retries: 18
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    # Session store and job queue. Appendonly keeps queued jobs.
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/peertube/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 18

  peertube:
    image: chocobozzz/peertube:v8.2.4@sha256:fee7ff44b9705401d8c228227e770257f088c3f3cb056746493888344a5a0324
    restart: unless-stopped
    env_file: /srv/peertube/.env
    environment:
      PEERTUBE_DB_HOSTNAME: postgres
      PEERTUBE_DB_USERNAME: peertube
      PEERTUBE_DB_PASSWORD: ${POSTGRES_PASSWORD}
      PEERTUBE_DB_SSL: "false"
      PEERTUBE_REDIS_HOSTNAME: redis
      # Caddy terminates TLS; without these two, every URL PeerTube
      # writes would say http.
      PEERTUBE_WEBSERVER_HTTPS: "true"
      PEERTUBE_WEBSERVER_PORT: "443"
      # Trust the docker bridge, so rate limits see real client IPs.
      PEERTUBE_TRUST_PROXY: '["loopback","linklocal","uniquelocal"]'
      # Closed registration, stated rather than assumed. Upstream agrees.
      PEERTUBE_SIGNUP_ENABLED: "false"
      PEERTUBE_CONTACT_FORM_ENABLED: "false"
      # Live wants a second published port and transcoding pipeline.
      PEERTUBE_LIVE_ENABLED: "false"
    volumes:
      # Videos, HLS segments, thumbnails, logs. The one that grows.
      - /srv/peertube/data:/data
      # PEERTUBE_LOCAL_CONFIG: what the admin UI writes.
      - /srv/peertube/config:/config
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8124.
      - "127.0.0.1:8124:9000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/peertube && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/peertube/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/peertube/compose.yml` and paste again in one go. Nothing in this file is optional.
PeerTube will not start without Redis, and it creates two PostgreSQL extensions on first boot,
which is why it connects as the superuser the image makes rather than a role of its own.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-peertube
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# PeerTube · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/Chocobozzz/PeerTube/blob/v8.2.4/support/nginx/peertube,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Upstream ships a 262-line nginx config and a container to run it in. This
# block replaces both; each comment names the nginx setting it stands in for.
# Its ciphers, certbot and ACME webroot become Caddy's automatic HTTPS; its
# sendfile, aio and limit_rate are dropped as I/O tuning.
#
# Append to /etc/caddy/Caddyfile with <DOMAIN> replaced by your hostname.

<DOMAIN> {
	# nginx: client_max_body_size 12G on the upload routes. Caddy applies
	# no limit unless told to, so one ceiling is tighter than the default.
	# Upstream's per-route regexes are not copied: such a list rots the day
	# PeerTube adds an endpoint.
	request_body {
		max_size 12GB
	}

	# nginx: X-File-Maximum-Size, which PeerTube's uploader reads off a
	# 413. 8GB against a 12GB cap because multipart encoding inflates a
	# body by about 1.4x. Upstream pairs the same two numbers.
	header /api/v1/videos/upload* X-File-Maximum-Size "8GB"

	header {
		# PeerTube sets its own X-Frame-Options, so this does not.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# nginx: gzip on CSS, JS, fonts, SVG and XML. Caddy's default matcher
	# is that list and holds no video type, so HLS segments and Range
	# requests pass through untouched and seeking works.
	encode zstd gzip

	# 8124 is the loopback port compose publishes here, not a container
	# port and not open in the firewall. Three nginx settings need nothing
	# written: proxy_request_buffering off (Caddy never spools a request
	# body to disk), proxy_read_timeout 15m (no transport read timeout) and
	# the Upgrade headers on the socket routes (reverse_proxy upgrades
	# WebSockets itself).
	reverse_proxy 127.0.0.1:8124
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-peertube /etc/caddy/Caddyfile`, reload,
and paste again. The one line worth understanding is `request_body`: Caddy has no request body
limit unless you set one, so without that block a 12 GB ceiling would be no ceiling at all, and
with it your uploads stop at 12 GB rather than at nginx's default of 1 MB. Caddy terminates TLS
and speaks plain http to the container, which is why `PEERTUBE_WEBSERVER_HTTPS` is true in the
compose file.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8124`, `5432`, `6379` or `1935`.

If you do not: delete anything for those four with `sudo ufw delete allow 8124`. 8124 is bound to
127.0.0.1 by the compose file, 5432 and 6379 are never published at all, and 1935 is the RTMP
port live streaming would want, which this install leaves off. 80/tcp is there to redirect to
HTTPS and answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

PeerTube runs its own database migrations, creates the `root` account from
`PT_INITIAL_ROOT_PASSWORD` and builds its storage tree on the way up. On a cold pull the first
boot takes several minutes; the loop below waits ten.

```bash
cd /srv/peertube
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/ping; echo
curl -sS https://<DOMAIN>/api/v1/config | grep -o '"signup":{"allowed":false'
curl -sS https://<DOMAIN>/api/v1/accounts/root | grep -o '"name":"root"'
curl -sS https://<DOMAIN>/login | grep -o 'og:platform" content="PeerTube"'
```

You should see, in order: the loop reaching `200`, then `pong`, then
`"signup":{"allowed":false`, then `"name":"root"`, then `og:platform" content="PeerTube"`.

If you do not: the `"signup":{"allowed":false` line is the one with security meaning. It says
nobody but you can make an account on this server, and if it prints nothing, stop and check that
`PEERTUBE_SIGNUP_ENABLED` really is `"false"` in the compose file before you leave this running
on a public hostname. If the loop never reaches `200`, run `docker compose logs --tail 20 postgres`
first, because a database that never reports healthy is step 2 done wrong, then
`docker compose logs --tail 40 peertube`. A log line about `pg_trgm` means PeerTube is not
connecting as the superuser PostgreSQL created. A `502` from Caddy with all three containers up
is step 5. A running container is not success.

The first screen at https://<DOMAIN>/login shows the heading `Login on PeerTube` over a
`Username or email address` box, a `Password` box and a `Login` button.

Now read your password, sign in, and upload something:

```bash
grep PT_INITIAL_ROOT_PASSWORD /srv/peertube/.env
```

You should see: one line. Put the value in your password manager, do not paste it here, sign in
at https://<DOMAIN>/login as `root`, then upload one short video at
https://<DOMAIN>/videos/upload and wait for it to play back. That is the product working end to
end: a file went in, ffmpeg re-encoded it to HLS on this box, and it came back out through Caddy.

If you do not get a playable video: read step 10 before you conclude anything is broken. There is
no mail on this install, so a forgotten password is recovered with
`docker compose exec -u peertube peertube npm run reset-password -- -u root`, not by email.

## 8. First backup and restore

Two artifacts. The database holds the accounts, the video records, the comments and the view
counts. The config archive holds what rebuilds the service around them. The video files are in
neither, on purpose: /srv/peertube/data runs to tens of gigabytes and wants its own copy.

```bash
cd /srv/peertube
docker compose exec -T postgres pg_dump -U peertube -d peertube | gzip > /srv/peertube/backups/peertube-db-$(date +%F).sql.gz
sudo tar -czf /srv/peertube/backups/peertube-config-$(date +%F).tar.gz -C /srv/peertube compose.yml .env config -C /etc/caddy Caddyfile
ls -lh /srv/peertube/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/peertube
scp vps:/srv/peertube/backups/* ~/backups/peertube/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/peertube/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one test video:

```bash
cd /srv/peertube
docker compose down
sudo rm -rf /srv/peertube/postgres
sudo install -d -m 700 /srv/peertube/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/peertube/backups/peertube-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U peertube -d peertube
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/ping
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command, and
your test video still on the site.

If you do not: `role "peertube" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand the stakes before you
skip this: the dump and the `data` folder travel together or neither is worth much, because a
restored database whose rows point at video files nobody copied is a catalogue of dead links.

## 9. Updating later

New versions are listed at https://github.com/Chocobozzz/PeerTube/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/peertube/compose.yml to the new tag and its
digest.

```bash
cd /srv/peertube
docker compose pull
docker compose up -d
docker compose logs --tail 40 peertube
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. A major version
can spend minutes migrating the database, so watch that log until it settles rather than
interrupting it, then re-run the five checks from step 7 before you call the update done.

## 10. What will probably go wrong

The first upload will look like a broken install. Mine did: the page said the video was published,
the video page showed a spinner where the player belongs, and the logs read like nothing was
happening for eleven minutes. Nothing was wrong. PeerTube had handed the file to ffmpeg with one
thread, upstream's default, and a two-core VPS re-encodes ten minutes of 1080p in about real time
or worse. That container near 100% CPU in `docker stats` is this working, not failing. If you want
it faster, the honest answers are more cores or a remote runner.

## 11. Out of scope

- Do not enable live streaming. It wants port 1935 open to the internet and a second transcoding
  pipeline running the whole time somebody watches.
- Do not configure SMTP or add upstream's postfix container. Registration is closed and there is
  one account, whose password is reset with
  `docker compose exec -u peertube peertube npm run reset-password -- -u root`.
- Do not enable object storage. Moving video to S3 is right for a growing instance, and it is a
  bucket, a credential pair and a base URL this prompt has not set up.
- Do not follow other instances or turn on auto-follow. That pulls remote videos and comments onto
  this disk, and it is your call.
