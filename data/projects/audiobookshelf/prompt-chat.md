This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Audiobookshelf 2.36.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. Audiobookshelf plays audio files that are already on that server. There
is no store, no credit, and nothing to search that you have not copied onto the disk yourself.
The `.aax` and `.aaxc` files Audible's own apps download are locked to Audible and will not play
here; what belongs in this library is audio you hold in an ordinary format you can copy, which in
upstream's own directory-structure examples means `.m4b`, `.m4a` and `.mp3`. Step 7 is where you
copy that library up, and how long it takes is a question about your upload speed.

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
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. The 5 G floor covers the
image, the database, the cover art and the transcoding cache only. Your audiobooks sit on top of
that number, so check the size of the folder on your own machine with `du -sh` and make sure the
server has room for it before you go any further.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/audiobookshelf /srv/audiobookshelf/backups
sudo install -d -m 700 /srv/audiobookshelf/config /srv/audiobookshelf/metadata
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/audiobookshelf/audiobooks /srv/audiobookshelf/podcasts
ls -la /srv/audiobookshelf
```

You should see: five entries, with `config` and `metadata` at mode `drwx------` owned by root,
`backups` at `drwxr-x---` owned by you, and `audiobooks` and `podcasts` at `drwxr-xr-x`.

If you do not: leave `config` and `metadata` owned by root on purpose. Upstream states that
Audiobookshelf does not read PUID or PGID, so the container runs as root and writes its database
as root; mode 700 there means no other account on this box can read your user table.
`audiobooks` stays yours so you can copy files into it in step 7, and `podcasts` is where
downloaded episodes land, which root writes to whoever owns the folder.

## 3. Secrets

There is nothing to generate here and there is no `.env` file. Upstream creates the key that
signs your sessions on first start and stores it in the database under /config, so no `openssl`
command runs in this install and there is no value for you to copy anywhere. Step 8 backs up
/config, which is where that key lives.

The only credential this server will have is the root account, and you create it in a browser in
step 7. Two things follow from that. First, between the container starting and you filling in
that form, the setup screen is open to whoever loads your hostname first, which is why step 7 is
written the way it is. Second, and this is the rule for this whole path: do not paste the
password you choose, any API key you generate later, or any command output containing either,
into this chat window. The other tab never sees those values; this one will hand them to a third
party unless you keep them out.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal; run `rm /srv/audiobookshelf/compose.yml` and paste again in one go. A complaint
about the `image` line usually means the digest was wrapped across two lines, and it has to be
one line. There is no `env_file` in this file and no `.env` to be missing, so a message about one
means you pasted a block from a different project.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-audiobookshelf /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you forgot to replace, and Caddy
names the line it choked on. Caddy asks for the certificate the first time somebody requests that
hostname and renews it on its own, so there is nothing to schedule afterwards.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8125`.

If you do not: delete anything for `8125` with `sudo ufw delete allow 8125`. That port is bound
to 127.0.0.1 by the compose file, so Caddy reaches it and nothing on the internet can. 80/tcp
redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp is
HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero
left this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it
back before you go any further.

## 7. Start and verify

```bash
cd /srv/audiobookshelf
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/status | grep -o '"isInit":[a-z]*'
```

You should see, in order: the loop reaching `200`, then `"isInit":false`.

If you do not: a loop that never reaches 200 wants `docker compose logs --tail 40
audiobookshelf`. A container that exits within seconds almost always cannot write
/srv/audiobookshelf/config, which sends you back to step 2. A `502` from Caddy while
`docker compose ps` shows the container running is step 5 instead. `/healthcheck` returns an
empty body with a 200, so the loop printing `200` is the whole of that check.

`"isInit":false` is upstream's way of saying no root user exists yet, and it also means the next
person to load that URL becomes the root user of your server. Close that window now, before you
go looking for your audiobooks.

Open https://<DOMAIN> in a browser. The first screen reads `Initial Server Setup` above
`Create Root User`, with Username, Password and Confirm Password boxes and the config and
metadata paths shown below them. Fill it in and submit. Set a real password: the form will accept
an empty one behind a confirmation dialog, and this server answers on the public internet. Then
come back here and run:

```bash
curl -sS https://<DOMAIN>/status | grep -o '"isInit":[a-z]*'
```

You should see: `"isInit":true`.

If you do not: the account was not created, and the setup screen is still open to whoever finds
it. Do not carry on until this prints `true`. This is the security check in this step, not a
formality.

Now the library. Run this one on your own machine, not the server, with your own path on the
left. Upstream expects one folder per book, `{Author}/{Book}` or `{Author}/{Series}/{Book}`:

```bash
rsync -av --info=progress2 ~/Audiobooks/ vps:/srv/audiobookshelf/audiobooks/
```

You should see: a file count and a transfer rate, then a summary line. One book is enough to
carry on; the rest can follow whenever you like.

Then the last step, which is yours: Audiobookshelf scans no folder it has not been told about. In
the web UI, open `Libraries`, then `Add Library`, media type `Books`, folder `/audiobooks`. Back
on the server:

```bash
cd /srv/audiobookshelf
sleep 30
docker compose logs audiobookshelf | grep -F 'Library scan' | tail -2
```

You should see: a line containing `Library scan` and `completed in`, ending in `N Added |
0 Updated | 0 Missing`, with N greater than 0.

If you do not: `0 Added` means the folder was added but the files under it are not laid out as
one folder per book, so check `ls /srv/audiobookshelf/audiobooks` against that pattern. Only a
`Starting` line means the scan is still running, so wait thirty seconds and run the command
again. A running container is not success. The two results that mean success are `"isInit":true`
and a scan line with something Added.

## 8. First backup and restore

One archive: the database, the compose file and the Caddy site block. Your audio is not in it, on
purpose. It is tens of gigabytes you already own, and it belongs in whatever backup protects your
own machine. Upstream's backup page says the same of its own built-in backups, which do not
include media files either.

```bash
cd /srv/audiobookshelf
docker compose stop
sudo tar -czf /srv/audiobookshelf/backups/audiobookshelf-config-$(date +%F).tar.gz -C /srv/audiobookshelf config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/audiobookshelf/backups/
```

You should see: one `.tar.gz`, a few hundred kilobytes on a fresh install. The service is offline
for about five seconds while the archive is made.

If you do not: an archive of a few hundred bytes means `tar` found nothing under `config`, which
means the container never wrote its database, and that sends you back to step 7. The container is
stopped on purpose: a SQLite database copied while it is being written is not a backup, and the
copy will look fine until the day you need it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/audiobookshelf
scp vps:/srv/audiobookshelf/backups/*.tar.gz ~/backups/audiobookshelf/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/audiobookshelf/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one account and a scan you can run
again:

```bash
cd /srv/audiobookshelf
docker compose down
sudo rm -rf /srv/audiobookshelf/config
sudo install -d -m 700 /srv/audiobookshelf/config
sudo tar -xzf /srv/audiobookshelf/backups/audiobookshelf-config-$(date +%F).tar.gz -C /srv/audiobookshelf config compose.yml
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/status | grep -o '"isInit":[a-z]*'
```

You should see: `"isInit":true`, which means your account survived a config directory that was
deleted and rebuilt from the archive.

If you do not: `"isInit":false` means the database did not come back and Audiobookshelf created
an empty one, so read the archive listing with `tar -tzf` before you trust it with anything. The
stakes are worth stating plainly: your accounts, your libraries and every listening position live
in `config/absdatabase.sqlite`. The audio you can copy up again from your own machine; the place
you stopped in each book you cannot.

One more thing the software will not tell you: the built-in scheduled backup is off until you
turn it on, in `Settings`, then `Backups`. The compose file has already pointed it at
/srv/audiobookshelf/backups.

## 9. Updating later

New versions are listed at https://github.com/advplyr/audiobookshelf/releases. Take the backup
first, then edit the `image:` line in /srv/audiobookshelf/compose.yml to the new tag and digest.

```bash
cd /srv/audiobookshelf
docker compose pull
docker compose up -d
docker compose logs --tail 30 audiobookshelf
```

You should see: migration lines, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/healthcheck` and `/status` checks from step 7 before you call the update done, and open the web
player and start one book as well, because a server that answers `/healthcheck` can still be
failing to stream if a migration stopped halfway.

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
  the root account you created in step 7 is enough for one household.
- Do not set `JWT_SECRET_KEY`. Upstream generates that value on first start and stores it in the
  database, which step 8 already backs up.
- Do not configure SMTP or the notification hooks. Audiobookshelf runs without either.
