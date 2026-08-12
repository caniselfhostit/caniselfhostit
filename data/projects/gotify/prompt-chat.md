This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Gotify 3.0.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read these two before step 1. The admin account is seeded from a mode-600 `.env` file generated
on the server; there is no open registration race. There is no first-party iOS app: Android has
the official Gotify client, and iPhone users need a third-party client or another path such as
ntfy.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `256` MB available, at least `2` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/gotify /srv/gotify/backups /srv/gotify/data
ls -la /srv/gotify
```

You should see: `backups` and `data` under /srv/gotify, owned by your login user.

If you do not: re-run the `install -d` line. `data` is where Gotify writes its SQLite database
(apps, clients, messages, users). That directory plus `.env` is the whole product state.

## 3. Secrets

One secret: the password for the seeded admin account. Generate it on the server. Do not paste
it into this chat.

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

You should see: mode `-rw-------` and your own username twice.

If you do not: run `chmod 600 /srv/gotify/.env` and carry on. Your username is `admin`. Read the
password once with `sudo grep GOTIFY_DEFAULTUSER_PASS /srv/gotify/.env` and put it in your
password manager. That password lives only in `.env` until you change it in the UI. A backup
that omits `.env` is a lockout after restore. Do not paste that file into this chat window.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost. Run
`rm /srv/gotify/compose.yml` and paste again in one go. The pin is `3.0.0`, not the older
`2.9.1` line, because 3.0.0 is the current stable on Docker Hub as of the digest read date.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Set `DOMAIN_HOST` to
your real hostname before you paste. The first line takes a copy, because a syntax error here
takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-gotify /etc/caddy/Caddyfile`, reload,
and paste again. Caddy requests the certificate on the first request to the hostname and renews
it on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8206`.

If you do not: delete anything for `8206` with `sudo ufw delete allow 8206`. It is bound to
127.0.0.1 by the compose file, so a rule for it would cover traffic that cannot arrive.

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

You should see: the loop ending on a success code, then `401` from `/application` without
credentials, then JSON from `/current/user` that includes the admin name.

If you do not: run `docker compose logs --tail 40 gotify`. A 502 from Caddy with a running
container points at step 5. A 401 on `/current/user` means the password in `.env` does not match
what the database was seeded with (common if you recreated `.env` after the first start without
wiping `data/`).

Application-token handoff (the product's core loop):

1. Open https://<DOMAIN> in a private window, sign in as admin with the password from `.env`.
2. Create an Application, copy its token.
3. Publish a test message (replace `CHANGE_ME`; do not paste the real token into this chat):

```bash
curl -sS -X POST "https://<DOMAIN>/message?token=CHANGE_ME" -F "title=caniselfhostit" -F "message=hello from install"
```

You should see: JSON for a created message with an `id` field. On Android, install the official
Gotify app, add the server URL, create a client in the UI, and confirm the message arrives. On
iOS, there is no official app; use a third-party client or ntfy if you need an iPhone path.

Application tokens send messages. Client tokens receive them on the WebSocket stream. Mixing the
two is the usual 401 after a "working" install.

Open the UI, confirm the test message is listed, and confirm you still cannot call `/application`
without credentials. Do not continue until both are true.

## 8. First backup and restore

One archive: `data/`, compose.yml, `.env`, and the live Caddyfile. Omitting `.env` makes a
restore a lockout.

```bash
cd /srv/gotify
docker compose stop
sudo tar -czf /srv/gotify/backups/gotify-$(date +%F).tar.gz -C /srv/gotify data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/gotify/backups/
```

You should see: one non-empty file. Downtime is a few seconds; the container is stopped so
SQLite is not copied mid-write.

If you do not: an archive of about 100 bytes means `tar` found none of the paths. Run
`tar -tzf` on it and read what it actually contains. Confirm the listing includes `.env` and
`Caddyfile`.

A backup on the same disk as the data is not a backup. On your own machine:

```bash
mkdir -p ~/backups/gotify
scp vps:/srv/gotify/backups/*.tar.gz ~/backups/gotify/
```

To restore: `docker compose down`, remove `data`, recreate it, untar into /srv/gotify (restores
`.env` and compose.yml), restore the Caddy block if needed, then `docker compose up -d`. Both
`data/` and `.env` must come back together. After restore, re-check `/current/user` with the
password from the restored `.env` before you trust the install again.

## 9. Updating later

New versions are listed at https://github.com/gotify/server/releases. Take a backup first, then
edit the `image:` line in /srv/gotify/compose.yml to the new tag and its digest. This install
deliberately left the older `2.9.1` line; stay on the 3.x track unless a release note says
otherwise.

```bash
cd /srv/gotify
docker compose pull
docker compose up -d
docker compose logs --tail 30 gotify
```

You should see: the server starting, no restart loop. Re-run the unauthenticated `401` and
authenticated `/current/user` checks from step 7 before you call the update done.

## 10. What will probably go wrong

You will create an application, copy the token into a script, and still get 401 on publish. I
did that by putting the client token (for receiving) where the application token (for sending)
belongs. Read the label in the UI twice before pasting. The other miss is restoring `data/`
without `.env` after a disk wipe: the database still has the password hash, a newly generated
`.env` does not match, and login fails. Always restore `.env` with the data directory.

A third failure mode is assuming iOS works like Android. There is no first-party iOS app in the
Gotify family. If the user needs iPhone delivery as a first-class path, point them at ntfy on
this catalog rather than inventing an official client that does not exist.

A fourth is editing `.env` after first boot and expecting the admin password to change. The
seed variables create the user only when the database is empty. To rotate later, use the web UI
or the API while logged in; do not assume a new GOTIFY_DEFAULTUSER_PASS line rewrites the hash
in an existing `data/` directory.

## 11. Out of scope

- Do not install a third-party iOS client for the user. Name the gap and leave the choice.
- Do not open port 8206 in the firewall. Caddy is the only public listener.
- Do not put the admin password into compose.yml as a standing default string.
- Do not add a second database container. SQLite under `data/` is the choice here.
- Do not configure plugins on day one. The core loop is application token to phone.
- Do not leave default credentials from a tutorial in place. This install generates a fresh
  password on the server for a reason.
