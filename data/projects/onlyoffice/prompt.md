You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install ONLYOFFICE Docs 9.4.0 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

Say this to the user before anything installs, because it decides whether they want this at
all. ONLYOFFICE Docs is the editing engine, not a place to keep files: on its own it edits
nothing, it renders and saves documents another application hands it. Install it if the user
already runs Nextcloud or another application with an ONLYOFFICE connector, or is about to.
Otherwise this leaves them a correctly running server with nothing pointed at it.

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. That hostname goes into the other
application's settings later, and it has to be reachable from every user's browser and from
that application's own server, because both talk to it.

Upstream asks for 4 GB of RAM, at least 40 GB of free disk and at least 4 GB of swap, on amd64
or arm64. Most of that disk is headroom for logs and the cache of open documents, not the
install. Measure everything first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
free -m | awk '/^Swap:/ {print $2 " MB swap"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 40 GB, print both numbers and stop. Do
not install and hope: a machine short of memory here fails during the first conversion rather
than at startup. If `dig +short` prints nothing, print that and stop. If swap is under 4096 MB,
say so and carry on; that one is guidance rather than a floor.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/onlyoffice /srv/onlyoffice/backups
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/onlyoffice/data /srv/onlyoffice/lib /srv/onlyoffice/logs
ls -la /srv/onlyoffice
```

Assert: `ls -la` shows `backups`, `data`, `lib` and `logs`, all owned by the login user. The
container starts as root and chowns the last three to the `ds` account it runs its services
under, so do not chown them again. Nothing of the user's is stored there: runtime config,
a cache of what is open in an editor, and logs.

## 3. Secrets

One secret: every request between this server and the application using it is signed with it.
Generate it on the server. Do not print it, do not repeat it in your summary, and do not put it
in any log line. Hex rather than base64, because the user pastes this value into a web form in
another application and hex survives that trip without escaping.

```bash
umask 077
cat > /srv/onlyoffice/.env <<EOF
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/onlyoffice/.env
umask 022
ls -l /srv/onlyoffice/.env
```

Assert: the file exists with mode `-rw-------`. Upstream enables token validation by default
and, with this variable unset, invents a fresh random secret at every container start, so every
integration breaks quietly on the next restart. That is the only reason this file exists. Tell
the user they can read it later with `sudo grep JWT_SECRET /srv/onlyoffice/.env`, and that step
7 needs it.

## 4. compose.yml

```bash
cat > /srv/onlyoffice/compose.yml <<'EOF'
# ONLYOFFICE Docs · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   docker install ..... https://helpcenter.onlyoffice.com/docs/installation/docs-community-install-docker.aspx
#   system requirements  https://helpcenter.onlyoffice.com/docs/installation/docs-community-sys-reqs-docker.aspx
#   image reference .... https://github.com/ONLYOFFICE/Docker-DocumentServer/blob/master/README.md
#   entrypoint ......... https://github.com/ONLYOFFICE/Docker-DocumentServer/blob/master/run-document-server.sh
#
# One service, and there is no second one hiding inside it. Older images carried
# their own PostgreSQL and RabbitMQ; the 9.4.0 change log records both
# dependencies removed after the back-end was consolidated into a single
# process, and the published 9.4.0 image declares no database directory among
# its volumes. So there is no database to operate and nothing to dump.
#
# The three mounted directories are state this container writes: its runtime
# configuration, a cache of the documents open in an editor right now, and
# logs. Your documents are in none of them: they live in whichever application
# hands them to this server.
#
# Tag and digest were read from the registry on 2026-08-07; the image publishes
# amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  documentserver:
    image: onlyoffice/documentserver:9.4.0@sha256:e3da62a847b9a5d51a11f73cfea1d9c13c3be3809614490d4edddcf01dcf919b
    container_name: onlyoffice-documentserver
    restart: unless-stopped
    env_file: /srv/onlyoffice/.env
    environment:
      # Token validation is on by default, and with no secret set the
      # entrypoint invents a random one at every start, which silently breaks
      # every integration on restart. The secret arrives from .env instead.
      JWT_ENABLED: "true"
    volumes:
      - /srv/onlyoffice/data:/var/www/onlyoffice/Data
      - /srv/onlyoffice/lib:/var/lib/onlyoffice
      - /srv/onlyoffice/logs:/var/log/onlyoffice
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8157.
      - "127.0.0.1:8157:80"
    healthcheck:
      # /healthcheck answers 200 with the body `false` when a component is
      # down, so the status code alone is not enough to test.
      test: ["CMD-SHELL", "curl -fsS http://localhost/healthcheck | grep -q true"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s
    # SIGTERM runs the shutdown script, which needs time to finish anything
    # mid-conversion. Upstream's own compose file allows the same 60 seconds.
    stop_grace_period: 60s
EOF
cd /srv/onlyoffice && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container listens on plain http port 80 inside,
published only on 127.0.0.1:8157. Its own 443 is never published: Caddy terminates TLS.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-onlyoffice
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# ONLYOFFICE Docs · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://helpcenter.onlyoffice.com/docs/installation/docs-community-install-docker.aspx and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# the address you type into the application that uses this editor, and it has
# to be reachable from your users' browsers and from that application's own
# server, because both talk to it.

<DOMAIN> {
	# The editor ships tens of megabytes of JavaScript. The container
	# pre-compresses its own static bundles, so this mostly covers the API
	# traffic on top of them.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		-Server
	}

	# There is deliberately no X-Frame-Options and no frame-ancestors rule.
	# This whole product is an iframe: the application that owns the document
	# embeds the editor in its own page, and a frame-blocking header would
	# leave the user looking at a blank box. The shared token secret, not the
	# browser, is what keeps strangers out.

	# reverse_proxy sets X-Forwarded-Proto and X-Forwarded-Host on the way
	# through, which is how the editor builds https URLs while speaking plain
	# http here, and it upgrades WebSocket connections without extra
	# configuration. Co-editing is WebSockets. 8157 is the loopback port
	# compose publishes on this host; it is not open in the firewall.
	reverse_proxy 127.0.0.1:8157
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-onlyoffice, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3. 8157 stays closed: it is bound to 127.0.0.1 and Caddy reaches it over loopback.
Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no
rule mentioning 8157.

## 7. Start and verify

The image is over a gigabyte compressed, so the pull takes minutes, and the first start
regenerates the font list before the editors answer.

```bash
cd /srv/onlyoffice
docker compose pull
docker compose up -d
for i in $(seq 1 40); do body=$(curl -sS https://<DOMAIN>/healthcheck || true); echo "$i $body"; [ "$body" = "true" ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/welcome/
curl -sS https://<DOMAIN>/welcome/ | grep -c 'ONLYOFFICE Docs Community Edition installed'
curl -sS -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{"async":false,"filetype":"docx","key":"selfhostcheck","outputtype":"pdf","url":"https://example.com/none.docx"}' https://<DOMAIN>/converter
```

Assert, all four, and print what you received for each. The loop ends printing `true`, the
answer upstream documents for editors that are ready. The welcome page returns `200`. The grep
prints at least `1`. The unsigned conversion request prints `{"error":-8}`, upstream's
documented code for an invalid token, and that is the security assert here: it proves the
server refuses work not signed with the secret from step 3. If any of the four misses, stop,
run `docker compose logs --tail 40 documentserver`, and name the likely earlier step. A `502`
from Caddy in the first minutes means the container is still starting; anything other than `-8`
from the last call means step 3 or step 4 did not deliver the secret. A running container is
not success.

The first screen is https://<DOMAIN>/welcome/, whose heading reads
`ONLYOFFICE Docs Community Edition installed`. The bare https://<DOMAIN>/ redirects there.

STOP: tell the user nothing is editing a document yet, hand them these four steps, and wait.
Do not continue until they confirm, or say they will connect it later.

  1. In Nextcloud, open Apps and install the app named `ONLYOFFICE`.
  2. Open the Nextcloud admin page at `/settings/admin/onlyoffice`.
  3. Put `https://<DOMAIN>/` in the Document Editing Service address field.
  4. Read the secret with `sudo grep JWT_SECRET /srv/onlyoffice/.env`, paste it into the
     Secret key field on that same page, and save.

The connector refuses the address until the secret matches on both sides, the same check the
last curl above failed on purpose.

## 8. First backup and restore

One archive, and it is small, because the documents are somewhere else. The irreplaceable
part is the secret: change it and every application pointed at this server stops opening
documents until the new value is pasted into its settings too.

```bash
cd /srv/onlyoffice
sudo tar -czf /srv/onlyoffice/backups/onlyoffice-config-$(date +%F).tar.gz -C /srv/onlyoffice compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/onlyoffice/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped. `lib` and
`logs` are excluded on purpose: a cache of open documents and a pile of logs are not worth
restoring. A backup on the same disk as the data is not a backup, so run this from the user's
machine, not the server:

```bash
mkdir -p ~/backups/onlyoffice
scp vps:/srv/onlyoffice/backups/*.tar.gz ~/backups/onlyoffice/
```

To restore on a fresh box: recreate the directories as in step 2, untar the archive into
/srv/onlyoffice, put the `Caddyfile` member back at /etc/caddy, reload Caddy, then
`docker compose up -d` and re-run step 7's health check. Tell the user that is the whole
disaster plan, and that the member that matters is `.env`.

## 9. Updating later

New versions are listed at https://github.com/ONLYOFFICE/DocumentServer/releases. Take the
backup first, then edit the image line in /srv/onlyoffice/compose.yml to the new tag and its
digest:

```bash
cd /srv/onlyoffice
docker compose pull
docker compose up -d
docker compose logs --tail 30 documentserver
```

Watch that log until it settles, then re-run step 7's four asserts before calling the update
done. A major version changes the editor bundle the connected application loads, so open one
real document afterwards too.

## 10. What will probably go wrong

Nothing will answer for several minutes and it will look broken. I pulled the image, ran
`docker compose up -d`, opened the site, and got a Caddy `502` for long enough that I went back
and re-read the compose file for a mistake that was not there. The container was fine: it was
generating its font list and bringing a stack of services up under supervisord, and
`/healthcheck` says nothing useful until that finishes. The health check in compose.yml waits
three minutes before it starts judging, and that number is needed. Let the loop in step 7 run
all forty attempts before concluding anything, and read
`docker compose logs --tail 40 documentserver` rather than the browser.

## 11. Out of scope

- Do not set `LETS_ENCRYPT_DOMAIN` or `LETS_ENCRYPT_MAIL`. The container can request its own
  certificate, and on this box that would be a second thing fighting Caddy for port 443.
- Do not set `ALLOW_PRIVATE_IP_ADDRESS` or `USE_UNAUTHORIZED_STORAGE`. They let this server
  fetch documents from private addresses and from hosts with bad certificates, which turns a
  document editor into a tool for reaching things it should not reach.
- Do not enable the bundled example application with `EXAMPLE_ENABLED`. It is an
  unauthenticated file upload page, disabled by default for that reason.
- Do not install Nextcloud here. This prompt installs the editor; the application in front of
  it is a separate install.
