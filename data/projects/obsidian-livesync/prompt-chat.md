This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Apache CouchDB 3.5.2.1 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. This install gives you the server half of Obsidian LiveSync and only
the server half. The other half is a community plugin you install by hand, inside Obsidian, on
every device you want synchronised, and Obsidian itself is closed-source software nothing here
touches. Step 7 is where you do that part, and it is the step that decides whether any of this
worked.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. This matters more here
than on most installs: Obsidian on a phone refuses a connection whose certificate it cannot
verify, so no certificate means no mobile sync at all. Under 1024 MB of RAM, add swap or resize
the box before going on.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/obsidian-livesync /srv/obsidian-livesync/backups
sudo install -d -m 755 -o 5984 -g 5984 /srv/obsidian-livesync/data
ls -la /srv/obsidian-livesync
```

You should see: `backups` owned by you, and `data` owned by `5984` twice.

If you do not: that uid is not arbitrary. The CouchDB image creates a `couchdb` account at uid
5984, and step 4 runs the container as that account, so a data directory owned by you is a
container that starts and then cannot write a single document. If `ls -la` prints a name instead
of the number, some other account on this box already holds 5984; that is fine, it is the same
uid.

## 3. Secrets

Two secrets, both generated here on the server, both written straight into a file only you can
read. Hex rather than base64: one of them gets typed into a settings field on a phone, and
neither wants escaping.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines in separate shells. Run `chmod 600 /srv/obsidian-livesync/.env` and carry on. If
the file already existed from an earlier attempt, this block has now replaced both values, which
is fine before the database exists and a nuisance afterwards: CouchDB takes the administrator
password from the environment when the container is created, so
`docker compose up -d --force-recreate` applies the new one, and every device still holding the
old one reports an authentication failure until you retype it there.

Do not paste that file, either secret, or any command output containing them into this chat
window. Read the two values you need with
`sudo grep -E 'COUCHDB_USER|COUCHDB_PASSWORD' /srv/obsidian-livesync/.env` in your own terminal
and put them in your password manager. `COUCHDB_SECRET` is not one you ever type: it signs
session cookies, and unset CouchDB would invent one at each boot inside the container, which this
install does not keep.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: an error naming `content` means your compose plugin predates v2.23.1, where inline
config content arrived. Upgrade the plugin rather than rewriting the file as a bind mount, since
a bind-mounted ini under /opt/couchdb is a permission problem you do not need.
`env file /srv/obsidian-livesync/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/obsidian-livesync/compose.yml` and paste again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-obsidian-livesync /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is forgetting to replace `<DOMAIN>`, which Caddy
reports as an unrecognised directive on the line holding the angle brackets.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8120` or `5984`.

If you do not: delete anything for `8120` or `5984` with `sudo ufw delete allow 8120`. CouchDB's
own port is 5984 inside the container and the compose file publishes it as 127.0.0.1:8120, so
neither number belongs in a firewall rule. 80/tcp answers the ACME challenge and redirects to
HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

```bash
cd /srv/obsidian-livesync
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/_up
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see, in order: the loop reaching `200`, then exactly `{"status":"ok"}`, then `401`.

If you do not: the `401` is the one worth understanding. It means CouchDB is up and refusing a
request that carries no credential, which is what this install configured, so seeing it is good
news. A `200` in its place would mean the server is open to the internet and you should stop and
re-check step 4. If the loop never reaches `200`, run `docker compose logs --tail 40 couchdb`; a
permission error there is step 2 done wrong, a `502` from Caddy means the container exited, and a
certificate error means the A record is too new and Caddy is still retrying.

Now create the database the plugin will replicate into. The credential is fed to curl on standard
input rather than on the command line, so it never shows up in `ps` or in your shell history:

```bash
cd /srv/obsidian-livesync
set -a; . ./.env; set +a
printf 'user = "%s:%s"\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" | curl -sS -K - -X PUT https://<DOMAIN>/obsidiannotes
unset COUCHDB_USER COUCHDB_PASSWORD COUCHDB_SECRET
```

You should see: `{"ok":true}`. On a second run you get `{"error":"file_exists"...}`, which is
also fine.

If you do not: `{"error":"unauthorized"...}` means the `.env` you sourced is not the one CouchDB
started with, so `docker compose up -d --force-recreate` and try again. A curl error about `-K`
means an old curl; the flag has been there for decades, so more likely the leading `printf` line
did not get pasted.

Now the half only you can do. In Obsidian, in this order:

1. Back up the vault, and turn off Obsidian Sync, iCloud and anything else writing to it. Two
   synchronisers on one vault duplicate and corrupt notes, and upstream says so twice.
2. Settings, Community plugins, turn off Restricted mode, Browse, install and enable
   `Self-hosted LiveSync`.
3. Select the `Welcome to Self-hosted LiveSync` notice, choose
   `I am setting this up for the first time`, and confirm.
4. On `Connection Method` choose `Configure a remote manually`.
5. On `End-to-End Encryption`, enable it and enter a passphrase you have written down first.
   That passphrase never reaches the server, and nothing on the server can recover it.
6. Choose `CouchDB`. Enter the URL `https://<DOMAIN>`, the username and password from step 3, and
   the database name `obsidiannotes`.
7. Select `Create or connect to database and continue`, then `Restart and Initialise Server`,
   then `I Understand, Overwrite Server`, then `Use this device's settings`.
8. Wait for the progress indicators to clear, then create one ordinary note.

Then prove the note arrived:

```bash
cd /srv/obsidian-livesync
set -a; . ./.env; set +a
printf 'user = "%s:%s"\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" | curl -sS -K - https://<DOMAIN>/obsidiannotes
unset COUCHDB_USER COUCHDB_PASSWORD COUCHDB_SECRET
```

You should see: a JSON object containing `"db_name":"obsidiannotes"` and a `doc_count` greater
than 0. That number is the whole product working end to end.

If you do not: a `doc_count` of 0 means the plugin never connected. Reopen its settings in
Obsidian and read the connection error there, which names the cause better than any log on the
server will. There is no first screen to look at in a browser: `https://<DOMAIN>/` asks for the
credentials and then shows a small JSON object saying `Welcome`, and that is all CouchDB has.

## 8. First backup and restore

Take the backup now, while the only thing in that database is a test note.

```bash
cd /srv/obsidian-livesync
docker compose stop
sudo tar -czf /srv/obsidian-livesync/backups/obsidian-livesync-$(date +%F).tar.gz -C /srv/obsidian-livesync data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/obsidian-livesync/backups/
```

You should see: one archive, a few hundred kilobytes on a fresh install. The service is down for
about ten seconds, because a tar of a database taken mid-write is not a backup.

If you do not: an archive of a few hundred bytes means `data` was empty, so CouchDB never
initialised. Start it, re-run the `/_up` check from step 7, and take the backup again.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/obsidian-livesync
scp vps:/srv/obsidian-livesync/backups/*.tar.gz ~/backups/obsidian-livesync/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/obsidian-livesync/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a test note:

```bash
cd /srv/obsidian-livesync
docker compose down
sudo rm -rf /srv/obsidian-livesync/data
sudo tar -xzf /srv/obsidian-livesync/backups/obsidian-livesync-$(date +%F).tar.gz -C /srv/obsidian-livesync data
sudo chown -R 5984:5984 /srv/obsidian-livesync/data
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/_up
```

You should see: `{"status":"ok"}`, and your test note still in Obsidian after the plugin
reconnects.

If you do not: the `chown` line is the one people skip, and skipping it gives a container that
starts and logs a permission error. Understand the stakes before you move on: with end-to-end
encryption on, every document in that archive is ciphertext, your passphrase is neither in it nor
on the server, and a restored database without the passphrase is a folder of noise. Put the
passphrase in the same password manager entry as the CouchDB password now, not later.

## 9. Updating later

New images are listed at https://hub.docker.com/_/couchdb and the release notes at
https://docs.couchdb.org/en/stable/whatsnew/index.html. Take a backup first, then edit the
`image:` line in /srv/obsidian-livesync/compose.yml to the new tag and its digest.

```bash
cd /srv/obsidian-livesync
docker compose pull
docker compose up -d
docker compose logs --tail 30 couchdb
```

You should see: the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/_up` check from step 7 before you call the update done. The plugin updates separately, inside
Obsidian, on each device, and nothing on the server pins its version.

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
