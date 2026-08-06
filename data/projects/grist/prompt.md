You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Grist 1.7.17 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` is the hostname whose A record already points at this server.
`<ADMIN_EMAIL>` is the address that becomes the administrator of this Grist installation and
also the username on the login box in front of it, so it is typed at every sign-in.

Grist needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64. Measure all four before doing anything else:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
caddy version
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. `caddy version` must print 2.8 or newer: the site block in step 5 uses
the `basic_auth` directive, which is what 2.8 renamed `basicauth` to. If it is older, stop and
tell the user to upgrade Caddy first.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/grist /srv/grist/backups
sudo install -d -m 700 /srv/grist/persist
ls -la /srv/grist
```

Assert: `ls -la` shows `backups` owned by the login user and `persist` at mode `700`. Leave
`persist` alone after this. The Grist image starts as root, chowns everything under /persist to
its own unprivileged user, and only then drops to that user, so an ownership fix here would be
undone on the next start. Everything the install holds lives under /srv/grist: documents are
`.grist` SQLite files in `persist/docs`, and the account table is `persist/home.sqlite3`.

## 3. Secrets

Two secrets, both generated here on the server. Print neither, repeat neither in your summary,
and put neither in a log line. The first replaces a session key whose default value is
published in the Grist source. The second is the password on the login box, and it is the only
thing standing between the public internet and this database.

```bash
umask 077
cat > /srv/grist/.env <<EOF
APP_HOME_URL=https://<DOMAIN>
GRIST_DEFAULT_EMAIL=<ADMIN_EMAIL>
GRIST_SESSION_SECRET=$(openssl rand -hex 32)
EOF
openssl rand -hex 24 > /srv/grist/browser-login
chmod 600 /srv/grist/.env /srv/grist/browser-login
umask 022
ls -l /srv/grist/.env /srv/grist/browser-login
```

Assert: both files exist with mode `-rw-------`. Hex rather than base64, because the login
value gets typed into a browser dialog and hex has nothing in it a keyboard layout can ruin.
The login password is deliberately not in `.env`: `.env` is what compose hands to the
container, and the credential the user types belongs nowhere near the application's
environment.

## 4. compose.yml

```bash
cat > /srv/grist/compose.yml <<'EOF'
# Grist · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   self-managed ....... https://support.getgrist.com/self-managed/
#   forwarded headers .. https://support.getgrist.com/install/forwarded-headers/
#   env var reference .. https://github.com/gristlabs/grist-core/blob/v1.7.17/README.md
#   upstream examples .. https://github.com/gristlabs/grist-core/tree/v1.7.17/docker-compose-examples
#
# One service. Documents are .grist SQLite files under /persist/docs and the
# account table is /persist/home.sqlite3, so there is no database process to run
# and nothing to dump. grist-core ships no username-and-password login of its
# own: the host Caddy checks the credential and passes the address it verified
# in X-Forwarded-User, which is what GRIST_FORWARD_AUTH_HEADER together with
# GRIST_IGNORE_SESSION tells Grist to trust on every request. Tag and digest
# were read from Docker Hub on 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  grist:
    image: gristlabs/grist-oss:1.7.17@sha256:b87ec1c3b62ca99f872611a9aa71ca33ee5fef9f40e0921e0beed878e5083473
    container_name: grist
    restart: unless-stopped
    environment:
      # These three come from /srv/grist/.env, which is mode 600. Compose reads
      # that file for substitution because it sits beside this one.
      APP_HOME_URL: ${APP_HOME_URL}
      GRIST_DEFAULT_EMAIL: ${GRIST_DEFAULT_EMAIL}
      GRIST_SESSION_SECRET: ${GRIST_SESSION_SECRET}
      # Trust this header, and only this header, for identity. Caddy overwrites
      # it on every proxied request, so a browser cannot put a name in it.
      GRIST_FORWARD_AUTH_HEADER: X-Forwarded-User
      GRIST_IGNORE_SESSION: "true"
      GRIST_FORCE_LOGIN: "true"
      # One team site, so no /o/<team> prefix turns up in any URL.
      GRIST_SINGLE_ORG: grist
      # Skip the first-run Quick setup gate, which would otherwise ask for a
      # boot key pasted out of the container log.
      GRIST_IN_SERVICE: "true"
      # Formulas are Python running on this server. On a public host they run
      # inside gvisor rather than directly.
      GRIST_SANDBOX_FLAVOR: gvisor
    volumes:
      # The image chowns everything under /persist to its own user on start,
      # then drops out of root, so this directory is left alone after step 2.
      - /srv/grist/persist:/persist
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8101.
      - "127.0.0.1:8101:8484"
EOF
cd /srv/grist && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Nothing is published beyond 127.0.0.1, and there is no
second service, because Grist keeps its documents and its account table in SQLite files inside
/persist.

## 5. Caddy and TLS

Two files. First the credential Caddy checks, which is a bcrypt hash of the password step 3
generated, written where the caddy user can read it and nowhere else:

```bash
umask 077
caddy hash-password < /srv/grist/browser-login > /srv/grist/grist-auth.hash
printf 'basic_auth {\n\t%s %s\n}\n' '<ADMIN_EMAIL>' "$(cat /srv/grist/grist-auth.hash)" > /srv/grist/grist-auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/grist/grist-auth.conf /etc/caddy/grist-auth.conf
rm -f /srv/grist/grist-auth.hash /srv/grist/grist-auth.conf
sudo grep -c basic_auth /etc/caddy/grist-auth.conf
```

Assert: that prints `1`. Reading the password from a file rather than passing it as an
argument keeps it out of the process list.

Then the site block, appended to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced
by the real hostname. Copy the file first: a syntax error here takes down every other site on
the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-grist
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Grist · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://support.getgrist.com/install/forwarded-headers/,
# https://support.getgrist.com/self-managed/ and
# https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. grist-core has no
# username-and-password login of its own, so this block is the login: Caddy
# checks the credential and then tells Grist which address it verified. Needs
# Caddy 2.8 or newer, which is where the directive is spelled basic_auth.

<DOMAIN> {
	# Grist ships a large JavaScript bundle, so compression is worth having.
	# WebSocket upgrades pass through untouched.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# The credential is not in this file, because this file is published. The
	# install writes /etc/caddy/grist-auth.conf with one basic_auth block: the
	# username, and a bcrypt hash of the password it generated. That file is
	# mode 640, owned by root and readable by the caddy group.
	import /etc/caddy/grist-auth.conf

	# 8101 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8101 {
		# Set, not add. Whatever a browser sent under this name is replaced by
		# the username basic_auth has verified, so the header cannot be
		# spoofed, which is the one thing this whole arrangement depends on.
		header_up X-Forwarded-User {http.auth.user.id}
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-grist, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it on its own; there is nothing to
schedule.

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
443/udp is HTTP/3. 8101 stays closed because it is bound to 127.0.0.1, and opening it would
route around the login box in step 5 entirely. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8101.

## 7. Start and verify

```bash
cd /srv/grist
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8101/status?db=1'); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS 'http://127.0.0.1:8101/status?db=1'
docker compose logs grist | grep -c 'gvisor check ok'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The
status response contains `is alive` and `db ok`. The log grep prints `1`, which is the
sandbox check upstream runs before the server starts. The last curl prints `401`: that is
Caddy refusing an unauthenticated request, and it is the security assert in this block,
because an unauthenticated Grist on a public hostname is an open database. If any of the four
misses, stop, run `docker compose logs --tail 40 grist`, and say which earlier step is the
likely cause. `gvisor check failed` in that log means this kernel will not run the sandbox and
the container exits on purpose; do not switch the sandbox off to get past it.

STOP: tell the user to open https://<DOMAIN>, sign in with `<ADMIN_EMAIL>` and the password
they read with `cat /srv/grist/browser-login`, put that password in their password manager,
then create one document and put a number in a cell. Wait. Do not continue until they confirm.
The first screen after signing in shows `Create empty document`. A running container is not
success, and neither is a login box: the document has to open, because that is the part that
uses the WebSocket the proxy has to carry.

## 8. First backup and restore

One archive. Stop the container first: the documents are SQLite files, and a copy taken
mid-write is not a backup.

```bash
cd /srv/grist
docker compose stop
sudo tar -czf /srv/grist/backups/grist-$(date +%F).tar.gz -C /srv/grist persist .env browser-login compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/grist/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds.
That archive contains both secrets, so it is as sensitive as the data. A backup on the same
disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/grist
scp vps:/srv/grist/backups/*.tar.gz ~/backups/grist/
```

To restore: `docker compose down`, `sudo rm -rf /srv/grist/persist`, untar the archive back
into /srv/grist, re-run the first fence of step 5 to rebuild /etc/caddy/grist-auth.conf from
the restored `browser-login`, `sudo systemctl reload caddy`,
then `docker compose up -d` and re-run the four asserts from step 7. Tell the user those are
the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/gristlabs/grist-core/releases. Take the backup
first, then edit the image line in /srv/grist/compose.yml to the new tag and its digest:

```bash
cd /srv/grist
docker compose pull
docker compose up -d
docker compose logs --tail 30 grist
```

Grist migrates its own SQLite files on the way up, so watch that log until it settles, then
re-run the four asserts from step 7 before calling the update done.

## 10. What will probably go wrong

The sandbox. I set `GRIST_SANDBOX_FLAVOR=gvisor` because formulas in Grist are Python running
on this server, and that turns a start-up check into a hard gate: upstream's own start script
runs `runsc` once before the server, prints `gvisor check ok` or `gvisor check failed`, and
exits on failure. A container stuck in that loop looks fine from the outside, which is the
part that cost me time: `docker compose ps` reports it as restarting rather than as broken,
and the reason is only ever in the log. It is not a Grist bug, and it is not something to
paper over by dropping the sandbox: the honest options are a VPS whose kernel hosts gvisor, or
a deliberate decision by the user that they will only open documents they wrote themselves.
Read the log before you conclude anything else is wrong.

## 11. Out of scope

- Do not configure OIDC, SAML or any identity provider. Caddy's login box is the whole auth
  story here, and a second one would leave two doors into the same install.
- Do not set `GRIST_BOOT_KEY` or open the Quick setup page. `GRIST_IN_SERVICE` skips that gate
  on purpose, and the address in `GRIST_DEFAULT_EMAIL` is already the installation admin.
- Do not configure SMTP, and do not set `ASSISTANT_API_KEY` or `OPENAI_API_KEY`. Grist runs
  without mail, and the formula assistant is a paid account somewhere else.
- Do not add Redis, PostgreSQL or MinIO. Those belong to the multi-worker setup upstream
  documents separately; this install is one container with SQLite files.
