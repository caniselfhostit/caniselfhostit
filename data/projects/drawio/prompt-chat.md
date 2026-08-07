This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing draw.io 31.1.8 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record
already points at the box.

Read this before step 1, because it is the reason to stop and think rather than the reason
to keep going. draw.io already runs a hosted editor at https://app.diagrams.net that costs
nothing and asks for no account: their own home page says "No account required. No credit
card." This install gives you the same editor. What it changes is where the page comes
from: it loads from a hostname you control, on a machine you control, and no third-party
origin ever serves the code. That is what an offline network, an air-gapped site or a
written company policy needs. If none of those three describe you, the free hosted editor
does this job and you can close this tab with nothing lost.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname
that does not resolve, and failed attempts count against a rate limit you cannot see. The
RAM floor is 1024 MB because this is a Tomcat on a JVM rather than a static file server; on
a 512 MB box the container starts and then dies during the first page load, which reads as
a broken install rather than as a memory problem.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/drawio /srv/drawio/backups
ls -la /srv/drawio
```

You should see: `backups`, owned by you.

If you do not: there is no `data` directory in that command and that is deliberate. The
container writes no diagram anywhere on this server, so the only files that will ever live
under /srv/drawio are the two the next steps write and the archive step 8 makes of them.

## 3. Secrets

One secret, and it is not a login. draw.io has no accounts, so there is nothing to sign in
to and no admin page to protect. What this generates is `KEYSTORE_PASS`: the image builds a
self-signed certificate for its own container port 8443 at every start, and when that
variable is unset it uses a password printed in its own public documentation. Port 8443 is
never published by this install, so nobody outside the container can reach that
certificate, and a documented default is still a documented default.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>`
on the first line with your real hostname before you paste, and keep the trailing slash:
`DRAWIO_SERVER_URL` is upstream's variable for the public deployment URL and it wants one.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens
if you pasted the lines separately in different shells. Run `chmod 600 /srv/drawio/.env` and
carry on. If the file already existed from an earlier attempt this block has overwritten
it, which costs nothing here, because the container regenerates its certificate at every
start anyway.

Do not paste that file, the generated value, or any command output containing it into this
chat window. Nothing in this install will ever ask you to type it back, so there is no
reason it should leave the server.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/drawio/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your
terminal, so run `rm /srv/drawio/compose.yml` and paste again in one go. There is no
`volumes:` key in that file and nothing is missing: the container has nowhere to put a
document, which is the single most important fact about this install.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a
syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-drawio /etc/caddy/Caddyfile`,
reload, and paste again. Do not add a `Content-Security-Policy` header of your own here.
The container writes its own CSP into the page as a meta tag at start-up, and a browser
enforces the intersection of the two, so a second policy usually shows up as an editor that
loads to a blank grey screen with errors in the browser console and nothing at all in the
Caddy log.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8158` or `8443`.

If you do not: delete anything for those two with `sudo ufw delete allow 8158`. 8158 is
bound to 127.0.0.1 by the compose file, and 8443 is never published at all, so the
container's own TLS port has no host port a firewall rule could apply to. `Status: inactive`
is a different problem: Prompt Zero left this firewall enabled, so something has turned it
off since, and `sudo ufw enable` puts it back before you go any further.

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

You should see, in order: the loop reaching `200`, then `1`, then `1`, then `1`.

If you do not: the third command is the one worth understanding. It reads the configuration
file the container generated at start-up and checks that `gapi` is off, which means the
Google Drive backend is not offered to anyone who loads your editor. A `0` there means a
cloud storage button will appear in the app, and the cause is an environment variable that
should not be set. A `404` on PreConfig.js instead means the entrypoint could not write into
the webapp, which shows up in `docker compose logs --tail 40 drawio` as a `WARNING: No write
access` line. If the loop never reaches `200`, that is almost always DNS: a hostname whose
A record was created minutes ago makes Caddy's first certificate attempt fail and retry
quietly. A running container is not success. Four asserts passing is success.

The first screen at https://<DOMAIN>/?offline=1 is a dialog headed `Save diagrams to:` with
two buttons, `Device` and `Browser`, and a `Decide Later` link under them. There is no login
form and no sign-up link, because there are no accounts.

Open https://<DOMAIN>/?offline=1 now and confirm that dialog shows `Device` and `Browser`
and no Google Drive, OneDrive or GitHub button. That is the check no command can make for
you, and it is the difference between an editor that keeps your work on your own hardware
and one that offers to post it somewhere else.

## 8. First backup and restore

There is no database to dump and no data directory to archive, and saying so is more useful
than inventing one. The backup here is the configuration that rebuilds the service:

```bash
cd /srv/drawio
sudo tar -czf /srv/drawio/backups/drawio-config-$(date +%F).tar.gz -C /srv/drawio compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/drawio/backups/
```

You should see: one file, a couple of kilobytes. Nothing goes offline, because there is no
write to catch halfway.

If you do not: an archive of about 45 bytes is an empty one, which means `tar` found none of
the three files. Check that you are in /srv/drawio and that step 3 and step 4 both wrote
their file.

A backup on the same disk as the data is not a backup. Run this one on your own machine,
not the server:

```bash
mkdir -p ~/backups/drawio
scp vps:/srv/drawio/backups/*.tar.gz ~/backups/drawio/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/drawio/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now the other half, and no command on that server can reach it. Open
https://<DOMAIN>/?offline=1, draw one shape, and use File then Save As to write the
`.drawio` file somewhere on your own computer. If you picked `Browser` in that first dialog
the diagram is in one browser's local storage on one machine, and the archive you took
above does not contain it and never will.

To restore the server: untar the archive into /srv/drawio, append the Caddy block from step
5 again, and run `docker compose up -d`. To restore a diagram, open the editor and use File
then Open to load the file you saved. That is two disaster plans, the second one holds your
work, and saving to your own disk is a habit rather than a step you did once today.

## 9. Updating later

New versions are listed at https://github.com/jgraph/drawio/releases, and the Docker tag is
the release tag without its leading `v`. Take the backup first, then edit the `image:` line
in /srv/drawio/compose.yml to the new tag and its digest.

```bash
cd /srv/drawio
docker compose pull
docker compose up -d
docker compose logs --tail 30 drawio
```

You should see: the entrypoint printing the configuration it wrote, then Tomcat starting,
and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
all four asserts from step 7 before you call the update done. Nothing is migrated in an
upgrade here, because the container carries no state between versions, which makes a
rollback the cheapest one in this catalogue.

## 10. What will probably go wrong

The first dialog. I clicked `Browser` because it sounded like the thing running on the
server, drew a diagram, and came back the next morning on a different laptop to an empty
canvas at the same hostname. Nothing was broken. `Browser` means that browser's local
storage on that machine, `Device` means a file on the computer in front of you, and neither
of them is the server. I spent several minutes reading Tomcat logs looking for a database
that has never existed. If a diagram disappears, ask which browser and machine you drew it
on before you read a log line.

## 11. Out of scope

- Do not install the export server or set `DRAWIO_SELF_CONTAINED` or `EXPORT_URL`. That is
  a second container carrying its own headless Chromium, and this install runs one service.
  PNG and SVG export from the browser works without it.
- Do not set `DRAWIO_GOOGLE_CLIENT_ID`, `DRAWIO_MSGRAPH_CLIENT_ID` or `DRAWIO_GITLAB_ID`.
  Each one is an OAuth application registered with somebody else, and step 7 asserts that
  those backends are off.
- Do not set `ENABLE_DRAWIO_PROXY=1`. It opens a `/proxy` endpoint that fetches arbitrary
  external URLs on your server's behalf, which is a request forwarder pointed at your own
  network.
- Do not publish container port 8443 and do not set `LETS_ENCRYPT_ENABLED`. Caddy holds the
  certificate for this hostname, and a second one inside the container would be a second
  thing to renew.
