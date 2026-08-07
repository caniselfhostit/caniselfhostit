You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install PocketBase 0.39.10 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. The A record for `<DOMAIN>` must already point at this server. `<ADMIN_EMAIL>` is
the address the superuser account is created under, and it is the name the user types into the
dashboard login form. No mail is ever sent to it by this install.

PocketBase needs 512 MB of RAM available and 5 GB free on /srv. The image publishes amd64,
arm64 and armv7. Measure all four before installing:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a hostname that does not resolve, and failed attempts count against a rate
limit nobody can see.

## 2. Layout

The container runs as uid 1000, so the data directory belongs to 1000 rather than to the login
user. Backups stay with the login user, because the login user is who copies them off the box.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/pocketbase /srv/pocketbase/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/pocketbase/data
ls -la /srv/pocketbase
```

Assert: `ls -la` shows `data` owned by `1000` and `backups` owned by the login user. Nothing is
written outside /srv/pocketbase. Keep `data` on local disk: it holds a SQLite database, and
SQLite on a network mount corrupts quietly and weeks later.

## 3. Secrets

One secret: the password of the first superuser account. Generate it on the server. Do not
print it, do not repeat it in your summary, and do not put it in any log line. Hex rather than
base64, because the user retypes this string into a browser login form and hex has no
characters they can mistake for each other.

```bash
umask 077
cat > /srv/pocketbase/.env <<EOF
PB_ADMIN_EMAIL=<ADMIN_EMAIL>
PB_ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/pocketbase/.env
umask 022
ls -l /srv/pocketbase/.env
```

Assert: the file exists with mode `-rw-------`. The image's entrypoint reads those two
variables and runs `pocketbase superuser upsert` against the data directory before it starts
the web server, so the superuser exists before the port ever answers a request. There is no
default account, no blank password and no open signup window to close afterwards, which is why
step 7 asserts the API refuses an unauthenticated call rather than asserting a form went away.

Tell the user: their password is in /srv/pocketbase/.env, they read it with
`sudo grep PB_ADMIN_PASSWORD /srv/pocketbase/.env`, and it belongs in their password manager
now.

## 4. compose.yml

```bash
cat > /srv/pocketbase/compose.yml <<'EOF'
# PocketBase · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   introduction ....... https://pocketbase.io/docs/
#   production notes ... https://pocketbase.io/docs/going-to-production/
#   health endpoint .... https://pocketbase.io/docs/api-health/
#   image entrypoint ... https://github.com/muchobien/pocketbase-docker/blob/22f36a08837f26b22a3327cb8066ad63c3362c70/entrypoint.sh
#
# One container. PocketBase is a single Go binary with SQLite compiled into it,
# so there is no database service here, and no Caddy service either: Prompt Zero
# already runs Caddy under systemd on the host.
#
# The PocketBase project publishes no image. Its production page states that
# PocketBase doesn't have an official Docker image, so this file uses
# ghcr.io/muchobien/pocketbase, built outside the PocketBase project from the
# revision named above, which is the one this digest was built from. That
# Dockerfile downloads upstream's own release zip for the target architecture
# and unpacks it, and it does not check that zip against the checksums.txt
# upstream publishes beside it. Neither does the example Dockerfile in
# upstream's own docs. What fixes the bytes you run is the digest below, which
# names one build and nothing else, and step 7 asserts the binary inside it
# reports 0.39.10. Digest read from ghcr.io on 2026-08-07; the index carries
# linux/amd64, linux/arm64 and linux/armv7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  pocketbase:
    image: ghcr.io/muchobien/pocketbase:0.39.10@sha256:dfebd2550d6b5176d67afd3e859f9b642096e624c7f6ada1b5a5bc70a5d21be1
    container_name: pocketbase
    restart: unless-stopped
    # The image declares no USER, so without this line it runs as root.
    # PocketBase writes nothing outside its data directory, so uid 1000 is
    # enough, and step 2 hands that directory to 1000.
    user: "1000:1000"
    env_file: /srv/pocketbase/.env
    environment:
      # Inside the container the server has to listen on every interface, or
      # the loopback port published on the host reaches nothing. 8090 is the
      # port the image's entrypoint defaults to, named here so a change to
      # that default cannot move it under the healthcheck and the Caddy block.
      PB_HOST: "0.0.0.0"
      PB_PORT: "8090"
    volumes:
      # The one mount: data.db, every uploaded file, and PocketBase's own
      # backup archives. Local disk only: SQLite needs real POSIX file locks,
      # and a network mount corrupts it quietly.
      - /srv/pocketbase/data:/pb_data
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8090/api/health || exit 1"]
      start_period: 10s
      interval: 15s
      retries: 10
    ports:
      # Loopback only. The host's Caddy is the only thing that reaches 8166,
      # and 8166 never enters the firewall.
      - "127.0.0.1:8166:8090"
EOF
cd /srv/pocketbase && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on 8090 inside itself, 8166 is bound to
127.0.0.1 on the host, and Caddy is the only route in.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-pocketbase
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# PocketBase · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://pocketbase.io/docs/going-to-production/ and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# No `encode` directive here, on purpose. PocketBase's realtime endpoint is
	# a long-lived text/event-stream, which Caddy flushes to the client
	# immediately instead of buffering, and a compressor in front of a stream
	# that carries JSON this small earns nothing.
	#
	# reverse_proxy sets X-Forwarded-For itself and ignores whatever the client
	# sent in that header, which is what makes it safe to name in PocketBase's
	# User IP proxy headers setting.
	#
	# 8166 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8166
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-pocketbase, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own, so there is nothing to schedule.

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
443/udp is HTTP/3. 8166 stays closed because compose binds it to 127.0.0.1, so a rule for it
would cover traffic that cannot arrive; if a previous run left one, `sudo ufw delete allow 8166`
removes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp,
and no rule for 8166.

## 7. Start and verify

The entrypoint creates the superuser from the two variables in .env, then starts the server.

```bash
cd /srv/pocketbase
docker compose pull
docker compose up -d
docker compose exec -T pocketbase pocketbase --version
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/api/health
echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/collections
docker compose logs pocketbase | grep -c 'Successfully saved superuser'
```

Assert, all five, and print what you received for each. The version line contains `0.39.10`,
which is how you know the community image carries upstream's release binary and not an older
one. The loop ends printing `200`. The health body contains
`"message":"API is healthy."`. The unauthenticated call to `/api/collections` prints `401`,
which is the security assert in this block: that route requires a superuser token and refuses
without one. The last command prints a number of at least `1`, meaning the superuser account
was written before the server accepted its first request.

If any of the five misses, stop, run `docker compose logs --tail 40 pocketbase`, and say which
earlier step is the likely cause. A `403` where a `401` was expected means something else is
answering on that hostname. `curl: (35)` or a certificate error points at step 5 or at DNS. A
container that restarts in a loop with a permissions error on `/pb_data` points at step 2. A
running container is not success.

The first screen at https://<DOMAIN>/_/ is a login form headed `Superuser login`, with an email
field and a password field and no way to create an account.

STOP: tell the user to open https://<DOMAIN>/_/, read their password with
`sudo grep PB_ADMIN_PASSWORD /srv/pocketbase/.env`, sign in with `<ADMIN_EMAIL>` and that
password, and save both in their password manager. Wait until they are looking at the
dashboard. Do not continue until they confirm.

## 8. First backup and restore

Take the backup now, before the user creates a single collection. Stop the container first:
upstream says plainly that copying `pb_data` is the backup, and that the application must not be
running while it happens.

```bash
cd /srv/pocketbase
docker compose stop
sudo tar -czf /srv/pocketbase/backups/pocketbase-$(date +%F).tar.gz -C /srv/pocketbase data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/pocketbase/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds. That one
archive is the whole install: the SQLite database with every account and record, the uploaded
files, the compose file, the superuser password and the live Caddy site block.

A backup on the same disk as the data is not a backup, so run this one from the user's machine:

```bash
mkdir -p ~/backups/pocketbase
scp vps:/srv/pocketbase/backups/*.tar.gz ~/backups/pocketbase/
```

To restore: `docker compose down`, `sudo rm -rf /srv/pocketbase/data`, untar the archive back
into /srv/pocketbase, `sudo chown -R 1000:1000 /srv/pocketbase/data`, then `docker compose up -d`.
The Caddy site block comes out of the same archive at `Caddyfile` and goes back into
/etc/caddy/Caddyfile by hand, because that file also holds every other site on the box. Tell the
user those five commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/pocketbase/pocketbase/releases, and the image
tags that follow them are at
https://github.com/muchobien/pocketbase-docker/pkgs/container/pocketbase. Take a backup first,
then edit the image line in /srv/pocketbase/compose.yml to the new tag and its digest:

```bash
cd /srv/pocketbase
docker compose pull
docker compose up -d
docker compose logs --tail 30 pocketbase
```

PocketBase runs its own database migrations on the way up, so watch that log until it settles,
then re-run the health check and the version check from step 7 before calling the update done.
Read the upstream release notes first: PocketBase is pre-1.0, and breaking changes land in minor
releases rather than waiting for a major one.

## 10. What will probably go wrong

The password will come back. I changed my superuser password inside the dashboard, restarted the
container a week later, and could not sign in with the new one. Nothing was broken: the image's
entrypoint runs `superuser upsert` from `PB_ADMIN_EMAIL` and
`PB_ADMIN_PASSWORD` on every single start, so the value in /srv/pocketbase/.env wins over
whatever the dashboard was told, every time the container comes up. Treat that file as the
source of truth. To change the password, edit .env and run `docker compose up -d --force-recreate`,
and if the user ever wants the dashboard to own it instead, delete the `PB_ADMIN_PASSWORD` line
from .env after they have set their own.

## 11. Out of scope

- Do not configure SMTP or S3 file storage. PocketBase's core loop needs neither, the superuser
  account this install creates needs no mail, and uploaded files belong in /pb_data, which is
  what step 8 backs up.
- Do not set `--encryptionEnv`. That flag encrypts the SMTP password and the S3 credentials
  stored in the database, and this install configures neither of them.
- Do not add mounts for /pb_public or /pb_hooks. Serving a frontend and writing JavaScript
  hooks are compose edits the user makes once they have something to put in them.
- Do not build an application on top of this. Collections and API rules are the user's work,
  and each is a decision this prompt has no business making.
