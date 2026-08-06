You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Apache CouchDB 3.5.2.1 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS, as the sync server the Obsidian Self-hosted LiveSync plugin
replicates into.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say this to the user before anything installs. The server half is the only half you can do. The
other half is a community plugin only they can install, inside Obsidian, on every device they
want synchronised, and Obsidian itself is closed-source software this prompt never touches.

CouchDB needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, say so and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/obsidian-livesync /srv/obsidian-livesync/backups
sudo install -d -m 755 -o 5984 -g 5984 /srv/obsidian-livesync/data
ls -la /srv/obsidian-livesync
```

Assert: `backups` is owned by the login user and `data` by uid `5984`. The CouchDB image creates
a `couchdb` account at uid 5984 and step 4 runs the container as it, so a data directory owned by
anyone else is a container that starts and cannot write a single document.

## 3. Secrets

Two secrets, both generated here. Do not print either, do not repeat them in your summary, and
do not put them in any log line. Hex rather than base64: one gets typed into a settings field on
a phone, and neither wants escaping.

```bash
umask 077
cat > /srv/obsidian-livesync/.env <<EOF
COUCHDB_USER=livesync
COUCHDB_PASSWORD=$(openssl rand -hex 32)
COUCHDB_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/obsidian-livesync/.env
umask 022
ls -l /srv/obsidian-livesync/.env
```

Assert: the file exists with mode `-rw-------`. `COUCHDB_PASSWORD` is the administrator password
and the credential the user types into the plugin on every device. `COUCHDB_SECRET` signs session
cookies; unset, CouchDB invents one at each boot inside the container, which this install does not
keep. CouchDB locks an address out after five failed authentications by default, and that is the
whole of the brute-force protection here.

## 4. compose.yml

```bash
cat > /srv/obsidian-livesync/compose.yml <<'EOF'
# Obsidian LiveSync · the deterministic fallback. Authored by caniselfhostit
# from the upstream documentation, not copied from a repository:
#   couchdb setup ...... https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md
#   settings applied ... https://github.com/vrtmrz/obsidian-livesync/blob/main/utils/couchdb/provision.ts
#   couchdb config ..... https://docs.couchdb.org/en/stable/config/couchdb.html
#   http and cors ...... https://docs.couchdb.org/en/stable/config/http.html
#   image entrypoint ... https://github.com/apache/couchdb-docker/blob/main/3.5.2.1/docker-entrypoint.sh
#
# One service: Apache CouchDB is the entire server side, and the Obsidian plugin
# replicates into it. The `configs` block holds the settings upstream's
# provisioning tool PUTs into /_node/_local/_config, written as a config file
# instead so nothing needs Deno or a script fetched at install time. Three of
# that tool's settings are left out because CouchDB 3.5 no longer acts on them.
# The mounted name sorts before the docker.ini the image writes, which stays the
# file CouchDB rewrites its own runtime changes into.
#
# `user: "5984:5984"` is upstream's own choice; it also keeps the entrypoint from
# chowning mounts at boot, so the data directory is chowned once, in step 2.
#
# Digest read from Docker Hub on 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  couchdb:
    image: couchdb:3.5.2.1@sha256:b80216f643e99d31df318c740dbc556ac08b56444030ed1d5e6d7b0d4e625213
    container_name: obsidian-livesync-couchdb
    restart: unless-stopped
    user: "5984:5984"
    env_file: /srv/obsidian-livesync/.env
    configs:
      - source: livesync-ini
        target: /opt/couchdb/etc/local.d/10-livesync.ini
    volumes:
      - /srv/obsidian-livesync/data:/opt/couchdb/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8120.
      - "127.0.0.1:8120:5984"

configs:
  livesync-ini:
    content: |
      [couchdb]
      ; Creates _users and _replicator at startup: the single-node equivalent
      ; of the /_cluster_setup call.
      single_node = true
      ; A note and its attachments are one document, and CouchDB defaults to
      ; 8000000 bytes.
      max_document_size = 50000000

      [chttpd]
      ; Nothing anonymous reaches anything but /_up, the health endpoint.
      require_valid_user = true
      require_valid_user_except_for_up = true
      ; The CouchDB default, restated: the limit above is reachable only
      ; while this one stays above it.
      max_http_request_size = 4294967296
      enable_cors = true

      [cors]
      credentials = true
      ; Obsidian desktop, then mobile under Capacitor. CouchDB rejects a
      ; wildcard origin while credentials are on.
      origins = app://obsidian.md,capacitor://localhost,http://localhost
EOF
cd /srv/obsidian-livesync && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. An error naming `content` means the compose plugin predates
v2.23.1, where inline config content arrived; upgrade it rather than rewriting the file.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-obsidian-livesync
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Obsidian LiveSync · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. CouchDB answers at
# the root of that hostname on purpose: upstream documents the subdirectory form
# as needing the proxy path rewritten. Obsidian on a phone refuses a certificate
# it cannot verify, so the automatic TLS here is the reason mobile sync works.

<DOMAIN> {
	# CouchDB sets its own CORS headers for the three Obsidian origins, so
	# nothing here adds or rewrites one: two Access-Control-Allow-Origin
	# headers on one response is a failure a browser reports as a bare CORS
	# error with no detail worth reading.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# No `encode`: replication holds a long-lived streaming response open and
	# moves chunks that are already encrypted.
	#
	# 8120 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8120
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-obsidian-livesync, reload, and report what it objected to.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. CouchDB's 5984 never reaches the host: compose publishes it as 127.0.0.1:8120, so 8120
stays closed too. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8120 or 5984.

## 7. Start and verify

```bash
cd /srv/obsidian-livesync
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/_up
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert all three and print what you received for each. The loop ends printing `200`. The next
line prints exactly `{"status":"ok"}`. The last prints `401`, the security assert here: the root
refuses an anonymous request while `/_up` does not. If any of the three misses, stop, run
`docker compose logs --tail 40 couchdb`, and name the likely cause. A permission error there
points at step 2; a `502` means the container exited; a certificate error means the A record was
too new; a `200` from the root means step 4's config was never applied, stop and re-check it. A
running container is not success.

Now create the database the plugin replicates into. The credential goes to curl on standard
input, so it never appears in the process list:

```bash
cd /srv/obsidian-livesync
set -a; . ./.env; set +a
printf 'user = "%s:%s"\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" | curl -sS -K - -X PUT https://<DOMAIN>/obsidiannotes
unset COUCHDB_USER COUCHDB_PASSWORD COUCHDB_SECRET
```

Assert: that prints `{"ok":true}`, or `{"error":"file_exists"` on a re-run, which is also fine.
Do not print that file or echo either variable.

STOP: tell the user to read their credentials with
`sudo grep -E 'COUCHDB_USER|COUCHDB_PASSWORD' /srv/obsidian-livesync/.env`, put both in their
password manager, and wait. Do not continue until they confirm.

STOP: tell the user to set up the first device, and wait. Do not continue until they confirm.
Give them these steps in this order. Back up the vault. Turn off Obsidian Sync, iCloud and every
other tool writing to it, because two synchronisers on one vault duplicate and corrupt notes. In
Obsidian: Settings, Community plugins, turn off Restricted mode, Browse, install and enable
`Self-hosted LiveSync`. Select the `Welcome to Self-hosted LiveSync` notice, choose
`I am setting this up for the first time`, confirm. On `Connection Method` choose
`Configure a remote manually`. On `End-to-End Encryption`, enable it and enter a passphrase they
wrote down first: it never reaches this server and nothing here can recover it. Choose `CouchDB`.
Enter the URL `https://<DOMAIN>`, the username and password from the previous step, and the
database name `obsidiannotes`. Select
`Create or connect to database and continue`, then `Restart and Initialise Server`, then
`I Understand, Overwrite Server`, then `Use this device's settings`. Wait for the progress
indicators to clear, then create one ordinary note.

Once they confirm, prove the note arrived:

```bash
cd /srv/obsidian-livesync
set -a; . ./.env; set +a
printf 'user = "%s:%s"\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" | curl -sS -K - https://<DOMAIN>/obsidiannotes
unset COUCHDB_USER COUCHDB_PASSWORD COUCHDB_SECRET
```

Assert: the response contains `"db_name":"obsidiannotes"` and a `doc_count` greater than 0. That
number is the product working end to end, a note that went from a text editor into a database on
the user's own server. If it is still 0, the plugin never connected: have them reopen its
settings and read the connection error there, which names the cause better than any log here.

## 8. First backup and restore

Take the backup now, while the only thing in that database is a test note.

```bash
cd /srv/obsidian-livesync
docker compose stop
sudo tar -czf /srv/obsidian-livesync/backups/obsidian-livesync-$(date +%F).tar.gz -C /srv/obsidian-livesync data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/obsidian-livesync/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container stops for the copy
because a tar of a database mid-write is not a backup. Downtime is about ten seconds.

A backup on the same disk as the data is not a backup either. Run this from the user's machine,
not the server:

```bash
mkdir -p ~/backups/obsidian-livesync
scp vps:/srv/obsidian-livesync/backups/*.tar.gz ~/backups/obsidian-livesync/
```

To restore: `docker compose down`, `sudo rm -rf /srv/obsidian-livesync/data`, untar the archive
into /srv/obsidian-livesync, `sudo chown -R 5984:5984 /srv/obsidian-livesync/data`, then
`docker compose up -d`. Tell the user the part that is easy to miss: with end-to-end encryption
on, every document in that archive is ciphertext and the passphrase is neither in it nor on this
server, so a restored database without it is a folder of noise. That passphrase belongs in the
same password manager entry as the CouchDB password, today.

## 9. Updating later

New images are listed at https://hub.docker.com/_/couchdb and the release notes at
https://docs.couchdb.org/en/stable/whatsnew/index.html. Take a backup first, then edit the image
line in /srv/obsidian-livesync/compose.yml to the new tag and its digest:

```bash
cd /srv/obsidian-livesync
docker compose pull
docker compose up -d
docker compose logs --tail 30 couchdb
```

Re-run the `/_up` check from step 7 before calling the update done. The plugin updates
separately, inside Obsidian, on each device, and nothing here pins its version.

## 10. What will probably go wrong

I opened https://<DOMAIN> in a browser expecting a dashboard, got a login box, typed the
credentials, and landed on a page of raw JSON that says `Welcome`. I spent several minutes
convinced Caddy was proxying the wrong thing. It was not: this install ships no web interface, so
a `401` before you log in and a small JSON object afterwards are both correct. The screen that
tells you this worked is inside Obsidian, and the number that proves it is `doc_count`.

## 11. Out of scope

- Do not run upstream's `couchdb-init.sh` or its Deno setup-URI generator. Every setting either
  one applies is already in the compose file, with its source recorded there.
- Do not enable Customisation Sync or Hidden File Sync. Upstream keeps optional features off
  until ordinary note sync is verified, and so does this install.
- Do not set `origins` to `*`. CouchDB refuses a wildcard origin while `credentials` is true,
  and the three listed are the ones Obsidian sends.
- Do not configure SMTP. CouchDB sends no mail, so there is nothing for it to do.
