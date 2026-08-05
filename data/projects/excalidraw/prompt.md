You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Excalidraw, pinned to the image digest in step 4, on that server, reachable at
https://<DOMAIN>, behind the existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. The A record for it must already point at this server.

Excalidraw needs 256 MB of RAM available and 2 GB free on /srv. The image is published for
amd64 and arm64, so both work. Measure all four before touching anything:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 256 MB or free disk is under 2 GB, print both numbers and stop.
Do not install and hope. If `dig +short` prints nothing the A record does not exist yet,
so print that and stop: Caddy cannot get a certificate for a hostname that does not
resolve.

Read this next paragraph before you go further, because it changes what "working" means in
step 7. The image upstream publishes is the Excalidraw frontend on its own, an nginx
serving compiled JavaScript. There is no database, no account system and no server side
document store. A drawing is saved in the browser that drew it. This prompt installs
exactly that and nothing more.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/excalidraw /srv/excalidraw/backups
ls -la /srv/excalidraw
```

Assert: `ls -la` shows `backups` and shows the login user as owner. Everything for this
service lives under /srv/excalidraw and nothing is written outside it.

## 3. Secrets

There are none. Excalidraw has no accounts, no admin page and no database, so this install
generates no secret and writes no `.env`. Do not invent a token to make the install feel
more finished.

## 4. compose.yml

Write this file exactly as it appears. The pin is a digest rather than a version tag
because upstream publishes only a rolling tag for this image, so the digest is the version
here.

```bash
cat > /srv/excalidraw/compose.yml <<'EOF'
# Excalidraw · the deterministic fallback.
#
# Authored by caniselfhostit from the upstream documentation, not copied from a
# repository:
#   image and port ..... https://hub.docker.com/r/excalidraw/excalidraw
#   docker notes ....... https://docs.excalidraw.com/docs/introduction/development
#   collab server ...... https://github.com/excalidraw/excalidraw-room
#
# One container, and it is an nginx serving the compiled Excalidraw frontend.
# There is no database, no account system and no server side document store.
# Every drawing lives in the browser that drew it.
#
# Upstream publishes no versioned tag for this image, only a rolling one, so the
# pin is the multi-arch manifest digest read from Docker Hub on 2026-08-05, which
# covers linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  excalidraw:
    image: excalidraw/excalidraw@sha256:f7ee194addd607bf831d2af0f0a34463dd4225e426cf35199ef0b12a803398e9
    container_name: excalidraw
    restart: unless-stopped
    ports:
      # Loopback only. The Caddy that Prompt Zero installed on the host is the
      # only thing that can reach this port, and 8083 never enters the firewall.
      - "127.0.0.1:8083:80"
EOF
cd /srv/excalidraw && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on port 80 inside itself, and 8083
on the host is bound to 127.0.0.1, so the only route in is through Caddy.

## 5. Caddy and TLS

Append the site block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>`
replaced by the real hostname. Copy the file first, because a syntax error here takes down
every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-excalidraw
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Excalidraw · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://caddyserver.com/docs/automatic-https
# and https://hub.docker.com/r/excalidraw/excalidraw
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname whose A record already points at this box.
# Caddy asks for the certificate on the first request and renews it on its own,
# so there is nothing to schedule.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8083 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8083
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-excalidraw, reload, and report what it objected to. Caddy
requests the certificate on the first request to the hostname and renews it without a cron
job.

## 6. Firewall

Two ports open, both of them Caddy's, and 8083 is not one of them. These commands are
idempotent, so running them on a box Prompt Zero already configured changes nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. 8083 stays closed: it is bound to
127.0.0.1, so a rule for it would be a rule for traffic that cannot arrive. If 8083
appears in that output a previous run left it there, and `sudo ufw delete allow 8083`
removes it.

Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and
shows no rule for 8083.

## 7. Start and verify

```bash
cd /srv/excalidraw
docker compose pull
docker compose up -d
sleep 10
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -c 'Excalidraw'
```

Assert: the first curl prints `200` and the second prints a number greater than `0`,
because `Excalidraw` appears in the title of the served document. Print what you actually
received for both. If either misses, stop, run `docker compose logs --tail 30 excalidraw`,
and say which earlier step is the likely cause. The usual one is DNS: a hostname whose A
record was created minutes ago makes Caddy's first certificate attempt fail and retry
quietly.

A running container is not success. Two asserts passing is success.

The first screen at https://<DOMAIN> is a blank white canvas with the drawing toolbar
across the top. There is no login form and no sign-up link, because there are no accounts.
Anyone who reaches this hostname gets their own blank canvas, and they cannot see the
user's drawings, because those never leave the user's browser.

## 8. First backup and restore

Two things need copying and only one of them is on this server. The configuration first:

```bash
cd /srv/excalidraw
tar -czf /srv/excalidraw/backups/excalidraw-config-$(date +%F).tar.gz compose.yml Caddyfile
ls -lh /srv/excalidraw/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped, because
there is no database to catch mid-write. A backup on the same disk as the data is not a
backup either, so run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/excalidraw
scp vps:/srv/excalidraw/backups/*.tar.gz ~/backups/excalidraw/
```

The drawings are the other thing, and no command on this server reaches them.

STOP: tell the user to open https://<DOMAIN>, draw one line, then use the app's export to
save the scene to a file on their own machine, and wait. Do not continue until they
confirm they have that file.

To restore the server, untar the archive into /srv/excalidraw, append the Caddy block
again, and run `docker compose up -d`. To restore a drawing, open the app and import the
exported file. Tell the user that is two disaster plans, that the second one holds their
work, and that exporting is a habit rather than a step they did once.

## 9. Updating later

There is no release page to watch for this image and no changelog tied to the tag, which
is a real cost of pinning it. Read the digest upstream publishes today, then edit
compose.yml:

```bash
docker pull excalidraw/excalidraw
docker image inspect --format '{{index .RepoDigests 0}}' excalidraw/excalidraw
```

Take a backup first. Put the digest that prints into the `image:` line in
/srv/excalidraw/compose.yml, then:

```bash
cd /srv/excalidraw
docker compose pull
docker compose up -d
docker compose logs --tail 20 excalidraw
```

## 10. What will probably go wrong

The drawings. I installed this, drew a diagram on my laptop, then opened the same hostname
on my phone and found an empty canvas, and I spent a few minutes certain the install was
broken. It was not. The container has nowhere to put a document, so the drawing was in the
laptop's browser storage and nowhere else. Clearing site data, using a private window or
switching devices loses work that was never on the server. If the user reports a drawing
has vanished, ask which browser they drew it in before you read any log.

## 11. Out of scope

- Do not install excalidraw-room or wire up live collaboration. That is a second service
  with its own socket transport, and this prompt installs one container.
- Do not add an S3 bucket, a database, or any storage backend. This image has no server
  side storage to point at one, so a bucket would sit there empty.
- Do not put basic auth in the Caddy block. If the user wants the board private the answer
  is a hostname they do not hand out, and that decision is theirs.
- Do not set analytics or telemetry environment variables. The published image ships
  without them, which is one of the reasons to run it.
