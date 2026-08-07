You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Kavita 0.9.0.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Tell the user one thing before anything installs, because it decides whether they want this.
Kavita serves reading files that are already on this server: epub, pdf, cbz and cbr that they
copy in themselves. There is no catalog, no unlock and nothing to search that they have not put
on the disk. Books bought inside a store that wraps them in DRM, the Kindle and Kobo purchases
most people have the most of, stay locked to that store's own apps and will not open here.
Step 7 asks the user for the files, and only they know how many they have.

Kavita needs 1024 MB of RAM available and 5 GB free on /srv before any books. The image
publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve. Upstream reports installs running in as little as
256 MB; the 1024 MB here is the floor for the first library scan, which generates a cover image
for every book at once. The 5 GB covers the image, the database, the covers and the reading
cache, and the books sit on top of it.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kavita /srv/kavita/backups
sudo install -d -m 700 /srv/kavita/config
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/kavita/books
ls -la /srv/kavita
```

Assert: `ls -la` shows three entries, with `config` at mode `700` owned by root, and `backups`
and `books` owned by the login user. Upstream took the PUID and PGID handling out of its
container entrypoint, so Kavita runs as root and writes its database as root; `config` at 700
means no other account on this box can read the user table. `books` stays the login user's so
they can copy their library in during step 7.

## 3. Secrets

No secret is generated for this install, and there is no `.env` file. On first start Kavita
draws 256 random bytes for the key that signs user sessions and writes it into
config/appsettings.json itself, so there is nothing here for `openssl` to make. Step 8 backs up
that file along with the database.

The only credential this server will have is the admin account, created in a browser in step 7.
Say one thing to the user now: until that account exists, Kavita answers every visitor with its
`Register` form, and the first person to fill it in becomes the administrator of this server.
Step 7 is written to make that window short, and it is a hard stop for exactly that reason.

## 4. compose.yml

```bash
cat > /srv/kavita/compose.yml <<'EOF'
# Kavita · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ...... https://wiki.kavitareader.com/installation/docker/
#   dockerhub image ..... https://wiki.kavitareader.com/installation/docker/dockerhub/
#   server settings ..... https://wiki.kavitareader.com/guides/admin-settings/general/
#   libraries ........... https://wiki.kavitareader.com/guides/admin-settings/libraries/
#
# One service. The whole state is a SQLite database and a handful of folders
# under /kavita/config, a path upstream's own compose example marks as the one
# that must not be changed. The image already exposes 5000 and carries its own
# HEALTHCHECK against /api/health, so this file repeats neither. Upstream took
# the PUID and PGID handling out of its entrypoint, so the container runs as
# root and the config directory is root-owned on the host to match. The library
# is mounted read-only: Kavita reads filenames and in-file metadata and writes
# nothing back into it. Tag and digest read from Docker Hub on 2026-08-06; the
# image publishes linux/amd64, linux/arm64 and linux/arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  kavita:
    image: jvmilazz0/kavita:0.9.0.2@sha256:ca6af7a18d7124d014702983c2364e485294f808c1552e9555f2595b7cda7982
    container_name: kavita
    restart: unless-stopped
    environment:
      # The nightly library scan and the database backup task both run at
      # midnight in this zone, so it is the one setting worth being deliberate
      # about before the first scan.
      TZ: UTC
    volumes:
      - /srv/kavita/config:/kavita/config
      # Read-only. Nothing in this configuration writes to the library, and the
      # mount is what keeps a mis-click in the web UI from writing to it either.
      - /srv/kavita/books:/books:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8146.
      - "127.0.0.1:8146:5000"
EOF
cd /srv/kavita && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one database file.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-kavita
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Kavita · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://wiki.kavitareader.com/installation/remote-access/caddy-example/,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream's own
# Caddy example is two directives, an encode and a reverse_proxy. Kavita opens
# a websocket for scan progress and reading events; Caddy upgrades that
# connection with no extra directive, so the only additions here are headers.

<DOMAIN> {
	# The Angular bundle, the JSON API and epub text all compress well. Caddy's
	# default encode matcher covers text, JSON, JavaScript and SVG only, so
	# cover images and archive downloads pass through untouched.
	encode zstd gzip

	# No X-Frame-Options here on purpose: Kavita renders books in a same-origin
	# frame and decides its own frame-ancestors policy from the AllowIFraming
	# server setting, so a blanket DENY at the proxy would break the reader.
	# HSTS is here because every request to this host carries either a session
	# credential or an OPDS key in the URL.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8146 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8146
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-kavita, reload, and report what it objected to. Caddy asks for the
certificate on the first request to the hostname and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8146 stays closed because compose binds it to 127.0.0.1 and Caddy is the only thing
that speaks to it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule mentioning 8146.

## 7. Start and verify

```bash
cd /srv/kavita
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/api/health
curl -sS https://<DOMAIN>/api/admin/exists
```

Assert all three, and print what you received for each: the loop ends on `200`, the health
endpoint prints `Ok`, and the admin check prints `false`, which is upstream's way of saying no
administrator has been created yet. If the loop never reaches 200, stop, run
`docker compose logs --tail 40 kavita`, and name the likely earlier step: a container that exits
within seconds usually means step 2 left /srv/kavita/config unwritable, and a 502 from Caddy with
a running container means step 5. A running container is not success.

`false` also means the next person to load that URL becomes the administrator, so close that
window now, before the books arrive.

STOP: tell the user to open https://<DOMAIN> and create their account, and wait.
Do not continue until they confirm. The first screen reads `Register` above the line
`Complete the form to register an admin account`, with Username, Email and Password boxes. Tell
them two things upstream documents: the email does not have to be a real address, it is only how
a forgotten password is recovered and it is never sent anywhere, and the password has to be at
least 6 characters. Choose a real one; this server answers on the public internet.

```bash
curl -sS https://<DOMAIN>/api/admin/exists
```

Assert: `true`. That is the registration form closed for good, and it is the security assert in
this block. If it still prints `false`, the account was not created; do not go on.

STOP: tell the user to copy at least one book into /srv/kavita/books, from their own machine, not
the server, and wait. Do not continue until they confirm. Upstream requires one folder per series
and no files loose at the top of the library. This is the command, with their own path on the
left:

```bash
rsync -av --info=progress2 ~/Books/ vps:/srv/kavita/books/
```

Once they confirm, tell them the last step is theirs: Kavita scans no folder it has not been told
about. In the web UI, `Libraries`, `Add Library`, type `Book`, then pick `/books` in the folder
picker. Then read what the scanner did:

```bash
sleep 45
docker compose logs kavita | grep -F '[ScannerService] Found' | tail -1
```

Assert: a line containing `Found N Series that need processing`, with N greater than 0. Print it.
`Found 0 Series` means the files went in loose rather than one folder per series. No line at all
means the scan is still running, so wait 30 seconds and run it again.

## 8. First backup and restore

One archive: the database, the settings file holding the session key, the compose file and the
Caddy site block. The books are not in it, on purpose: they are the user's own library, and they
belong in whatever backup already protects the machine they copied them from. The cache and temp
folders are skipped because Kavita rebuilds both.

```bash
cd /srv/kavita
docker compose stop
sudo tar --exclude='config/cache' --exclude='config/cache-long' --exclude='config/temp' -czf /srv/kavita/backups/kavita-config-$(date +%F).tar.gz -C /srv/kavita config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/kavita/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds; the
container is stopped on purpose because a SQLite database copied mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/kavita
scp vps:/srv/kavita/backups/*.tar.gz ~/backups/kavita/
```

To restore: `docker compose down`, `sudo rm -rf /srv/kavita/config`, recreate it as in step 2,
untar the archive back into /srv/kavita, put the Caddy block back if that is what was lost, then
`docker compose up -d`. The accounts, the libraries, every bookmark and every page position live
in `config/kavita.db`, and the key that signs sessions is in `config/appsettings.json` beside it.
Tell the user those two files are the whole product: the books can be copied again from their own
machine; the page they stopped on cannot.

## 9. Updating later

New versions are listed at https://github.com/Kareadita/Kavita/releases. Take the backup first,
then edit the image line in /srv/kavita/compose.yml to the new tag and digest:

```bash
cd /srv/kavita
docker compose pull
docker compose up -d
docker compose logs --tail 30 kavita
```

Kavita migrates its own database on the way up. Watch that log until it settles, then re-run step
7's `/api/health` and `/api/admin/exists` checks before calling the update done.

## 10. What will probably go wrong

The scan will find nothing and the library will look broken. Mine did. I copied a folder of epub
files straight into /srv/kavita/books, added the library, and got a page that said the library
was empty, with no error in the UI and nothing alarming in the log. Kavita requires every series
to sit in its own folder and refuses to index files lying loose at the top of a library, which is
documented and is not something the interface tells you at the moment it matters. One folder per
book, then rescan from `Libraries` before you go looking at mount syntax.

## 11. Out of scope

- Do not enter a Kavita+ licence key. Kavita+ is a paid upstream subscription that adds metadata
  matching, reviews and scrobbling, and everything in this install works without it.
- Do not configure SMTP under `Admin`, `Email`. Kavita runs with no mail server, and an admin can
  reset another user's password from the user list without one.
- Do not configure OpenID Connect. It needs an identity provider registered elsewhere, and the
  admin account from step 7 is enough for one household.
- Do not change `Base URL` or `Port` in `Admin`, `General`. Both are set by the compose file here,
  and changing them in the UI leaves the container listening where nothing is looking.
