You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Baserow 2.3.3 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. That hostname becomes `BASEROW_PUBLIC_URL`, and
the Caddy inside the container matches the Host header against it to decide whether a request is
Baserow's, so changing it later takes the API routes down.

Baserow needs 4096 MB of RAM available and 10 GB free on /srv. That floor is not padding: the
image upstream calls all-in-one runs a PostgreSQL 15 and a Redis inside the same container as
the Django backend, the Nuxt web frontend and a Caddy of its own, and upstream's own capacity
guidance for one of these containers is 2 vCPU and 4 GB even when the database sits outside it.
The image publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope: the OOM killer arrives partway through the first migration and the failure
looks random. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/baserow /srv/baserow/backups
sudo install -d -m 755 /srv/baserow/data
ls -la /srv/baserow
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by root. Leave `data`
to root. The container starts as root and chowns that directory to uid 9999 before it drops
privileges, and the PostgreSQL inside it refuses to initialise in a directory somebody else
already owns. Everything the instance keeps lands under there: the database cluster, the Redis
dump, the uploaded files and the plugins.

## 3. Secrets

Two secrets: the Django secret key and the JWT signing key. The image generates a pair of its
own into /baserow/data if none arrive from outside, and values set from outside win, so generate
them here where they land in a file the backup carries. Do not print either, do not repeat them
in your summary, and do not put them in any log line.

```bash
umask 077
cat > /srv/baserow/.env <<EOF
BASEROW_PUBLIC_URL=https://<DOMAIN>
SECRET_KEY=$(openssl rand -hex 32)
BASEROW_JWT_SIGNING_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/baserow/.env
umask 022
ls -l /srv/baserow/.env
```

Assert: the file exists with mode `-rw-------`. Hex rather than base64, because both values are
read by a shell before Django ever sees them and neither wants escaping. Tell the user to read
the pair back with `sudo grep -E 'SECRET_KEY|SIGNING_KEY' /srv/baserow/.env` and put both in
their password manager tonight. The first signs session cookies, the second signs every API
token, and a restore without them logs everybody out of an instance that no longer recognises
its own tokens.

## 4. compose.yml

```bash
cat > /srv/baserow/compose.yml <<'EOF'
# Baserow · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://baserow.io/docs/installation%2Finstall-with-docker
#   variable reference . https://baserow.io/docs/installation%2Fconfiguration
#   capacity guidance .. https://baserow.io/docs/installation%2Finstall-on-aws
#   supported versions . https://baserow.io/docs/installation%2Fsupported
#
# One service, and it is five processes wearing one hat. Upstream's all-in-one
# image runs a PostgreSQL 15 and a Redis inside this same container next to the
# Django backend, the Nuxt web frontend and a Caddy of its own, and keeps every
# byte of that under /baserow/data. That is why no database service appears
# below, and why the RAM floor is 4 GB rather than the few hundred megabytes a
# web application on its own would want.
#
# BASEROW_CADDY_ADDRESSES is pinned to :80 so the container's Caddy serves plain
# http and never asks Let's Encrypt for anything. The host Caddy already holds
# the hostname and terminates TLS, so only the container's port 80 is published.
# Tag and digest were read from Docker Hub on 2026-08-07; the image publishes
# amd64 and arm64. The image carries its own HEALTHCHECK, so this file adds
# none.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  baserow:
    image: baserow/baserow:2.3.3@sha256:41adb3493379403946a493f30873f743bb65b19b5f387d630ec75f41e25d5b5b
    container_name: baserow
    restart: unless-stopped
    env_file: /srv/baserow/.env
    environment:
      # :80 keeps the inner Caddy on plain http and off the ACME path.
      BASEROW_CADDY_ADDRESSES: ":80"
      # The host Caddy terminates TLS and sets X-Forwarded-Proto itself, which
      # is the condition upstream names for turning this on. Without it the
      # paginated API hands out http:// links for an https-only service.
      BASEROW_ENABLE_SECURE_PROXY_SSL_HEADER: "yes"
      # One celery worker running both the fast and the slow queue. Upstream
      # names this pair as the way to lower the image's memory use, and the
      # price is that a large export can delay a realtime row update.
      BASEROW_AMOUNT_OF_WORKERS: "1"
      BASEROW_RUN_MINIMAL: "yes"
    volumes:
      - /srv/baserow/data:/baserow/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8175.
      - "127.0.0.1:8175:80"
EOF
cd /srv/baserow && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-baserow
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Baserow · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://baserow.io/docs/installation%2Finstall-with-docker,
# https://baserow.io/docs/installation%2Fconfiguration and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also BASEROW_PUBLIC_URL in .env. The container's own Caddy decides whether a
# request is for Baserow by comparing the Host header against that value, so
# the two have to stay the same string or the API routes stop answering.

<DOMAIN> {
	# The web frontend is a large JavaScript bundle and the API answers JSON.
	# The container's Caddy compresses neither, so this is the only place it
	# happens. Uploaded files are served from the same hostname and Caddy
	# leaves already-compressed images alone.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# Realtime collaboration holds a websocket open on /ws/, and reverse_proxy
	# carries that upgrade with no extra directive. Caddy also sets
	# X-Forwarded-Proto here, which is what lets the container be told it is
	# behind https.
	#
	# 8175 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8175
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-baserow, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own, so there is nothing to schedule.

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
443/udp is HTTP/3. 8175 stays closed because compose binds it to 127.0.0.1. The PostgreSQL and
the Redis live inside the container and are never published at all, so there is no host port for
them to firewall. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8175, 5432 or 6379.

## 7. Start and verify

The first boot is slow. The pull is over a gigabyte, then PostgreSQL initialises a cluster,
Django runs every migration from scratch and the built-in templates import in the background.
Upstream's deployment guide asks for a 900-second grace period on a first start, and this loop
allows exactly that.

```bash
cd /srv/baserow
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/_health/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/_health/
curl -sS https://<DOMAIN>/api/settings/ | grep -o '"show_admin_signup_page":[a-z]*'
```

Assert, all three, and print what you received for each. The loop ends printing `200`. The
health endpoint answers with the two characters `OK` and nothing else. The third command prints
`"show_admin_signup_page":true`, which means no account exists yet and the next person to reach
this hostname becomes the administrator. If any of the three misses, stop, run
`docker compose logs --tail 60 baserow`, and name the likely cause: a `502` inside the first
fifteen minutes is the migrations still running, a `502` past fifteen minutes points at step 4, a
certificate error points at step 5, and a container restarting in a loop usually means the RAM
floor in step 1 was measured on a box that had already given the memory away.

The first screen at https://<DOMAIN> is the sign-up form. Baserow sends the login page straight
to it while no account exists, and it carries the notice `Welcome to Baserow!` above the line
`Please fill the form below to create the admin user.`

STOP: tell the user to open https://<DOMAIN>, fill that form in, and then, once they are signed
in, open https://<DOMAIN>/admin/settings and turn off `Allow creating new accounts`. Wait. Do
not continue until they confirm both. The first account created on an instance is given staff
rights, which is what makes it the administrator, and until that toggle is off any visitor can
make an account of their own. Tell them to put the password in their password manager as they
type it: there is no mail server here, so there is no reset link.

```bash
curl -sS https://<DOMAIN>/api/settings/ | grep -o '"show_admin_signup_page":[a-z]*'
curl -sS https://<DOMAIN>/api/settings/ | grep -o '"allow_new_signups":[a-z]*'
```

Assert: the first prints `"show_admin_signup_page":false` and the second prints
`"allow_new_signups":false`. Both must pass before you report success. A running container is
not success, and an instance still offering accounts to strangers is not success either.

## 8. First backup and restore

One archive, taken with the container stopped. A PostgreSQL cluster and a Redis are writing
inside that directory, and a tar of a live database is a file that looks like a backup.

```bash
cd /srv/baserow
docker compose stop
sudo tar -czf /srv/baserow/backups/baserow-$(date +%F).tar.gz -C /srv/baserow compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/baserow/backups/
```

Assert: the archive exists and is non-empty. Print its size. On a fresh install with the
templates imported it runs to a few hundred megabytes, and the stop and start cost about a
minute.

A backup on the same disk as the data is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/baserow
scp vps:/srv/baserow/backups/*.tar.gz ~/backups/baserow/
```

To restore: `docker compose down`, `sudo rm -rf /srv/baserow/data`, then
`sudo tar -xzf /srv/baserow/backups/<archive> -C /srv/baserow`, then `docker compose up -d`.
Untar it with sudo, always, because the archive carries the uid 9999 that PostgreSQL owns its
cluster as, and an extract that flattens those owners gives a container that starts and a
database that does not. Tell the user two things about that archive. It holds a raw copy of the
PostgreSQL data directory, so it restores into this same image and this same major version and
not into a PostgreSQL you install somewhere else. And it holds .env, which is the only copy of
the two keys from step 3. Those four commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/baserow/baserow/releases. Take the backup from
step 8 first, then edit the image line in /srv/baserow/compose.yml to the new tag and its digest:

```bash
cd /srv/baserow
docker compose pull
docker compose up -d
docker compose logs --tail 40 baserow
```

Baserow migrates its own database on the way up and prints `Baserow is now available at` when it
has finished. Watch that log until that line appears, then re-run the health check from step 7
before calling the update done.

## 10. What will probably go wrong

The wait. I brought this up on a 4 GB box, watched the browser return `502` for eleven minutes,
decided the reverse proxy was wrong and started taking the Caddy block apart. Nothing was wrong.
A first boot initialises a PostgreSQL cluster, runs every Django migration in order and then
imports the built-in templates, and none of that answers a request. The way to tell waiting from
broken is the loop in step 7: while it prints `502` or `000` under fifteen minutes it is still
coming up, and past fifteen minutes something is actually wrong. Read the log rather than the
browser, with `docker compose logs -f baserow`.

## 11. Out of scope

- Do not set `BASEROW_CADDY_ADDRESSES` to `:443` or to an https URL. That makes the container
  ask Let's Encrypt for its own certificate on a hostname the host Caddy already holds.
- Do not configure SMTP. Baserow runs without it; what it costs is invitation mail and
  password-reset mail, and that is a decision the user makes later, not a step here.
- Do not point `DATABASE_URL` or `REDIS_URL` at anything outside the container. The embedded
  pair is the shape of this install, and moving them is a migration rather than a setting.
- Do not add a licence key or install any premium or enterprise feature. This prompt installs
  the free edition, which is the MIT-licensed part of the repository.
