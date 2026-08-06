You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Audiobookshelf 2.36.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Tell the user one thing before anything installs, because it decides whether they want this:
Audiobookshelf plays audio files that are already on this server. There is no store, no credit,
and nothing to search that they have not copied onto the disk themselves. The `.aax` and
`.aaxc` files Audible's own apps download are locked to Audible and will not play here. What
belongs here is audio in an ordinary format they can copy: `.m4b`, `.m4a` and `.mp3` are what
upstream's directory-structure page uses throughout. Step 7 asks them for it.

Audiobookshelf needs 1024 MB of RAM available and 5 GB free on /srv before any audio. The image
publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve. The 5 GB covers the image, the database, the cover
art and the transcoding cache. The audiobooks sit on top of it, and only the user knows how many
hours they have.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/audiobookshelf /srv/audiobookshelf/backups
sudo install -d -m 700 /srv/audiobookshelf/config /srv/audiobookshelf/metadata
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/audiobookshelf/audiobooks /srv/audiobookshelf/podcasts
ls -la /srv/audiobookshelf
```

Assert: `ls -la` shows five entries, with `config` and `metadata` at mode `700` owned by root,
`backups` owned by the login user, and `audiobooks` and `podcasts` at `755`. Upstream states that
Audiobookshelf does not read PUID or PGID, so the container runs as root and writes its database
as root; `config` at 700 means no other account on this box can read the user table.
`audiobooks` stays the login user's so they can copy files into it in step 7; `podcasts` is where
downloaded episodes land, and root writes there whoever owns it.

## 3. Secrets

No secret is generated for this install, and there is no `.env` file. Upstream generates the key
that signs sessions on first start and stores it in the database under /config, so there is
nothing here for `openssl` to make. Step 8 backs up /config, which is where that key lives.

The only credential this server has is the root account, created in a browser in step 7. Say one
thing to the user now: between the container starting and them filling in that form,
the setup screen is open to whoever loads the hostname first. Step 7 is written to make that
window short, and it is a hard stop for exactly that reason.

## 4. compose.yml

```bash
cat > /srv/audiobookshelf/compose.yml <<'EOF'
# Audiobookshelf · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   docker install ...... https://www.audiobookshelf.org/docs/documentation/install/docker
#   configuration ....... https://www.audiobookshelf.org/docs/documentation/install/configuration
#   backups ............. https://www.audiobookshelf.org/docs/documentation/server-management/backups
#   reverse proxy ....... https://www.audiobookshelf.org/docs/documentation/install/reverse-proxy/caddy
#
# One service. The whole state is a SQLite database under /config, which
# upstream says must be local disk and never a network mount. The image already
# sets PORT=80, CONFIG_PATH=/config and METADATA_PATH=/metadata, so this file
# does not repeat them. Upstream states that Audiobookshelf does not read PUID
# or PGID, so the container runs as root and the two state directories are
# root-owned on the host to match. The audiobook library is mounted read-only,
# because nothing in this configuration writes to it. Tag and digest read from
# ghcr.io on 2026-08-06; the image publishes linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:2.36.0@sha256:180acad33d69c99ed208676465d8edcb268fa46967735579a7810859885b1a8e
    container_name: audiobookshelf
    restart: unless-stopped
    environment:
      TZ: UTC
      # Backups belong beside the other backups on this box rather than inside
      # the metadata cache. The scheduler that fills this folder ships off and
      # stays off until it is turned on in the web UI.
      BACKUP_PATH: /backups
    volumes:
      - /srv/audiobookshelf/config:/config
      - /srv/audiobookshelf/metadata:/metadata
      - /srv/audiobookshelf/backups:/backups
      # Read-only. Nothing in this configuration writes to the library, and the
      # mount is what keeps a mis-click in the UI from writing to it either.
      - /srv/audiobookshelf/audiobooks:/audiobooks:ro
      # Read-write, because podcast episodes are downloaded into this folder.
      - /srv/audiobookshelf/podcasts:/podcasts
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8125.
      - "127.0.0.1:8125:80"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd /srv/audiobookshelf && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one database file.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-audiobookshelf
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Audiobookshelf · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.audiobookshelf.org/docs/documentation/install/reverse-proxy/caddy,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream's own
# Caddy page is two directives, an encode and a reverse_proxy, and notes that
# the web player needs a websocket connection. Caddy upgrades that connection
# with no extra directive, so the only additions here are the headers.

<DOMAIN> {
	# The player bundle and its JSON API compress well. Audio does not, and
	# Caddy's default encode matcher covers text, JSON, JavaScript and SVG
	# only, so the audio streams pass through untouched.
	encode zstd gzip

	# Audiobookshelf already sets Content-Security-Policy frame-ancestors
	# 'self' and Referrer-Policy no-referrer on every response, so this block
	# does not repeat either. HSTS is here because every request to this host
	# carries a session cookie or a bearer token.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		-Server
	}

	# 8125 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. The websocket the
	# player opens rides this same proxy.
	reverse_proxy 127.0.0.1:8125
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-audiobookshelf, reload, and report what it objected to. Caddy asks
for the certificate on the first request to the hostname and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8125 stays closed because compose binds it to 127.0.0.1 and Caddy is the only thing
that speaks to it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule mentioning 8125.

## 7. Start and verify

```bash
cd /srv/audiobookshelf
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/status | grep -o '"isInit":[a-z]*'
```

Assert both, and print what you received for each: the loop ends printing `200`, and the status
line prints `"isInit":false`, which upstream computes as "no root user exists yet". If the loop
never reaches 200, stop, run `docker compose logs --tail 40 audiobookshelf`, and name the
likely earlier step: a container that exits within seconds usually means step 2 left
/srv/audiobookshelf/config unwritable, and a 502 from Caddy with a running container means step
5. A running container is not success.

`"isInit":false` also means the next person to load that URL becomes the root user of this
server, so close that window now rather than after the audio arrives.

STOP: tell the user to open https://<DOMAIN> and create their account, and wait. Do not continue
until they confirm. The first screen reads `Initial Server Setup` above `Create Root User`, with
Username, Password and Confirm Password boxes and the config and metadata paths shown below them.
Tell them to set a real password: the form will accept an empty one behind a confirmation dialog,
and this server answers on the public internet.

```bash
curl -sS https://<DOMAIN>/status | grep -o '"isInit":[a-z]*'
```

Assert: `"isInit":true`. That is the setup screen closed for good, and it is the security assert
in this block. If it still prints `false`, the account was not created; do not go on.

STOP: tell the user to copy at least one audiobook into /srv/audiobookshelf/audiobooks, from
their own machine, not the server, and wait. Do not continue until they confirm. Upstream expects
one folder per book, `{Author}/{Book}` or `{Author}/{Series}/{Book}`. This is the command, with
their own path on the left:

```bash
rsync -av --info=progress2 ~/Audiobooks/ vps:/srv/audiobookshelf/audiobooks/
```

Once they confirm, tell them the last step is theirs: Audiobookshelf scans no folder it has not
been told about. In the web UI, `Libraries`, `Add Library`, media type `Books`, folder
`/audiobooks`. Then read what the scanner did:

```bash
sleep 30
docker compose logs audiobookshelf | grep -F 'Library scan' | tail -2
```

Assert: a line containing `Library scan` and `completed in`, ending in `N Added | 0 Updated |
0 Missing`, with N greater than 0. Print it. `0 Added` means the folder was added but the files under it are
not laid out as one folder per book. A lone `Starting` line means the scan is still running, so
wait 30 seconds and run it again.

## 8. First backup and restore

One archive: the database, the compose file and the Caddy site block. The audio is not in it, on
purpose: it is the user's own library, tens of gigabytes, and it belongs in whatever backup
already protects the machine they copied it from. Upstream's backup page says the same of its
built-in backups, which exclude media files too.

```bash
cd /srv/audiobookshelf
docker compose stop
sudo tar -czf /srv/audiobookshelf/backups/audiobookshelf-config-$(date +%F).tar.gz -C /srv/audiobookshelf config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/audiobookshelf/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds; the
container is stopped on purpose because a SQLite database copied mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/audiobookshelf
scp vps:/srv/audiobookshelf/backups/*.tar.gz ~/backups/audiobookshelf/
```

To restore: `docker compose down`, `sudo rm -rf /srv/audiobookshelf/config`, recreate it as in
step 2, untar the archive back into /srv/audiobookshelf, put the Caddy block back if that is what
was lost, then `docker compose up -d`. The accounts, the libraries and every listening position
are in `config/absdatabase.sqlite`. Tell the user that file is the whole product: the audio can be
copied again from their own machine; the place they stopped in each book cannot.

One more thing the software will not say: the built-in scheduled backup is off until they turn it
on, in `Settings`, then `Backups`. Compose has already pointed it at /srv/audiobookshelf/backups.

## 9. Updating later

New versions are listed at https://github.com/advplyr/audiobookshelf/releases. Take the backup
first, then edit the image line in /srv/audiobookshelf/compose.yml to the new tag and digest:

```bash
cd /srv/audiobookshelf
docker compose pull
docker compose up -d
docker compose logs --tail 30 audiobookshelf
```

Audiobookshelf migrates its own database on the way up. Watch that log until it settles, then
re-run step 7's `/healthcheck` and `/status` checks before calling the update done.

## 10. What will probably go wrong

The library will look empty and the install will look broken. Mine did. Copying files into
/srv/audiobookshelf/audiobooks does nothing on its own: the folder is mounted, but no library
points at it until somebody adds one in the web UI, and until then the home screen is an empty
state with no error anywhere and nothing in the log. I spent ten minutes checking mount syntax
before I opened `Libraries` and found there were none. Add the library first, then judge the
scan.

## 11. Out of scope

- Do not mount the audiobook library read-write to make the upload button work. Uploading,
  embedding metadata into the audio files and storing metadata beside the items all write into
  the library, and this install keeps it read-only on purpose.
- Do not configure OIDC single sign-on. It needs an identity provider registered elsewhere, and
  the root account created in step 7 is enough for one household.
- Do not set `JWT_SECRET_KEY`. Upstream generates that value on first start and stores it in the
  database, which step 8 already backs up.
- Do not configure SMTP or the notification hooks. Audiobookshelf runs without either.
