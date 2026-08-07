You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install draw.io 31.1.8 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. The A record for it must already point at this server.

Say this to the user before anything installs, because it is the reason to stop and think
rather than the reason to keep going. draw.io already runs a hosted editor at
https://app.diagrams.net that costs nothing and asks for no account: their own home page
says "No account required. No credit card." What this install buys is not the editor, it
is where the editor comes from. The page loads from a hostname the user controls, on a
machine they control, with no third-party origin serving the code, which is what an
offline network, an air-gapped site or a written company policy actually needs. If none of
those three describe the user, tell them plainly that the free hosted editor does the same
job and let them decide before step 2.

draw.io needs 1024 MB of RAM available and 5 GB free on /srv. It is a Tomcat on a JVM, and
the image publishes amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop.
Do not install and hope. If `dig +short` prints nothing the A record does not exist yet, so
print that and stop: Caddy cannot get a certificate for a hostname that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/drawio /srv/drawio/backups
ls -la /srv/drawio
```

Assert: `ls -la` shows `backups` owned by the login user. There is no `data` directory and
there is nothing to create one for. The container writes no diagram anywhere on this
server, so the only files under /srv/drawio are the two this prompt writes and the archive
step 8 makes of them.

## 3. Secrets

One secret, and it is not a login. draw.io has no accounts, so there is nothing to sign in
to and no admin page to protect. What this generates is `KEYSTORE_PASS`: the image builds a
self-signed certificate for its own port 8443 at every start, and when that variable is
unset it uses a password printed in its own public documentation. Port 8443 is never
published by this install, so nobody outside the container can reach that certificate, and
a documented default is still a documented default. Generate the value, do not print it, do
not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/drawio/.env <<EOF
DRAWIO_SERVER_URL=https://<DOMAIN>/
KEYSTORE_PASS=$(openssl rand -hex 32)
EOF
chmod 600 /srv/drawio/.env
umask 022
ls -l /srv/drawio/.env
```

Assert: the file exists with mode `-rw-------`. `DRAWIO_SERVER_URL` is upstream's variable
for the public deployment URL and it wants the trailing slash, which is why the line ends
in one. Tell the user this file holds no credential they will ever be asked to type.

## 4. compose.yml

```bash
cat > /srv/drawio/compose.yml <<'EOF'
# draw.io · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image, ports, env vars .. https://github.com/jgraph/docker-drawio/blob/v31.1.8/README.md
#   entrypoint behaviour .... https://github.com/jgraph/docker-drawio/blob/v31.1.8/main/docker-entrypoint.sh
#   image build ............. https://github.com/jgraph/docker-drawio/blob/v31.1.8/main/Dockerfile
#
# One container: Tomcat 9 on JDK 11 serving the compiled draw.io editor at the
# root path on container port 8080, as a non-root tomcat user. There is no
# database and no account system, and this file mounts no volume, because the
# server holds no diagram. A diagram is written to the reader's own device or
# into the storage of the browser that drew it.
#
# The entrypoint switches every cloud backend off when its credentials are
# absent: with no DRAWIO_GOOGLE_CLIENT_ID, DRAWIO_MSGRAPH_CLIENT_ID or
# DRAWIO_GITLAB_ID it writes gapi, od and gl to 0, and it always writes db, gh
# and tr to 0. This file sets none of them, so none of them are on.
#
# KEYSTORE_PASS arrives from /srv/drawio/.env. Left alone, the image falls back
# to a keystore password printed in its own documentation and puts it on a
# self-signed certificate it regenerates at every start. Container port 8443 is
# never published here, so nothing outside can reach that certificate; the
# generated value is what keeps a documented default from standing behind it.
#
# Tag and digest read from Docker Hub on 2026-08-06; the manifest list covers
# linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  drawio:
    image: jgraph/drawio:31.1.8@sha256:0c8910ea14dfbccb17c784ee17d995317a8d753479f5ec0f21b2ab2213153100
    container_name: drawio
    restart: unless-stopped
    env_file: /srv/drawio/.env
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8080/ >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8158.
      - "127.0.0.1:8158:8080"
EOF
cd /srv/drawio && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on 8080 inside itself and 8158 on
this host is bound to 127.0.0.1, so Caddy is the only route in.

## 5. Caddy and TLS

Append the site block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>`
replaced by the real hostname. Copy the file first, because a syntax error here takes down
every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-drawio
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# draw.io · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://caddyserver.com/docs/automatic-https
# and https://github.com/jgraph/docker-drawio/blob/v31.1.8/README.md
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname whose A record already points at this
# box. Caddy asks for the certificate on the first request and renews it on its
# own, so there is nothing to schedule. The container builds a self-signed
# certificate for its own port 8443 at every start; that port is not published,
# and Caddy is the only thing terminating TLS in front of this service.

<DOMAIN> {
	# The editor is several megabytes of JavaScript on a cold load, so
	# compression is the one setting here that changes what the user feels.
	encode zstd gzip

	# No Content-Security-Policy line on purpose. The container injects its own
	# CSP as a meta tag at start-up and a second policy sent as a header would
	# intersect with it, which fails as a blank editor rather than as an error.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8158 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8158
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-drawio, reload, and report what it objected to. Caddy requests
the certificate on the first request to the hostname and renews it without a cron job.

## 6. Firewall

Two ports open, both of them Caddy's, and neither 8158 nor 8443 is one of them. These
commands are idempotent, so on a box Prompt Zero already configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. 8158 stays closed because it is bound to
127.0.0.1, and 8443 stays closed because compose never publishes it: the container's own
TLS port has no host port a rule could apply to. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and shows no rule for 8158 or 8443.

## 7. Start and verify

Tomcat rewrites the editor's configuration files from the environment at every start, so
the first boot is slower than the ones after it.

```bash
cd /srv/drawio
docker compose pull
docker compose up -d
for i in $(seq 1 20); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/ | grep -c 'Flowchart Maker'
curl -sS https://<DOMAIN>/js/PreConfig.js | grep -cF "urlParams['gapi'] = '0'"
curl -sS https://<DOMAIN>/js/PreConfig.js | grep -cF "window.DRAWIO_SERVER_URL = 'https://<DOMAIN>/'"
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The
second command prints `1`, because `Flowchart Maker` is in the title of the served
document. The third prints `1`, which is the security assert in this block: it proves the
container wrote `gapi` off, so the Google Drive backend is not offered to anyone who loads
this page. The fourth prints `1`, which proves the `.env` from step 3 reached the
container. If any of the four misses, stop, run `docker compose logs --tail 40 drawio`, and
say which earlier step is the likely cause: a `404` on PreConfig.js means the entrypoint
could not write into the webapp, and a first curl that never reaches `200` is usually DNS,
because a hostname whose A record was created minutes ago makes Caddy's first certificate
attempt fail and retry quietly. A running container is not success. Four asserts passing is
success.

The first screen at https://<DOMAIN>/?offline=1 is a dialog headed `Save diagrams to:` with
two buttons, `Device` and `Browser`, and a `Decide Later` link under them. There is no login
form and no sign-up link, because there are no accounts.

STOP: tell the user to open https://<DOMAIN>/?offline=1, confirm that dialog shows `Device`
and `Browser` and no Google Drive, OneDrive or GitHub button, and wait.
Do not continue until they confirm. No command can make that check for them, and it is the
difference between an editor that keeps their work on their own hardware and one that
offers to post it somewhere else.

## 8. First backup and restore

There is no database to dump and no data directory to archive, and saying so is more useful
than inventing one. The backup here is the configuration that rebuilds the service:

```bash
cd /srv/drawio
sudo tar -czf /srv/drawio/backups/drawio-config-$(date +%F).tar.gz -C /srv/drawio compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/drawio/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped, because
there is no write to catch halfway. A backup on the same disk is not a backup, so run this
one from the user's machine, not the server:

```bash
mkdir -p ~/backups/drawio
scp vps:/srv/drawio/backups/*.tar.gz ~/backups/drawio/
```

The diagrams are the other half, and no command on this server can reach them.

STOP: tell the user to open https://<DOMAIN>/?offline=1, draw one shape, and use File then
Save As to write the `.drawio` file somewhere on their own computer, and wait.
Do not continue until they confirm they have that file. Explain why: if they picked
`Browser` in that dialog the diagram is in one browser's local storage on one machine, and
no backup taken on this server would ever have contained it.

To restore the server: untar the archive into /srv/drawio, append the Caddy block from step
5 again, and run `docker compose up -d`. To restore a diagram, open the editor and use File
then Open to load the saved file. Tell the user that is two disaster plans, that the second
one holds the work, and that saving to their own disk is a habit rather than a step they
did once today.

## 9. Updating later

New versions are listed at https://github.com/jgraph/drawio/releases, and the Docker tag is
the release tag without its leading `v`. Take a backup first, then edit the image line in
/srv/drawio/compose.yml to the new tag and its digest:

```bash
cd /srv/drawio
docker compose pull
docker compose up -d
docker compose logs --tail 30 drawio
```

Then re-run all four asserts from step 7 before calling the update done. Nothing is
migrated in an upgrade here, because the container carries no state between versions.

## 10. What will probably go wrong

The first dialog. I clicked `Browser` because it sounded like the thing running on the
server, drew a diagram, and came back the next morning on a different laptop to an empty
canvas at the same hostname. Nothing was broken. `Browser` means that browser's local
storage on that machine, `Device` means a file on the computer in front of you, and neither
of them is the server. I spent several minutes reading Tomcat logs looking for a database
that has never existed. If the user reports a diagram has vanished, ask which browser and
machine they drew it on before you read a log line.

## 11. Out of scope

- Do not install the export server or set `DRAWIO_SELF_CONTAINED` or `EXPORT_URL`. That is
  a second container carrying its own headless Chromium, and this prompt installs one
  service. PNG and SVG export from the browser works without it.
- Do not set `DRAWIO_GOOGLE_CLIENT_ID`, `DRAWIO_MSGRAPH_CLIENT_ID` or `DRAWIO_GITLAB_ID`.
  Each one is an OAuth application registered with somebody else, and step 7 asserts that
  those backends are off.
- Do not set `ENABLE_DRAWIO_PROXY=1`. It opens a `/proxy` endpoint that fetches arbitrary
  external URLs on this server's behalf, which is a request forwarder pointed at the user's
  own network.
- Do not publish container port 8443 and do not set `LETS_ENCRYPT_ENABLED`. Caddy holds the
  certificate for this hostname, and a second one inside the container would be a second
  thing to renew.
