This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Kavita 0.9.0.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Read this before step 1, because it decides whether you want the install. Kavita serves reading
files that are already on this server: epub, pdf, cbz and cbr that you copy in yourself. There is
no catalog, no unlock and nothing to search that you have not put on the disk. Books bought
inside a store that wraps them in DRM, the Kindle and Kobo purchases most people have the most
of, stay locked to that store's own apps and will not open here.

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
resolve, and failed attempts count against a rate limit you cannot see. On the memory line,
upstream reports installs running in as little as 256 MB, but the first library scan generates a
cover image for every book at once, and that is what the 1024 MB is for. The 5 GB covers the
image, the database, the covers and the reading cache; your books sit on top of it.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kavita /srv/kavita/backups
sudo install -d -m 700 /srv/kavita/config
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/kavita/books
ls -la /srv/kavita
```

You should see: three entries, `config` at mode `drwx------` owned by root, and `backups` and
`books` owned by you.

If you do not: leave `config` owned by root on purpose. Upstream took the PUID and PGID handling
out of its container entrypoint, so Kavita runs as root and writes its database as root, and mode
700 means no other account on this box can read the user table. `books` is yours so you can copy
your library in at step 7.

## 3. Secrets

Nothing to generate and no `.env` file. On first start Kavita draws 256 random bytes for the key
that signs user sessions and writes it into /srv/kavita/config/appsettings.json itself. The only
credential this server will have is the admin account you create in a browser at step 7.

Do not paste /srv/kavita/config/appsettings.json, or any part of it, into this chat window. The
same goes for the OPDS URL Kavita shows you in User Settings later: it carries your API key in
the address, so a link that looks harmless is a password. The Claude Code path never sees either
value; this path will hand them to a third party unless you keep them out of the window.

There is one thing to understand before you start the container at step 7. Until the admin
account exists, Kavita answers every visitor with its `Register` form, and the first person to
fill it in becomes the administrator of this server. Step 7 is ordered to make that window short.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/kavita/compose.yml` and paste again in one go. If it complains about
the image reference, the digest line was wrapped by your terminal; that line is long on purpose
and has to arrive intact.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-kavita /etc/caddy/Caddyfile`, reload, and
paste again. The most common cause is a `<DOMAIN>` you replaced in the site line but not in the
comment above it, which is harmless, or one you did not replace at all, which is not.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8146`.

If you do not: delete anything for 8146 with `sudo ufw delete allow 8146`. That port is bound to
127.0.0.1 by the compose file, so Caddy is the only thing that can reach it and a firewall rule
would only widen the install. 80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp
is the only way in, and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a
different problem: Prompt Zero left this firewall enabled, so something has turned it off since,
and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

```bash
cd /srv/kavita
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/api/health
curl -sS https://<DOMAIN>/api/admin/exists
```

You should see, in order: the loop reaching `200`, then `Ok`, then `false`.

If you do not: `false` is the good answer here, not a fault. It is upstream's way of saying no
administrator has been created yet, and it turns to `true` in a moment. If the loop never reaches
200, run `docker compose logs --tail 40 kavita`. A container that exits within seconds usually
means step 2 left /srv/kavita/config unwritable; a 502 from Caddy with a running container means
step 5. A running container is not success.

Now open https://<DOMAIN> in a browser and create your account. The first screen reads `Register`
above the line `Complete the form to register an admin account`, with Username, Email and
Password boxes. Upstream documents that the email does not have to be a real address, it is only
how a forgotten password is recovered and it is never sent anywhere, and that the password has to
be at least 6 characters. Choose a real one; this server answers on the public internet. Do this
before anything else, because until you do, whoever loads that hostname first becomes the
administrator.

```bash
curl -sS https://<DOMAIN>/api/admin/exists
```

You should see: `true`.

If you do not: the account was not created, and the registration form is still open to the
internet. Go back to the browser and finish it before continuing. This is the security check in
this step, not a formality.

Now copy your books in. Run this one on your own machine, not the server, with your own path on
the left. Upstream requires one folder per series and no files loose at the top of the library:

```bash
rsync -av --info=progress2 ~/Books/ vps:/srv/kavita/books/
```

You should see: a transfer summary, and `ls /srv/kavita/books` on the server listing your folders.

If you do not: `Permission denied` means you ran it on the server. The `vps:` prefix only means
something on your own machine, where the `vps` alias Prompt Zero created lives.

The last step is in the browser: Kavita scans no folder it has not been told about. In the web
UI, `Libraries`, `Add Library`, type `Book`, then pick `/books` in the folder picker. Then read
what the scanner did:

```bash
sleep 45
docker compose logs kavita | grep -F '[ScannerService] Found' | tail -1
```

You should see: a line containing `Found N Series that need processing`, with N greater than 0.

If you do not: `Found 0 Series` means the files went in loose rather than one folder per series;
fix the layout and rescan from `Libraries`. No line at all means the scan is still running, so
wait 30 seconds and run the command again. If the folder picker showed you nothing to pick, look
at the top level, `/`, for the mount; upstream's own libraries page tells docker users to check
there first.

## 8. First backup and restore

One archive: the database, the settings file holding the session key, the compose file and the
Caddy site block. Your books are not in it, on purpose: they are your own library and they belong
in whatever backup already protects the machine you copied them from. The cache and temp folders
are skipped because Kavita rebuilds both.

```bash
cd /srv/kavita
docker compose stop
sudo tar --exclude='config/cache' --exclude='config/cache-long' --exclude='config/temp' -czf /srv/kavita/backups/kavita-config-$(date +%F).tar.gz -C /srv/kavita config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/kavita/backups/
```

You should see: one file, a few megabytes on a fresh install with a small library. Kavita is
offline for about five seconds while it runs.

If you do not: an archive of a few hundred bytes means the `-C /srv/kavita` directory change did
not take and tar archived nothing. Run the command again as one line. Do not skip the
`docker compose stop`: a SQLite database copied mid-write is not a backup, it is a file that
restores into a broken library at the worst possible moment.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/kavita
scp vps:/srv/kavita/backups/*.tar.gz ~/backups/kavita/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/kavita/`.

If you do not: `No such file or directory` means the wildcard matched nothing, so check the
listing on the server again.

Now prove the restore, today, while the only thing at risk is a test library:

```bash
cd /srv/kavita
docker compose down
sudo rm -rf /srv/kavita/config
sudo install -d -m 700 /srv/kavita/config
sudo tar -xzf /srv/kavita/backups/kavita-config-$(date +%F).tar.gz -C /srv/kavita
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/admin/exists
```

You should see: `true`, and your own account still working when you reload the browser.

If you do not: `false` means the archive did not carry config/kavita.db, which means the tar in
this step ran against an empty config directory. Understand the stakes before you skip this: the
accounts, the libraries, every bookmark and every page position live in `config/kavita.db`, and
the key that signs sessions is in `config/appsettings.json` beside it. The books can be copied
again from your own machine; the page you stopped on cannot.

## 9. Updating later

New versions are listed at https://github.com/Kareadita/Kavita/releases. Take the backup first,
then edit the `image:` line in /srv/kavita/compose.yml to the new tag and its digest.

```bash
cd /srv/kavita
docker compose pull
docker compose up -d
docker compose logs --tail 30 kavita
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health and admin checks from step 7 before you call the update done, and open one book as well,
because a server that answers `Ok` on health can still be failing to open files if a migration
stopped halfway.

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
