You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Kener 4.1.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and the same hostname becomes `ORIGIN` in
step 3.

Say two things to the user before anything installs. One: a monitor cannot tell them that the
machine it runs on is down, so this belongs on a box other than the ones it watches, and they
should keep one free external check pointed at this hostname from a service they do not run.
Two: what goes on that hostname is a public status page. It answers everybody by design, and
every monitor name and description they add later is published to whoever loads it. The manage
screens behind it are not public, and step 7 closes the one window where that is not yet true.

Kener needs 1024 MB of RAM available and 5 GB free on /srv. Both images publish amd64 and
arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a hostname that does not resolve.

## 2. Layout

Three directories, three owners, and the ownership is the part that matters. The Kener image
runs as the `node` user, uid 1000, so it cannot write a directory owned by the login user. The
redis image chowns its own data directory on first start, so that one is left to root.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kener /srv/kener/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/kener/database
sudo install -d -m 750 /srv/kener/redis
ls -la /srv/kener
```

Assert: `ls -la` shows `backups` owned by the login user, `database` owned by `1000`, and
`redis` owned by root. Nothing is written outside /srv/kener. Keep `database` on local disk:
`kener.sqlite.db` is a SQLite file and a network mount corrupts one quietly, weeks later.

## 3. Secrets

One secret, `KENER_SECRET_KEY`. Upstream documents it as the key that signs the session tokens
and encrypts stored credentials, and documents `openssl rand -base64 32` as the way to make
one. Generate it on the server. Do not print it, do not repeat it in your summary, and do not
put it in any log line.

`ORIGIN` goes in the same file and is not a secret. It is the public URL SvelteKit compares
against on every form post, with no trailing slash, and step 10 is what happens when it is
wrong.

```bash
umask 077
cat > /srv/kener/.env <<EOF
ORIGIN=https://<DOMAIN>
TZ=UTC
KENER_SECRET_KEY=$(openssl rand -base64 32)
EOF
chmod 600 /srv/kener/.env
umask 022
ls -l /srv/kener/.env
```

Assert: the file exists with mode `-rw-------`, and `ORIGIN` reads `https://` followed by the
real hostname. Tell the user the key is in /srv/kener/.env, that they can read it themselves
with `sudo grep KENER_SECRET_KEY /srv/kener/.env`, and that changing it later signs everyone
out and makes anything Kener had encrypted with it unreadable, so it belongs in their password
manager today.

## 4. compose.yml

```bash
cat > /srv/kener/compose.yml <<'EOF'
# Kener · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   deployment ......... https://kener.ing/docs/v4/setup/deployment
#   environment ........ https://kener.ing/docs/v4/setup/environment-variables
#   database ........... https://kener.ing/docs/v4/setup/database-setup
#   image build ........ https://github.com/rajnandan1/kener/blob/v4.1.2/Dockerfile
#
# Two services. Redis is not optional in v4: upstream's own compose file calls
# it required for the queues, the cache and the scheduler, and the environment
# reference marks REDIS_URL required, so a Kener with no Redis runs no checks.
# No database container: DATABASE_URL is left unset, so upstream defaults to
# SQLite at ./database/kener.sqlite.db, the mount below. The image runs as the
# node user, uid 1000, which is why step 2 hands database/ to 1000. Digests
# read from the registries on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: kener-redis
    restart: unless-stopped
    volumes:
      # Queue and scheduler state only: monitors, incidents and every result
      # live in the SQLite file below. The image chowns this on first start.
      - /srv/kener/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    # No `ports:` at all: 6379 is reachable only from the other container.

  kener:
    image: ghcr.io/rajnandan1/kener:v4.1.2@sha256:239ab635b900b3fe0a4e22f5599f77525211d1b7a25b8fcf3d173936ddacc1cc
    container_name: kener
    restart: unless-stopped
    env_file: /srv/kener/.env
    environment:
      # Redis is on the compose network only, so this carries no credential.
      REDIS_URL: redis://redis:6379
      NODE_ENV: production
    volumes:
      # kener.sqlite.db: every monitor, incident, page, user and result.
      - /srv/kener/database:/app/database
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8179.
      - "127.0.0.1:8179:3000"
    depends_on:
      redis:
        condition: service_healthy
EOF
cd /srv/kener && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port. Do not add a Postgres
service: `DATABASE_URL` is unset on purpose, upstream then uses SQLite in the mounted
`database` directory, and that one file is what step 8 backs up.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-kener
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Kener · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://kener.ing/docs/v4/setup/deployment and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That same hostname is
# ORIGIN in .env: Kener hands ORIGIN to SvelteKit for the cross-site check on
# every form post, so if the two disagree the page loads and the sign-in fails.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# The status page is public and the manage screens behind it are not,
		# and both share a hostname. SAMEORIGIN protects the second, at the cost
		# of the badge embeds Kener offers for other people's sites.
		X-Frame-Options "SAMEORIGIN"
		# Upstream reads the Origin header when the browser sends one and falls
		# back to SameSite=Lax cookies when it does not, so this costs nothing.
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8179 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8179
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-kener, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3. 8179 stays closed because compose binds it to 127.0.0.1, and 6379 stays
closed because compose never publishes it, so Redis has no host port a rule could apply to. The
checks are outbound and need nothing opened. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8179, 6379 or 3000.

## 7. Start and verify

Kener runs its migrations and its seed on the way up, so the first boot writes the schema and a
starter status page before it answers anything. Use the loop, not a fixed sleep.

```bash
cd /srv/kener
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' 'https://<DOMAIN>/healthcheck?strict=1'); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthcheck; echo
curl -sSL https://<DOMAIN>/ | grep -c 'Service Status'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/monitors
curl -sSL https://<DOMAIN>/account/signin | grep -c 'Create Admin Account'
```

Assert all five, and print what you received for each. The loop ends printing `200`, and it
asks with `?strict=1` on purpose: upstream answers `200` from `/healthcheck` even when a
dependency is down, and only the strict form turns that into `503`. The plain call then prints
`{"status":"ok","db":true,"redis":true}`, and all three fields matter. The third command prints
a number greater than `0`, because `Service Status` is the heading the seeded status page
renders. The API call prints `401`, upstream's answer to a request carrying no bearer token,
and that is the security assert in this block. The last prints a number greater than `0`,
because with no users yet the sign-in page is a `Create Admin Account` form. If any of the five
misses, stop, run `docker compose logs --tail 40 kener`, then
`docker compose logs --tail 20 redis`, and name the likely earlier step: a Redis that never
reports healthy holds the app in `depends_on` and points at step 4, and a 502 from Caddy with
both containers up points at step 5. A running container is not success.

That `Create Admin Account` form is open to whoever loads the hostname first. Close it now.

STOP: tell the user to open https://<DOMAIN>/account/signin, fill in a name, an email address
and a password to create the administrator account, and save that password in their password
manager. Wait. Do not continue until they confirm.

Once they confirm, prove the window is shut:

```bash
curl -sSL https://<DOMAIN>/account/signin | grep -c 'Create Admin Account'
curl -sSL https://<DOMAIN>/account/signin | grep -c 'Sign In'
```

Assert: the first prints `0` and the second prints a number greater than `0`. Upstream's signup
action refuses once one user exists, so that page is a login form from here on. Both asserts
must pass before you report success.

## 8. First backup and restore

One archive: the SQLite database, the environment file, the compose file and the live Caddy
site block. Redis is not in it, because it holds queue and scheduler state that rebuilds
itself, while every monitor, incident, page, user and result is in the SQLite file.

```bash
cd /srv/kener
docker compose stop
sudo tar -czf /srv/kener/backups/kener-$(date +%F).tar.gz -C /srv/kener database .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/kener/backups/
```

Assert: the archive exists and is non-empty. Print its size. The containers are stopped on
purpose and downtime is a few seconds, because a SQLite file copied mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this one from the user's machine,
not the server:

```bash
mkdir -p ~/backups/kener
scp vps:/srv/kener/backups/*.tar.gz ~/backups/kener/
```

To restore: `docker compose down`, `sudo rm -rf /srv/kener/database`, recreate that directory
as in step 2, untar the archive back into /srv/kener, put the Caddy block back if that is what
was lost, then `docker compose up -d`. Tell the user what the archive holds in plain terms:
`database/kener.sqlite.db` is their monitors, their incident history and their administrator
account, and `.env` is the key that decrypts what Kener stored under it, so the two are worth
nothing apart.

## 9. Updating later

New versions are listed at https://github.com/rajnandan1/kener/releases. The release tag and
the image tag are the same string, so release `v4.1.3` is image tag `v4.1.3`. Take a backup
first, then edit the image line in /srv/kener/compose.yml to the new tag and its digest:

```bash
cd /srv/kener
docker compose pull
docker compose up -d
docker compose logs --tail 30 kener
```

Kener runs its migrations on the way up, so watch that log until it settles, then re-run step
7's health check and the `Service Status` grep before calling the update done.

## 10. What will probably go wrong

The sign-in that fails on a page that loads. I had `ORIGIN` set with a trailing slash, and
everything else looked right: the status page rendered, the health check said ok, the
`Create Admin Account` form appeared. Submitting it returned a bare
`Cross-site POST form submissions are forbidden`, and I spent twenty minutes in Caddy's logs
looking for a problem that was one character in .env. Kener hands `ORIGIN` to SvelteKit, which
compares it against the host the browser used on every form post; a trailing slash, an `http://`
where the browser said `https://`, or a `www.` on one side only are all mismatches. If step 7's
STOP will not complete, run `grep ORIGIN /srv/kener/.env` first, fix it, then
`docker compose up -d --force-recreate` before touching anything else.

## 11. Out of scope

- Do not set `DATABASE_URL` and do not add a Postgres or MySQL service. SQLite is the choice
  here, and it is why the whole install is one directory and one file to copy.
- Do not configure SMTP, `RESEND_API_KEY`, or any alerting provider. Every one of them is an
  account or a key somewhere else, and the user wires those up in the manage screens.
- Do not set `KENER_BASE_PATH` and do not switch to a `-status` image variant. Those exist for
  serving Kener under a subpath of a hostname that already has a site, and they are a different
  image built at a different base path.
- Do not publish 3000 or 6379 on the host and do not open either in the firewall. Caddy is the
  only way in, and Redis is reachable only from the other container.
