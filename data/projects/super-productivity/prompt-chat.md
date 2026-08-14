This path is slower: you paste every command yourself, and there is nobody watching the output but
you. If you can run Claude Code, use the other tab.

You are installing Super Productivity v18.19.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless
a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read these three before step 1, because they decide whether you want this install rather than how it
goes. The server will hold none of your tasks: the image is nginx serving a built web app as static
files, and upstream states that data is stored in the browser and the container provides no
persistent storage, so everything you type lives in the browser profile that loaded the page and
clearing site data for the hostname deletes it. There is no account and no login, because there is
no server-side store to have an account in, so the page answers everybody and a stranger who loads
it gets their own empty list rather than a view of yours. And cross-device sync is not one setting
away; step 8 has the two measured reasons this install leaves it off.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `256` MB available, at least `2` G free, `amd64` or `arm64`, and your
server's IP address.

If you do not: with under 256 MB or under 2 GB, stop and resize the box rather than installing and
hoping. If `dig +short` prints nothing, add the A record and wait a minute. Caddy cannot issue a
certificate for a name that does not resolve, and the certificate is load-bearing here, because
browsers grant a service worker and WebCrypto only on a secure origin. `df -BG` is a GNU coreutils
flag; on a box that is neither Debian nor Ubuntu, run `df -h /srv` and read the figure yourself.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/super-productivity /srv/super-productivity/backups
ls -la /srv/super-productivity
```

You should see: `backups` under /srv/super-productivity, owned by you.

If you do not: check that you ran this as your login user and not as root. There is deliberately no
`data/` directory here; the compose file in step 4 mounts nothing, so a `data/` would be an empty
archive pretending to be a safety net.

## 3. Secrets

Nothing to generate. There is no `.env` file, no default credential, no registration form and no
administration screen, so there is no first claimant and no claim race, and no step here to run.

Two things to know instead. The image's entrypoint can write
`assets/sync-config-default-override.json` from `WEBDAV_BASE_URL`, `WEBDAV_USERNAME`,
`WEBDAV_SYNC_FOLDER_PATH`, `SYNC_INTERVAL`, `IS_COMPRESSION_ENABLED` and `IS_ENCRYPTION_ENABLED`,
and that file is served to everyone who loads your URL. Step 4 sets none of them, and step 7 prints
the file as proof. Upstream provides no variable for a password in any case: a sync password is
typed into the browser and kept by the browser, never by this server.

The second is a chat-window rule. Do not paste your sync password, any app password from another
service, or the contents of the JSON file step 8 exports into this chat. That export is plaintext
and it can carry the API credentials of any issue provider you connect later. The other tab's agent
never sees those values; this one will, if you paste them.

## 4. compose.yml

```bash
cat > /srv/super-productivity/compose.yml <<'EOF'
# Super Productivity · the deterministic fallback. Authored by caniselfhostit
# from the upstream documentation, not copied from a repository:
#   run with docker .... https://github.com/super-productivity/super-productivity/blob/v18.19.0/docs/wiki/2.13-Run-with-Docker.md
#   entrypoint ......... https://github.com/super-productivity/super-productivity/blob/v18.19.0/docker-entrypoint.sh
#   nginx template ..... https://github.com/super-productivity/super-productivity/blob/v18.19.0/nginx/default.conf.template
#
# One service: nginx serving the built web app as static files. No database, no
# volume, no state on this box, because upstream states that data is stored in
# the browser and the container provides no persistent storage. No env_file and
# no environment block, on purpose: the entrypoint would write a world-readable
# sync-config-default-override.json under assets/ from the WEBDAV_ and
# SYNC_INTERVAL variables, and with WEBDAV_BACKEND unset the image's /webdav/
# proxy answers 404. Block 8 of the prompts says why. No
# `user:` line: nginx binds 80 in the container and the image names no
# unprivileged user; the healthcheck uses the curl the image installs.
#
# Image identity, checked 2026-08-14: the wiki's docker run line names a Docker
# Hub repository that does not resolve; the one that does, and that upstream's
# own compose file names, is johannesjo/super-productivity. Tag v18.19.0 was
# released 2026-08-07; digest read from registry-1.docker.io on 2026-08-14, an
# OCI index covering linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  super-productivity:
    image: johannesjo/super-productivity:v18.19.0@sha256:ae91fe9ac19561e0f3669d15a2c4c71d7a75c43a29eb44ddc010ae50d1f63c82
    container_name: super-productivity
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8199.
      - "127.0.0.1:8199:80"
EOF
cd /srv/super-productivity && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK`.

If you do not: `docker compose config` prints the line it objected to, and it is almost always an
indentation change made while pasting. Re-paste the block in one go rather than editing it in place.
Do not add a Caddy service here; Caddy already runs under systemd on this box.

## 5. Caddy and TLS

```bash
cat > /srv/super-productivity/Caddyfile <<'EOF'
# Super Productivity · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. What is served here is
# public by design: there are no accounts, because there is no server-side store
# to have an account in, and a stranger loading this URL gets an empty task list
# in their own browser rather than a view of yours. Caddy basic_auth is the
# opt-in. TLS is not decoration here: the app registers a service worker and
# uses WebCrypto, and browsers grant neither on a plain-http hostname.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8199 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8199
}
EOF
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-super-productivity
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" /srv/super-productivity/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `DOMAIN_HOST` to your real hostname before the `sed` line runs.

You should see: `Valid configuration` from `caddy validate`, and no output from the reload.

If you do not: restore the copy from a moment ago with
`sudo cp /etc/caddy/Caddyfile.before-super-productivity /etc/caddy/Caddyfile`, reload, and read what
validate objected to. The usual cause is `DOMAIN_HOST` still being literal, which writes the angle
brackets into the site name.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, with 80/tcp, 443/tcp and 443/udp allowed and nothing mentioning
8199.

If you do not: 80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3.
8199 must never appear; compose binds it to 127.0.0.1, so opening it in the firewall would publish
the container past the reverse proxy. If a previous run added it, remove it with
`sudo ufw delete allow 8199`.

## 7. Start and verify

```bash
cd /srv/super-productivity
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sSL https://<DOMAIN>/ | grep -c '<title>Super Productivity</title>'
curl -sS https://<DOMAIN>/assets/sync-config-default-override.json; echo
curl -sS https://<DOMAIN>/assets/sync-config-default-override.json | grep -ciE 'password|userName|baseUrl|syncFolderPath'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/webdav/
docker compose ps
```

You should see: the loop ending on `200`; a title count of `1`; a served sync-defaults file
containing a single `_comment` key and nothing else; a `0` from the grep after it; and `404` from
the /webdav/ line. That `0` is the security check on this install: it proves the file your server
hands to every visitor names no account, no server and no credential. The `404` is the image's own
proxy route answering with `WEBDAV_BACKEND` unset, so no second door is open on your hostname.

If you do not: a 502 with a healthy container means the Caddy step, so re-read step 5. A `200` with
a title count of `0` usually means another site block already owns the hostname, so look through
/etc/caddy/Caddyfile for a duplicate. Anything other than `404` on the last line means an
environment variable reached the container that step 4 did not put there. In every case run
`docker compose logs --tail 40 super-productivity` before changing anything. A running container is
not success.

One more thing before you trust a browser tab as evidence: the app registers a service worker, so a
browser that has loaded the page once keeps serving its cached copy even while the container is
down. Judge the install by the curl output and `docker compose ps` on the server, never by whether
the tab still looks fine.

STOP: open https://<DOMAIN> in a private window, add one throwaway task, and confirm two things to yourself: that the app loads with no login and the task appears, and that you are content for anyone who reaches this hostname to load the same app, knowing that gives them their own empty list and no access to yours. Do not continue until both are true.

## 8. First backup and restore

Two backups, and they are not the same thing. Do both, in this order.

The first is this box, and it is small on purpose: the compose file and the live Caddy site block.
Nothing under /srv/super-productivity is written by the app, so the container does not need to stop.

```bash
cd /srv/super-productivity
sudo tar -czf /srv/super-productivity/backups/super-productivity-$(date +%F).tar.gz \
  -C /srv/super-productivity compose.yml \
  -C /etc/caddy Caddyfile
ls -lh /srv/super-productivity/backups/
```

You should see: one `.tar.gz` listed, a few kilobytes, not zero bytes.

If you do not: read the tar error rather than moving past it. A zero-byte archive means the paths
were wrong, and an archive you never open is not a backup. Then copy it off the box, from your own
machine and not the server:

```bash
mkdir -p ~/backups/super-productivity
scp vps:/srv/super-productivity/backups/*.tar.gz ~/backups/super-productivity/
```

List the archive before you trust it, because an archive nobody has opened is a hope:

```bash
tar -tzf /srv/super-productivity/backups/*.tar.gz
```

You should see: exactly two names, `compose.yml` and `Caddyfile`.

To restore this box cold: recreate the two directories as in step 2, untar the archive into
/srv/super-productivity, append the Caddy site block to /etc/caddy/Caddyfile with `<DOMAIN>`
replaced as in step 5, validate, reload, then `cd /srv/super-productivity && docker compose up -d`.
That gives you the same app at the same URL, and no tasks, because none were ever here.

The second backup is yours, and it is the one that matters. In the app: Settings, the Sync & Backup
tab, then Export data. That downloads one plaintext JSON file of tasks, projects, tags, time
tracking, notes, metrics and archives, which upstream describes as a restorable snapshot of the
application model. Import in the same place replaces current data with it, and that is your restore.
Keep the file off the machine that downloaded it, and treat it as private: it is not encrypted. The
web build schedules no automatic file backup, so this export is the mechanism.

STOP: export that file now, before a real week of work goes in, and put a copy somewhere that is not the machine that downloaded it. Do not continue until that copy exists.

Sync would make that export a fallback rather than the plan, and this install does not configure it,
for two reasons measured against this image on 2026-08-14. Upstream states browser WebDAV sync is
likely to fail on CORS, and Nextcloud sends no CORS headers on its WebDAV endpoints. The image's own
same-origin answer, an nginx `/webdav/` route pointed at `WEBDAV_BACKEND`, refuses uploads over its
1 MB `client_max_body_size` default with 413 and sends no TLS server name upstream, so an HTTPS
Nextcloud that shares an address with other sites can fail the handshake. If you take that route
anyway, `WEBDAV_BACKEND` has to be a scheme and host with no path and no trailing slash, because a
path there replaces the whole request URI. For a Nextcloud user the reliable answer is the desktop
build, which is not subject to CORS.

## 9. Updating later

New versions are listed at https://github.com/super-productivity/super-productivity/releases. The
release tag and the image tag are the same string, and the image lives at
`johannesjo/super-productivity` even though the repository is now
`super-productivity/super-productivity`. Back up first, then edit the image line in
/srv/super-productivity/compose.yml to the new tag and its digest:

```bash
cd /srv/super-productivity
docker compose pull
docker compose up -d
docker compose logs --tail 20 super-productivity
```

You should see: the new image pulled, the container recreated, and a quiet nginx log. Read the
release notes before moving a pin: this project ships several releases a month, and v18.19.0,
released on 2026-08-07, will not stay the newest for long.

If you do not: the most common cause is a digest that does not match the tag you typed. Put the old
tag and digest back, run the same three commands, and the previous version returns. The app also
updates itself through its service worker and asks the browser to reload, so you may be prompted
minutes after the container changed. Reload; do not clear site data, because your tasks are in that
browser.

## 10. What will probably go wrong

I opened this on my laptop, added a week of tasks, then opened the same URL on my phone, found an
empty list, and spent ten minutes sure the install was broken. It was not. There is no server-side
store, so the phone got its own copy of the app and its own empty database, and nothing was lost.
That is the one fact to hold on to, and it is why step 8 makes you export a file. Second: the app
refuses to run in two tabs at once and shows a blocker asking you to close one, which reads like a
crash until you notice the other tab. Third: if the browser denies the app's request for persistent
storage it says so once, in a small notification, and that is the only warning before the browser
can evict your tasks under disk pressure.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy already runs under systemd on this box.
- Do not publish 8199 on `0.0.0.0` or open it in the firewall.
- Do not invent accounts or a first-run wizard for a build that has none.
- Do not set `WEBDAV_BACKEND` or any `WEBDAV_` variable in this session, and do not install
  SuperSync: it is upstream's own sync server, beta by upstream's own description, and it wants a
  Postgres and a second container.

If a check fails, name the step before changing anything else. Preflight is step 1. Compose errors
are step 4. Certificate and 502 problems are step 5. Ports that should be closed are step 6. A 200
with the wrong body is step 4 or 5. An empty archive is step 8.

NOT YET VERIFIED: no harness run has been recorded against this install path.
