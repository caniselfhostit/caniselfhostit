You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Super Productivity v18.19.0 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer. Its
A record must already point at this server. Say three things when you ask, because they decide
whether this is the right install at all.

One: this server holds none of their tasks. The image is nginx serving a built web app as static
files, and upstream states that data is stored in the browser and the container provides no
persistent storage, so clearing site data for the hostname deletes the lot.

Two: with no server-side store there is no account and no login, and the page answers everybody. A
stranger who loads the URL gets their own empty list, not a window into the user's. Caddy
`basic_auth` is the opt-in and this install does not enable it.

Three: cross-device sync is not one setting away, and it is what a TickTick subscriber most wants
back. Block 8 carries the two measured reasons this install leaves it off.

Super Productivity needs 256 MB of RAM available and 2 GB free on /srv. The image is about 320 MB
and idles at nearly nothing. The pinned tag publishes linux/amd64 and linux/arm64. Measure:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 256 MB or free disk is under 2 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: the certificate is
load-bearing here, because browsers grant a service worker and WebCrypto only on a secure origin.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/super-productivity /srv/super-productivity/backups
ls -la /srv/super-productivity
```

Assert: `ls -la` shows `backups` owned by the login user. There is no `data/` directory: step 4
mounts nothing, so a `data/` here would archive empty space and imply a safety that does not exist.
Say that to the user now.

## 3. Secrets

No secret is generated, there is no `.env` file, and there is no default credential for step 7 to
close. This build ships no account, no registration form and no administration screen, so there is
no first claimant and no claim race. Do not invent a setup step for software with none.

What replaces it is publication, and a sync credential this install never touches. The image's
entrypoint can write `assets/sync-config-default-override.json` from `WEBDAV_BASE_URL`,
`WEBDAV_USERNAME`, `WEBDAV_SYNC_FOLDER_PATH`, `SYNC_INTERVAL`, `IS_COMPRESSION_ENABLED` and
`IS_ENCRYPTION_ENABLED`, and that file is served to every visitor. Upstream provides no variable
for a password: the sync password is typed into the browser and stored by the browser. Step 4 sets
none of those variables, so the served file stays the one comment line the image ships, and step 7
prints it as evidence.

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

Assert: that prints `compose OK`. One service, one published port, no volumes, no env_file. Do not
add a Caddy service here: Caddy already runs under systemd on this box.

## 5. Caddy and TLS

Write the site block to `/srv/super-productivity/Caddyfile`, then append it to the live Caddyfile
with `<DOMAIN>` replaced. Copy the live file first: a syntax error takes down every site here.

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

Set `DOMAIN_HOST` to the real hostname from step 1 before running `sed`. Assert: `caddy validate`
exits 0 and the reload exits 0. If validate fails, restore
`/etc/caddy/Caddyfile.before-super-productivity`, reload, and report what it objected to. Caddy
issues the certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's, both idempotent:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8199 stays closed because compose binds it to 127.0.0.1. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8199.

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

Assert all five and print what you received. The loop ends printing `200`. The title grep prints
`1`, because the built page carries `<title>Super Productivity</title>`. The third command prints
the served sync defaults, a single `_comment` key and nothing else. The fourth prints `0`, and that
zero is the security assert here: it proves the file the server hands every visitor names no
account, no server and no credential, because step 4 set none of the variables that would put them
there. The fifth prints `404`, the image's own proxy route answering with `WEBDAV_BACKEND` unset.

If any miss, stop, run `docker compose logs --tail 40 super-productivity`, and name the likely
earlier step. A 502 with a healthy container is step 5. A `200` with a title count of `0` means
another site block owns the hostname. Anything but `404` on the last line means an environment
variable reached the container that step 4 did not put there. A running container is not success.

STOP: tell the user to open https://<DOMAIN> in a private window, add one throwaway task, and
confirm two things: that the app loads with no login and the task appears, and that they are content
for anyone reaching this hostname to load the same app, knowing that gives them their own empty list
and no access to theirs. Do not continue until they confirm.

## 8. First backup and restore

Two backups here, and they are not the same thing. Do both, in this order.

The first is this box: one compose file and the live Caddy site block. Nothing under
/srv/super-productivity is written by the app, so the container need not stop.

```bash
cd /srv/super-productivity
sudo tar -czf /srv/super-productivity/backups/super-productivity-$(date +%F).tar.gz \
  -C /srv/super-productivity compose.yml \
  -C /etc/caddy Caddyfile
ls -lh /srv/super-productivity/backups/
```

Assert: the archive exists and is non-empty. Print its size. If that tar reports an error, stop
and report it.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/super-productivity
scp vps:/srv/super-productivity/backups/*.tar.gz ~/backups/super-productivity/
```

To restore this box cold: recreate the directories as in step 2, untar the archive into
/srv/super-productivity, append the Caddy block to /etc/caddy/Caddyfile with `<DOMAIN>` replaced as
in step 5, validate, reload, then `cd /srv/super-productivity && docker compose up -d`. Same app,
same URL, no tasks, because none were ever here.

The second backup is the user's, and it is the one that matters. In the app: Settings, the
Sync & Backup tab, then Export data. That downloads one plaintext JSON file of tasks, projects,
tags, time tracking, notes, metrics and archives, which upstream describes as a restorable snapshot
of the application model. Import in the same place replaces current data with it, and that is the
restore. Keep the file off the machine that downloaded it and treat it as private: it is not
encrypted. The web build schedules no automatic file backup, so this export is the mechanism.

STOP: tell the user to export that file now, before a real week of work goes in, and to confirm both the filename and that a copy of it is off the machine that downloaded it. Do not continue until they confirm.

Sync would make that export a fallback rather than the plan, and this install does not configure
it, for two reasons measured against this image on 2026-08-14. Upstream states browser WebDAV sync
is likely to fail on CORS, and Nextcloud sends no CORS headers on its WebDAV endpoints. The image's
own same-origin answer, an nginx `/webdav/` route pointed at `WEBDAV_BACKEND`, refuses uploads over
its 1 MB `client_max_body_size` default with 413 and sends no TLS server name upstream, so an HTTPS
Nextcloud sharing an address with other sites can fail the handshake. Anyone taking that route must
set `WEBDAV_BACKEND` to a scheme and host with no path and no trailing slash, because a path there
replaces the whole request URI. For a Nextcloud user the reliable answer is the desktop build, which
is not subject to CORS.

## 9. Updating later

New versions are listed at https://github.com/super-productivity/super-productivity/releases. The
release tag and the image tag are the same string, and the image lives at
`johannesjo/super-productivity` even though the repository is now
`super-productivity/super-productivity`. Take a backup first, then edit the image line in
compose.yml to the new tag and its digest:

```bash
cd /srv/super-productivity
docker compose pull
docker compose up -d
docker compose logs --tail 20 super-productivity
```

Re-run step 7's asserts before calling the update done. The app also updates itself through its
service worker and asks the browser to reload, so a user with the tab open may be prompted minutes
later. Their data is in that browser: tell them to reload, not to clear.

## 10. What will probably go wrong

I opened this on my laptop, added a week of tasks, then opened the same URL on my phone, found an
empty list, and spent ten minutes sure the install was broken. It was not. There is no server-side
store, so the phone got its own copy of the app and its own empty database, and nothing was lost.
That is the one fact to hold on to, and it is why step 8 makes you export a file. Second: the
app refuses to run in two tabs at once and shows a blocker asking you to close one, which reads
like a crash until you notice the other tab. Third: if the browser denies the app's request for
persistent storage it says so once, in a small notification, and that is the only warning before
the browser can evict your tasks under disk pressure.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy already runs under systemd on this box.
- Do not publish 8199 on `0.0.0.0` or open it in the firewall.
- Do not invent accounts, a first-run wizard, or a claim-race warning for a build that has none.
- Do not set `WEBDAV_BACKEND` or any `WEBDAV_` variable in this session, and do not install
  SuperSync: it is upstream's own sync server, beta by upstream's own description, and it wants a
  Postgres and a second container.
