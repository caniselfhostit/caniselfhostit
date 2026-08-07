This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing ONLYOFFICE Docs 9.4.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1, because it decides whether you want the install at all. ONLYOFFICE
Docs is the editing engine, not a place to keep files. On its own it edits nothing: it opens,
renders and saves documents that another application hands to it. It is worth installing if you
already run Nextcloud, or another application with an ONLYOFFICE connector, or are about to. If
you have none of those, what you will have at the end is a correctly running server with
nothing pointed at it.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
free -m | awk '/^Swap:/ {print $2 " MB swap"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `40` G free, `amd64` or `arm64`, and
your server's IP on the last line. Upstream asks for 4 GB of swap as well.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that
does not resolve and failed attempts count against a rate limit you cannot see. Under 4096 MB
of memory, stop and resize the box: this is an office suite compiled to run on a server, and
the machine that is short of memory does not fail at startup, it fails in the middle of the
first document conversion, which looks like a bug in the editor rather than a bug in the
shopping. That hostname also has to be reachable from the other application's server, not only
from your browser, so a split-horizon DNS setup that answers differently inside your network
will bite you at step 7.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/onlyoffice /srv/onlyoffice/backups
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/onlyoffice/data /srv/onlyoffice/lib /srv/onlyoffice/logs
ls -la /srv/onlyoffice
```

You should see: four directories, `backups`, `data`, `lib` and `logs`, all owned by you.

If you do not: `Permission denied` means you are not in the sudoers group, which Prompt Zero
set up. Do not chown these again after the first start. The container runs as root and chowns
`data`, `lib` and `logs` to its own internal account, and nothing of yours is stored in them
anyway: they hold the runtime configuration it writes for itself, a cache of the documents open
in an editor at that moment, and logs.

## 3. Secrets

One secret. Every request between this server and the application that uses it is signed with
it, and it is generated here, on the server, straight into a file only you can read. Hex rather
than base64, because you will paste this value into a web form in another application and hex
survives that trip without escaping.

```bash
umask 077
cat > /srv/onlyoffice/.env <<EOF
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/onlyoffice/.env
umask 022
ls -l /srv/onlyoffice/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/onlyoffice/.env` and
carry on. If the file already existed from an earlier attempt, this block has now replaced the
secret, and any application already configured against the old one will stop opening documents
until you paste the new value into its settings too.

Do not paste that file, the secret, or any output containing it into this chat window. Upstream
turns token validation on by default and, when this variable is unset, invents a fresh random
secret at every container start, which is why the file exists at all: without it every restart
silently breaks the integration. Read it once at step 7 with
`sudo grep JWT_SECRET /srv/onlyoffice/.env`, put it in your password manager, and keep it out
of anything you are typing to a chatbot.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/onlyoffice/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/onlyoffice/compose.yml` and paste again in one go. The container listens on plain
http port 80 inside and is published only on 127.0.0.1:8157; its own port 443 is never
published, because Caddy on the host terminates TLS.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-onlyoffice /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and
not the other. Caddy requests the certificate on the first request and renews it on its own, so
there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8157`.

If you do not: delete anything for `8157` with `sudo ufw delete allow 8157`. That port is bound
to 127.0.0.1 by the compose file, so Caddy reaches it over loopback and nothing else can reach
it at all. 80/tcp is there to redirect to HTTPS and to answer the ACME challenge, 443/tcp is
the only way in, and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a
different problem: Prompt Zero left this firewall enabled, so something has turned it off
since, and `sudo ufw enable` puts it back before you go any further.

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

You should see, in order: the loop reaching `true`, then `200`, then a count of at least `1`,
then `{"error":-8}`.

If you do not: the `-8` is the one worth understanding. It is upstream's documented code for an
invalid token, so a conversion request that arrives with no signature at all is refused, which
means the secret from step 3 is in force. Anything else there, and in particular a
`{"error":0}` or a real conversion result, means token validation is off and this server
will convert documents for anyone who finds it. Stop and check that `.env` reached the
container. If the loop never reaches `true`, give it the full forty attempts before doing
anything: an empty reply or a `502` in the first few minutes is a container that is still
starting, not a broken install. After that, `docker compose logs --tail 40 documentserver` is
the place to look.

The first screen is https://<DOMAIN>/welcome/, whose heading reads
`ONLYOFFICE Docs Community Edition installed`. https://<DOMAIN>/ redirects there. A running
container is not success; those four asserts are.

Now read the secret once and put it in your password manager, because the next step needs it:

```bash
sudo grep JWT_SECRET /srv/onlyoffice/.env
```

You should see: one line, the variable name followed by 64 characters of hex. Do not paste that
line into this chat.

Nothing is editing a document yet. To connect it to Nextcloud: open Apps in Nextcloud and
install the app named `ONLYOFFICE`, go to the admin page at `/settings/admin/onlyoffice`, put
`https://<DOMAIN>/` in the Document Editing Service address field, paste the secret into the
Secret key field on that same page, and save. The connector refuses the address until the
secret matches on both sides, which is the same check the last curl above failed on purpose.

## 8. First backup and restore

One archive, and it is small, because the documents are somewhere else. The irreplaceable part
is the secret: change it and every application already pointed at this server stops opening
documents until the new value is pasted into its settings too.

```bash
cd /srv/onlyoffice
sudo tar -czf /srv/onlyoffice/backups/onlyoffice-config-$(date +%F).tar.gz -C /srv/onlyoffice compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/onlyoffice/backups/
```

You should see: one file, a few kilobytes on a fresh install. Nothing goes offline.

If you do not: run `tar -tzf` on the finished archive to list what is inside it. `compose.yml`,
`.env`, `data/` and `Caddyfile` should all be there, and if `Caddyfile` is missing then tar
never reached the second `-C` because the first path was wrong. `lib` and `logs` are excluded
on purpose: a cache of open documents and a pile of logs are not worth restoring.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/onlyoffice
scp vps:/srv/onlyoffice/backups/*.tar.gz ~/backups/onlyoffice/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/onlyoffice/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while nothing is at stake:

```bash
cd /srv/onlyoffice
docker compose down
sudo rm -rf /srv/onlyoffice/data /srv/onlyoffice/lib
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/onlyoffice/data /srv/onlyoffice/lib
sudo tar -xzf /srv/onlyoffice/backups/onlyoffice-config-$(date +%F).tar.gz -C /srv/onlyoffice --exclude Caddyfile
docker compose up -d
for i in $(seq 1 40); do body=$(curl -sS https://<DOMAIN>/healthcheck || true); echo "$i $body"; [ "$body" = "true" ] && break; sleep 15; done
```

You should see: the loop reaching `true` again, which means a directory tree that was deleted
and rebuilt is serving editors again.

If you do not: the archive also contains a `Caddyfile` member, and `--exclude Caddyfile` keeps
it out of /srv/onlyoffice where it would do nothing. On a genuinely fresh box you would put
that member at /etc/caddy/Caddyfile instead, with `<DOMAIN>` already replaced, and reload
Caddy. That is the whole disaster plan: four files back in place and one
`docker compose up -d`. The member that matters is `.env`, because losing it means every
connected application has to be reconfigured with a new secret.

## 9. Updating later

New versions are listed at https://github.com/ONLYOFFICE/DocumentServer/releases. Take the
backup first, then edit the `image:` line in /srv/onlyoffice/compose.yml to the new tag and its
digest.

```bash
cd /srv/onlyoffice
docker compose pull
docker compose up -d
docker compose logs --tail 30 documentserver
```

You should see: the start-up sequence, then no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
four asserts from step 7 before you call the update done, and open one real document in the
connected application as well, because a major version changes the editor bundle that
application loads and a server that answers `true` can still be serving a bundle the connector
does not understand.

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
  it is a separate install with its own hostname.
