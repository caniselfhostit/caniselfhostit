You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install ntfy 2.27.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say three things before anything is installed. One: this becomes a private push broker. The
default on ntfy.sh is open topics; this install sets auth-default-access to deny-all, so a
stranger who guesses a topic name cannot publish or subscribe. Two: users are created on the
CLI with `ntfy user add`, not in a browser signup wizard. Three: iOS instant delivery on a
self-hosted server needs `upstream-base-url` pointed at ntfy.sh's APNS bridge, which is a
third-party hop; without it, iOS notifications arrive delayed. This install leaves that off
until the user opts in.

ntfy needs 256 MB of RAM available and 2 GB free on /srv. The image publishes amd64 and arm64.
Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 256 MB or free disk is under 2 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
hostname that does not resolve, and NTFY_BASE_URL must be that same public URL.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ntfy /srv/ntfy/backups /srv/ntfy/cache /srv/ntfy/auth
ls -la /srv/ntfy
```

Assert: `ls -la` shows `backups`, `cache` and `auth`, owned by the login user. `cache` holds
the message cache SQLite file and attachments. `auth` holds the user database that deny-all
auth writes into. There is no empty `data/` directory in this install.

## 3. Secrets

One secret: the password for the admin account you will create in step 7. Generate it on the
server. Do not print it, do not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/ntfy/.env <<EOF
NTFY_BASE_URL=https://<DOMAIN>
NTFY_USERNAME=admin
NTFY_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/ntfy/.env
umask 022
ls -l /srv/ntfy/.env
```

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the
real hostname before running the block. Tell the user their username is `admin`, that they read
the password once with `sudo grep NTFY_PASSWORD /srv/ntfy/.env`, and that they should put it in
their password manager now. NTFY_BASE_URL is the public https URL phones and curl will use; a
wrong value breaks attachment links and the web UI's idea of where it lives.

## 4. compose.yml

```bash
cat > /srv/ntfy/compose.yml <<'EOF'
# ntfy · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.ntfy.sh/install/#docker
#   configuration ...... https://docs.ntfy.sh/config/
#   access control ..... https://docs.ntfy.sh/config/#access-control
#   behind a proxy ..... https://docs.ntfy.sh/config/#behind-a-proxy-tls-etc
#
# One container. Serve listens on port 80 inside the image. Auth is closed by
# default (deny-all): anonymous publish and subscribe are refused until a user
# is created with `ntfy user add`. Cache and auth live on separate mounts so a
# backup can name each path. NTFY_BASE_URL comes from .env and must be the
# public https URL (this file is the VPS path). behind-proxy is true because
# Caddy on the host terminates TLS. Digest read from Docker Hub on 2026-08-07;
# the manifest list covers amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  ntfy:
    image: binwiederhier/ntfy:v2.27.0@sha256:f2419f405127afa868f10985c1a41449e673477cee1eb19994339a5ae8b592e7
    container_name: ntfy
    restart: unless-stopped
    command: ["serve"]
    env_file: /srv/ntfy/.env
    environment:
      # Public URL phones and curl use. Set in .env as https://your.hostname.
      NTFY_BASE_URL: ${NTFY_BASE_URL}
      NTFY_CACHE_FILE: /var/cache/ntfy/cache.db
      NTFY_ATTACHMENT_CACHE_DIR: /var/cache/ntfy/attachments
      # Auth database is created on first start when this path is set.
      NTFY_AUTH_FILE: /var/lib/ntfy/user.db
      # Private instance: no anonymous read or write to any topic.
      NTFY_AUTH_DEFAULT_ACCESS: deny-all
      # Web UI login form; users themselves are still created on the CLI.
      NTFY_ENABLE_LOGIN: "true"
      # Rate limits must use X-Forwarded-For; without this every client is Caddy.
      NTFY_BEHIND_PROXY: "true"
    volumes:
      - /srv/ntfy/cache:/var/cache/ntfy
      - /srv/ntfy/auth:/var/lib/ntfy
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8200.
      - "127.0.0.1:8200:80"
EOF
cd /srv/ntfy && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, two bind mounts, no
database container. The auth database appears under `auth/` after first start.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-ntfy
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" <<'EOF' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
# ntfy · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.ntfy.sh/config/#nginxapachecaddy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project. Long-lived
# subscribe streams and WebSockets use Caddy's default reverse_proxy behaviour.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8200 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8200
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `DOMAIN_HOST` to the real hostname (not the literal `<DOMAIN>`) before the `sed` runs.
Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-ntfy, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8200 stays closed because compose binds it to 127.0.0.1. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8200.

## 7. Start and verify

```bash
cd /srv/ntfy
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/v1/health; echo
```

Assert: the loop ends printing `200` and the health body is healthy JSON. If the container
exits, run `docker compose logs --tail 40 ntfy` and stop.

Create the admin user non-interactively. Upstream accepts `NTFY_PASSWORD` in the environment
for scripts, so there is no interactive password prompt:

```bash
cd /srv/ntfy
NTFY_PASS=$(grep -E '^NTFY_PASSWORD=' .env | cut -d= -f2-)
NTFY_USER=$(grep -E '^NTFY_USERNAME=' .env | cut -d= -f2-)
docker compose exec -T -e NTFY_PASSWORD="$NTFY_PASS" ntfy ntfy user add --role=admin "$NTFY_USER"
docker compose exec -T ntfy ntfy user list
```

Assert: `user list` shows the admin user with role admin. Do not print `$NTFY_PASS`.

Close the instance and prove it. Anonymous publish must be denied; authenticated publish must
succeed:

```bash
unauth=$(curl -sS -o /dev/null -w '%{http_code}' -d 'probe' https://<DOMAIN>/caniselfhostit-probe)
echo "anonymous publish: $unauth"
auth=$(curl -sS -o /dev/null -w '%{http_code}' -u "${NTFY_USER}:${NTFY_PASS}" -d 'install ok' https://<DOMAIN>/caniselfhostit-probe)
echo "authenticated publish: $auth"
```

Assert: anonymous prints `403` and authenticated prints `200`. If anonymous is `200`, auth did
not load (check NTFY_AUTH_FILE and NTFY_AUTH_DEFAULT_ACCESS). If authenticated is not `200`, the
user was not created or the password in `.env` does not match. A running container is not
success; those two status codes are.

Publish handoff for the phone: tell the user to open the ntfy app (Android or iOS), add
https://<DOMAIN> as a custom server, sign in with username `admin` and the password from
`.env`, and subscribe to a topic they choose (for example `alerts`). Then publish once more
with curl using that topic name so the phone shows the message.

STOP: tell the user to confirm two things back to you: that they can log into the web UI at
https://<DOMAIN> with the admin account, and that an unauthenticated curl publish still returns
403. Do not continue until they confirm.

## 8. First backup and restore

One archive: the cache, the auth database, the compose file, `.env` (the admin password), and
the live Caddy site block. Take it now, before there is a month of topics to lose.

```bash
cd /srv/ntfy
docker compose stop
sudo tar -czf /srv/ntfy/backups/ntfy-$(date +%F).tar.gz -C /srv/ntfy cache auth compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/ntfy/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds; the
container is stopped on purpose so SQLite files are not copied mid-write.

A backup on the same disk as the data is not a backup. Run this one from the user's machine,
not the server:

```bash
mkdir -p ~/backups/ntfy
scp vps:/srv/ntfy/backups/*.tar.gz ~/backups/ntfy/
```

To restore: `docker compose down`, remove `cache` and `auth`, recreate those directories as in
step 2, untar the archive back into /srv/ntfy (which restores `.env` and compose.yml), put the
Caddy block back if that is what was lost, then `docker compose up -d`. Tell the user which
half matters: `auth/` is every account, and `.env` is the only place the generated password
lives. Losing either without the other is a lockout.

## 9. Updating later

New versions are listed at https://github.com/binwiederhier/ntfy/releases. The release tag and
the image tag are the same string, so release `v2.28.0` is image tag `v2.28.0`. Take a backup
first, then edit the image line in /srv/ntfy/compose.yml to the new tag and its digest:

```bash
cd /srv/ntfy
docker compose pull
docker compose up -d
docker compose logs --tail 30 ntfy
```

Watch that log until it settles, then re-run step 7's health check and the anonymous `403`
assert before calling the update done.

## 10. What will probably go wrong

You will publish a test message, the phone will stay silent, and you will assume ntfy is broken.
I did that on a self-hosted box with the iOS app. Android was fine; iOS was minutes late or
never instant. Instant delivery on iOS is not pure self-host: the app expects your server to
forward a wake-up through ntfy.sh's APNS path when you set `NTFY_UPSTREAM_BASE_URL=https://ntfy.sh`
in the compose environment and recreate the container. Without that line, iOS still works, but
it is delayed polling, not a real-time push. If you add it, say out loud that wake-ups now
touch ntfy.sh even though message content stays on your server. The other common miss is
forgetting basic auth on curl: after deny-all, a bare `curl -d hi https://host/topic` is
supposed to return 403. That is the product working, not a failure.

## 11. Out of scope

- Do not set `NTFY_UPSTREAM_BASE_URL` unless the user has heard the iOS APNS trade-off and asked
  for instant iOS delivery.
- Do not enable `NTFY_ENABLE_SIGNUP`. New accounts are created with `ntfy user add` on the
  server, not by strangers on the web UI.
- Do not open port 8200 in the firewall. Caddy is the only public listener.
- Do not switch the cache to PostgreSQL. SQLite in the `cache` mount is the choice here.
- Do not configure Firebase credentials for FCM. Self-hosted Android delivery uses the app's
  own path or UnifiedPush; this install does not run Google's push on your behalf.
