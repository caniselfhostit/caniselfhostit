You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Gotify 3.0.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things before anything is installed. One: the admin account is seeded from environment
variables into a mode-600 `.env` file; there is no open registration race. Two: there is no
first-party iOS app. Android has the official Gotify client; iPhone users need a third-party
client or another path (ntfy is the usual neighbour on this catalog).

Gotify needs 256 MB of RAM available and 2 GB free on /srv. The image publishes amd64 and arm64.
Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 256 MB or free disk is under 2 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
hostname that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/gotify /srv/gotify/backups /srv/gotify/data
ls -la /srv/gotify
```

Assert: `ls -la` shows `backups` and `data` owned by the login user. `data` is where Gotify
writes its SQLite database (apps, clients, messages, users). That directory is the whole product
state besides `.env`.

## 3. Secrets

One secret: the password for the seeded admin account. Generate it on the server. Do not print
it, do not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/gotify/.env <<EOF
GOTIFY_DEFAULTUSER_NAME=admin
GOTIFY_DEFAULTUSER_PASS=$(openssl rand -base64 24)
EOF
chmod 600 /srv/gotify/.env
umask 022
ls -l /srv/gotify/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user their username is `admin`, that
they read the password once with `sudo grep GOTIFY_DEFAULTUSER_PASS /srv/gotify/.env`, and that
they should put it in their password manager now. That password lives only in `.env` until they
change it in the UI; a backup that omits `.env` is a lockout after restore.

## 4. compose.yml

```bash
cat > /srv/gotify/compose.yml <<'EOF'
# Gotify · Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install ............ https://gotify.net/docs/install
#   configuration ...... https://gotify.net/docs/config
#   push messages ...... https://gotify.net/docs/pushmsg
#
# One container. Admin seed credentials come from env_file (generated on the
# server as GOTIFY_DEFAULTUSER_NAME and GOTIFY_DEFAULTUSER_PASS). State lives
# under /app/data (SQLite). Digest for server:3.0.0 read from Docker Hub on
# 2026-08-07; the manifest list covers amd64 and arm64. Pinned above the older
# 2.9.1 line on purpose: 3.0.0 is the current stable release.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  gotify:
    image: gotify/server:3.0.0@sha256:d75e89e0e28389c00c2556afe01282a37ee9756b0285799aa25214243aebd5e5
    container_name: gotify
    restart: unless-stopped
    env_file: /srv/gotify/.env
    volumes:
      - /srv/gotify/data:/app/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8206.
      - "127.0.0.1:8206:80"
EOF
cd /srv/gotify && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one data mount. Version
decision: this pin is `3.0.0`, not the older `2.9.1` line, because 3.0.0 is the current stable
on Docker Hub as of the digest read date.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-gotify
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" <<'EOF' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
# Gotify · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://gotify.net/docs/config#reverse-proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project. WebSocket
# streams use Caddy's default reverse_proxy behaviour.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8206 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8206
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `DOMAIN_HOST` to the real hostname before the `sed` runs. Assert: `caddy validate` exits 0
and the reload exits 0. If validate fails, restore /etc/caddy/Caddyfile.before-gotify, reload,
and report what it objected to.

## 6. Firewall

Two ports open, both Caddy's:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

8206 stays closed because compose binds it to 127.0.0.1. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8206.

## 7. Start and verify

```bash
cd /srv/gotify
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; case "$code" in 200|301|302) break ;; esac; sleep 5; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/application
ADMIN_PASS=$(grep -E '^GOTIFY_DEFAULTUSER_PASS=' .env | cut -d= -f2-)
ADMIN_NAME=$(grep -E '^GOTIFY_DEFAULTUSER_NAME=' .env | cut -d= -f2-)
curl -sS -u "${ADMIN_NAME}:${ADMIN_PASS}" https://<DOMAIN>/current/user; echo
```

Assert all three, and print what you received for each (except the password). The loop ends on
a success code. `GET /application` without credentials prints `401`. The authenticated
`/current/user` call returns JSON that includes the admin name. If any miss, stop, run
`docker compose logs --tail 40 gotify`, and name the likely step. A running container is not
success.

Application-token handoff (the product's core loop). After the user can log into the web UI:

1. Tell them to open https://<DOMAIN>, sign in as admin with the password from `.env`, create an
   Application, and copy its token.
2. Publish a test message (they paste the token; you do not store it in logs):

```bash
# Replace CHANGE_ME with the token from the UI; do not commit it anywhere.
curl -sS -X POST "https://<DOMAIN>/message?token=CHANGE_ME" -F "title=caniselfhostit" -F "message=hello from install"
```

Assert: the POST returns JSON for a created message (an `id` field). On Android, install the
official Gotify app, add the server URL, create a client in the UI, and confirm the message
arrives. On iOS, say plainly that there is no official app and stop recommending one.

STOP: tell the user to confirm they signed in, created an application, and saw the test
message either in the web UI or on Android. Do not continue until they confirm.

## 8. First backup and restore

One archive: the data directory, compose.yml, `.env` (the admin password), and the live Caddy
site block. Omitting `.env` makes a restore a lockout.

```bash
cd /srv/gotify
docker compose stop
sudo tar -czf /srv/gotify/backups/gotify-$(date +%F).tar.gz -C /srv/gotify data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/gotify/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds; the
container is stopped on purpose so SQLite is not copied mid-write.

A backup on the same disk as the data is not a backup. From the user's machine:

```bash
mkdir -p ~/backups/gotify
scp vps:/srv/gotify/backups/*.tar.gz ~/backups/gotify/
```

To restore: `docker compose down`, remove `data`, recreate it as in step 2, untar into
/srv/gotify (restores `.env` and compose.yml), put the Caddy block back if needed, then
`docker compose up -d`. Tell the user: `data/` is apps, clients and message history; `.env` is
the seeded admin password. Both must come back together.

## 9. Updating later

New versions are listed at https://github.com/gotify/server/releases. Take a backup first, then
edit the image line in /srv/gotify/compose.yml to the new tag and its digest. This install
deliberately left the older `2.9.1` line; stay on the 3.x track unless a release note says
otherwise.

```bash
cd /srv/gotify
docker compose pull
docker compose up -d
docker compose logs --tail 30 gotify
```

Watch that log until it settles, then re-run step 7's unauthenticated `401` and authenticated
`/current/user` checks before calling the update done.

## 10. What will probably go wrong

You will create an application, copy the token into a script, and still get 401 on publish. I
did that by putting the client token (for receiving) where the application token (for sending)
belongs. Gotify has two token kinds: application tokens go on `POST /message`, client tokens
open the WebSocket stream the Android app uses. Read the label in the UI twice before pasting.
The other miss is restoring `data/` without `.env` after a disk wipe: the database still has
the password hash, your new generated `.env` does not match, and login fails. Always restore
`.env` with the data directory.

## 11. Out of scope

- Do not install a third-party iOS client for the user. Name the gap and leave the choice.
- Do not open port 8206 in the firewall. Caddy is the only public listener.
- Do not put the admin password into compose.yml as a standing default string.
- Do not add a second database container. SQLite under `data/` is the choice here.
- Do not configure plugins on day one. The core loop is application token to phone.
