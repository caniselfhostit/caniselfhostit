This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Excalidraw, pinned to the image digest in step 4, on a VPS where Prompt
Zero is done: `ssh vps` works, Docker and Caddy are installed, the firewall is
default-deny. Run everything over `ssh vps` unless a step says otherwise, and replace
`<DOMAIN>` with the hostname whose A record already points at the box.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `256` MB available, at least `2` G free, `amd64` or `arm64`, and
your server's IP address on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it at your
DNS provider, wait a minute, run `dig +short <DOMAIN>` again. Do not go on without it,
because Caddy cannot get a certificate for a hostname that does not resolve, and failed
attempts count against a rate limit.

One thing to know before you start, because it changes what "working" means in step 7. The
image upstream publishes is the Excalidraw frontend on its own, an nginx serving compiled
JavaScript. There is no database, no accounts and no server side document store. A drawing
is saved in the browser that drew it, and nowhere else.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/excalidraw /srv/excalidraw/backups
ls -la /srv/excalidraw
```

You should see: a `backups` directory, and your own username in the owner column.

If you do not: `install: cannot change owner` means your user cannot sudo, which is a
Prompt Zero problem rather than this one. If the directory already exists from an earlier
attempt, this command is safe to run again: it fixes the mode and the owner and leaves
anything inside it alone.

## 3. Secrets

There are none. Excalidraw has no accounts, no admin page and no database, so there is no
`.env` file and no token to generate. Nothing in this install needs to be kept secret.

Keep the habit anyway, because the next thing you self-host will have secrets: never paste
the contents of a `.env` file, a token, or any command output containing a password into a
chat window. The model does not need it, and once it is in the transcript it is somebody
else's copy.

## 4. compose.yml

The pin is a digest rather than a version tag because upstream publishes only a rolling
tag for this image, so the digest is the version. Paste this whole block at once,
including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the heredoc lost its indentation
somewhere between the page and your terminal. Run `rm /srv/excalidraw/compose.yml` and
paste the whole block again in one go, and check that your terminal is not converting tabs
into something else. `docker: command not found` means you opened a shell on your own
machine instead of the server, so run `ssh vps` first.

## 5. Caddy and TLS

This appends one site block to the Caddy config that Prompt Zero installed. Replace
`<DOMAIN>` in the block below with your hostname before you paste it. The first line takes
a copy, because a syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: `adapting config` with a line number means the block landed inside another
site block. Run `sudo cp /etc/caddy/Caddyfile.before-excalidraw /etc/caddy/Caddyfile`,
then paste again, and check that the blank line from the second command is really there.
Caddy asks Let's Encrypt for the certificate on the first request to your hostname and
renews it on its own, so there is nothing to schedule and no renewal cron to forget.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, then rules for `80/tcp`, `443/tcp` and `443/udp`, and no
rule mentioning `8083`.

If you do not: a rule for `8083` from an earlier attempt should go, with
`sudo ufw delete allow 8083`. 8083 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it and a firewall rule for it would be a rule for traffic
that cannot arrive. 80/tcp is there to redirect to HTTPS and to answer the ACME challenge,
443/tcp is the only way in, and 443/udp is HTTP/3.

## 7. Start and verify

```bash
cd /srv/excalidraw
docker compose pull
docker compose up -d
sleep 10
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -c 'Excalidraw'
```

You should see: `200` from the first curl, and a number greater than `0` from the second,
because `Excalidraw` appears in the title of the page it served.

If you do not: `000` or `502` almost always means the certificate is not there yet. Run
`dig +short <DOMAIN>` once more, then `sudo journalctl -u caddy -n 30` to watch the ACME
attempt. If the certificate is fine but the second command prints `0`, run
`docker compose logs --tail 30 excalidraw` and look for the container restarting. A
container in `docker ps` is not proof of anything; the two commands above are.

Now open https://<DOMAIN> in a browser. The first screen is a blank white canvas with the
drawing toolbar across the top. There is no login form and no sign-up link, because there
are no accounts. Anyone who finds this hostname gets their own blank canvas, and they
cannot see your drawings, because your drawings never leave your browser.

## 8. First backup and restore

Two things need copying and only one of them is on the server. Start with the
configuration:

```bash
cd /srv/excalidraw
tar -czf /srv/excalidraw/backups/excalidraw-config-$(date +%F).tar.gz compose.yml Caddyfile
ls -lh /srv/excalidraw/backups/
```

You should see: one `.tar.gz` file with a size in the low single-digit kilobytes. Nothing
is stopped and nothing goes offline, because there is no database to catch mid-write.

If you do not: a size of `0` means the `cd` did not happen and tar found nothing to add.
Run the three lines again as one paste. `tar: compose.yml: Cannot stat` means step 4 wrote
the file somewhere else, so check `ls -la /srv/excalidraw` before you go on.

A backup on the same disk as the thing it backs up is not a backup. Run this one on your
own machine, not on the server:

```bash
mkdir -p ~/backups/excalidraw
scp vps:/srv/excalidraw/backups/*.tar.gz ~/backups/excalidraw/
```

You should see: one file copied, and the same file listed by
`ls -lh ~/backups/excalidraw/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake.
The `vps:` prefix only means something on your own machine.

Now the drawings, which no command on the server can reach. Open https://<DOMAIN>, draw
one line, and use the app's export to save the scene as a file on your own machine.

You should see: a file on your own disk whose name ends in `.excalidraw`, a few kilobytes
in size. That file is the only backup of a drawing that exists anywhere.

If you do not: the export lives in the app's own menu, not in the browser's print dialog,
and the browser will have put the file wherever your downloads go rather than asking you.

To restore the server: untar the archive into /srv/excalidraw, paste the Caddy block from
step 5 again, and run `docker compose up -d`. To restore a drawing: open the app and
import the file you exported. Those are two separate disaster plans, the second one is the
one holding your work, and exporting is a habit rather than something you did once.

## 9. Updating later

There is no release page to watch for this image and no changelog tied to the tag, which
is a real cost of pinning it. Take a backup, then read the digest upstream publishes
today:

```bash
docker pull excalidraw/excalidraw
docker image inspect --format '{{index .RepoDigests 0}}' excalidraw/excalidraw
```

You should see: one line ending in `@sha256:` and 64 hex characters. Put that digest into
the `image:` line of /srv/excalidraw/compose.yml, then:

```bash
cd /srv/excalidraw
docker compose pull
docker compose up -d
docker compose logs --tail 20 excalidraw
```

You should see: `Recreated`, then nginx startup lines and no repeated restart.

If you do not: put the old digest back and run the same three commands. Nothing on this
server holds a drawing, so a bad update costs you a page, not your work. Write the digest
you replaced into a note next to the compose file, because there is no tag history to look
it up from later.

## 10. What will probably go wrong

The drawings. I installed this, drew a diagram on my laptop, then opened the same hostname
on my phone and found an empty canvas, and I spent a few minutes certain the install was
broken. It was not. The container has nowhere to put a document, so the drawing was in the
laptop's browser storage and nowhere else. Clearing site data, using a private window or
switching devices loses work that was never on the server. If a drawing vanishes, the
question is which browser you drew it in, not which log to read.

## 11. Out of scope

- Do not install excalidraw-room or wire up live collaboration. That is a second service
  with its own socket transport, and this install is one container.
- Do not add an S3 bucket, a database, or any storage backend. This image has no server
  side storage to point at one, so a bucket would sit there empty.
- Do not put basic auth in the Caddy block. If you want the board private, the answer is a
  hostname you do not hand out.
- Do not set analytics or telemetry environment variables. The published image ships
  without them, which is one of the reasons to run it.
