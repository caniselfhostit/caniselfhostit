You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install code-server 4.131.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things to the user before anything installs. code-server is VS Code with a browser front
end, and VS Code comes with an integrated terminal, so this hostname becomes a shell on this
server behind one password; everything below treats that password accordingly. And the editor
opens an empty folder: nothing is copied here from their laptop, and there is nothing to browse
until they clone a repository.

code-server needs 1024 MB of RAM available and 10 GB free on /srv. Upstream's stated floor is
1 GB of RAM and 2 CPU cores; the 10 GB is the image, the extensions and whatever the user builds.
The image publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a name that does not resolve.

## 2. Layout

Four directories and one configuration file. The container runs as uid 1000, so three of the four
belong to that uid rather than to the login user.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/code-server /srv/code-server/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/code-server/local /srv/code-server/project
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/code-server/config /srv/code-server/config/code-server
cat > /srv/code-server/config/code-server/config.yaml <<'EOF'
auth: password
disable-telemetry: true
disable-update-check: true
EOF
sudo chown -R 1000:1000 /srv/code-server/config
ls -la /srv/code-server
sudo cat /srv/code-server/config/code-server/config.yaml
```

Assert: `ls -la` shows `local`, `project` and `config` owned by uid `1000`, `backups` owned by
the login user, and the last command prints the three lines above. Upstream writes this file
itself on first start with a random password in it, and refuses to overwrite one that exists.
Writing it first keeps that second credential-shaped string off the disk and turns telemetry off
before a request leaves the box. It carries no `password` line: step 3 supplies that from the
environment, which wins either way.

## 3. Secrets

One secret: the password that stands between the internet and a terminal on this server.
Generate it here. Do not print it, do not repeat it in your summary, and do not put it in any
log line.

```bash
umask 077
cat > /srv/code-server/.env <<EOF
PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/code-server/.env
umask 022
ls -l /srv/code-server/.env
```

Assert: the file exists with mode `-rw-------`. Hex rather than base64, because Docker Compose
reads this same file for interpolation and a `$` in the value would be expanded. Sixty-four hex
characters is 256 bits, which is not overkill on a login that is also a shell.

Two facts worth saying to the user: code-server deletes the variable from its own environment
before starting anything, so the terminal the editor opens does not inherit it, and the login
route refuses more than 2 attempts a minute plus 12 an hour. Then tell them
`grep PASSWORD /srv/code-server/.env` reads the value and that it belongs in their password
manager now.

## 4. compose.yml

```bash
cat > /srv/code-server/compose.yml <<'EOF'
# code-server · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://coder.com/docs/code-server/install
#   faq and config ..... https://coder.com/docs/code-server/FAQ
#   requirements ....... https://coder.com/docs/code-server/requirements
#   release image ...... https://github.com/coder/code-server/blob/v4.131.0/ci/release-image/Dockerfile
#
# One service, and it is a development machine: VS Code's open-source core with
# a browser front end, the terminal it opens, and whatever gets installed from
# inside it. The image runs as uid 1000, the `coder` user baked into it, and
# binds code-server to 0.0.0.0:8080, so the three host directories below are
# owned by 1000. No `user:` line: the entrypoint runs fixuid first.
#
# PASSWORD arrives from /srv/code-server/.env, mode 600. code-server reads it,
# then deletes it from its own environment before starting anything, so the
# integrated terminal never inherits it. Telemetry and the update check are off
# in config/code-server/config.yaml, written before the first start. No Docker
# socket is mounted, deliberately.
#
# Tag and digest read from Docker Hub on 2026-08-06; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  code-server:
    image: codercom/code-server:4.131.0@sha256:3623e6362abdec6258472882b06fdeec9d6ce2ad3fda316b3c5d7ed092b89add
    container_name: code-server
    restart: unless-stopped
    # PASSWORD, and nothing else, generated on this server.
    env_file: /srv/code-server/.env
    volumes:
      # config.yaml lives at config/code-server/config.yaml on the host.
      - /srv/code-server/config:/home/coder/.config
      # Extensions, editor settings and the machine id.
      - /srv/code-server/local:/home/coder/.local
      # The working tree. Empty until the user puts code in it.
      - /srv/code-server/project:/home/coder/project
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8137.
      - "127.0.0.1:8137:8080"
    healthcheck:
      # /healthz needs no authentication and never triggers a heartbeat.
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd /srv/code-server && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no database: settings and
extensions live under `local` and the user's work under `project`.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-code-server
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# code-server · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://coder.com/docs/code-server/guide,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream asks you
# to put a proxy in front of code-server that terminates TLS. This is it, and
# this hostname is the front door to a terminal on this server.

<DOMAIN> {
	# The workbench is tens of megabytes of JavaScript on first load.
	# Caddy's default encode matcher covers text, JSON, JavaScript and SVG
	# only, so a binary file opened in the editor passes through untouched.
	encode zstd gzip

	# code-server sends a Content-Security-Policy of its own and none of
	# these. HSTS is on because every request to this host carries the
	# session cookie for a shell.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8137 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. The editor rides
	# WebSockets, which Caddy upgrades with no extra configuration, and Caddy
	# forwards the original host, which is what code-server checks the
	# Origin header against before accepting that upgrade.
	reverse_proxy 127.0.0.1:8137
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-code-server, reload, and report what it objected to. Caddy requests
the certificate on the first request to the hostname and renews it itself, so nothing is
scheduled here.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3. 8137 stays closed because compose binds it to 127.0.0.1 and Caddy is the only
thing reaching it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp
and 443/udp, and no rule mentioning 8137 or 8080. If a previous run left one, delete it with
`sudo ufw delete allow 8137`.

## 7. Start and verify

```bash
cd /srv/code-server
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/healthz; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/login | grep -o -E '<title>[^<]*</title>|Welcome to code-server|Password was set from .PASSWORD'
```

Assert all four, and print what you received for each. The loop ends printing `200`. The health
response is a small JSON object containing `"lastHeartbeat"`; its `status` reads `expired` on a
fresh instance, which is correct: the heartbeat starts only once a browser holds the editor
open. The bare URL prints `302`, an unauthenticated request sent to the login
page, and that is the security assert here. The last command prints three lines:
`<title>code-server login</title>`, `Welcome to code-server`, and `Password was set from
$PASSWORD`. The third proves step 3's value reached the container, because code-server prints
that sentence only when the password came from the environment.

If the bare URL prints `200` rather than `302`, stop and do not report success: authentication is
off. If the loop never reaches 200, stop, run `docker compose logs --tail 40 code-server`, and
name the likely earlier step: a container that exits at once is usually step 2 leaving a
directory owned by somebody other than uid 1000, and a `502` with a healthy container is step 5.
A running container is not success.

STOP: tell the user to read their password with `grep PASSWORD /srv/code-server/.env`, put it in
their password manager, open https://<DOMAIN>, sign in, and wait. Do not continue until they
confirm they see the editor. The first screen is one card reading `Welcome to code-server` above
`Please log in below.`, with one `PASSWORD` box, a `SUBMIT` button and no username.

Once they confirm:

```bash
curl -sS https://<DOMAIN>/healthz; echo
```

Assert: `status` now reads `alive`. It falls back to `expired` a minute after the last request,
so `alive` here means a browser is holding the editor open right now; if it still reads
`expired`, have the user reload the page and check again. Then tell them the folder on the left
is `/home/coder/project`, that it is empty, and a `git clone` in the editor's terminal fills it.

## 8. First backup and restore

One archive: the editor configuration, the extensions and settings, the working tree, compose.yml,
.env and the live Caddy site block.

```bash
cd /srv/code-server
docker compose stop
sudo tar -czf /srv/code-server/backups/code-server-$(date +%F).tar.gz -C /srv/code-server config local project compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/code-server/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds, and
the container is stopped on purpose because a file the editor is midway through writing is not a
backup.

A backup on the same disk is not a backup. Run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/code-server
scp vps:/srv/code-server/backups/*.tar.gz ~/backups/code-server/
```

To restore: `docker compose down`, remove `config`, `local` and `project` under /srv/code-server,
recreate the four directories as in step 2, untar the archive back into /srv/code-server, put the
Caddy block back if that is what was lost, then `docker compose up -d`. Say the last part plainly:
only those three folders are in the archive, so a toolchain installed inside it is not.

## 9. Updating later

New versions are listed at https://github.com/coder/code-server/releases. The Docker Hub tag drops
the leading `v`, so release `v4.132.0` is tag `4.132.0`. Take the backup first, then edit the
image line in /srv/code-server/compose.yml to the new tag and digest:

```bash
cd /srv/code-server
docker compose pull
docker compose up -d
docker compose logs --tail 30 code-server
```

Extensions and settings survive because they live in `local`, not in the image. Re-run the
`/healthz` and `302` checks from step 7 before calling the update done, and reload the browser
tab: an old workbench talking to a new server looks like a failed update.

## 10. What will probably go wrong

The health endpoint told me the install was dead when it was fine. I ran the `/healthz` check in
step 7, read `"status":"expired"` with `"lastHeartbeat":0`, and spent several minutes in the
container logs looking for a crash that had not happened. That field reports whether a browser is
holding the editor open, and on a server nobody has signed into the honest answer is no. The
`200` is the assert; the word in the body is not, and it flips to `alive` seconds after the
first sign-in.

## 11. Out of scope

- Do not repoint the extension gallery at Microsoft's Visual Studio Marketplace. Their terms
  restrict those offerings to Visual Studio products and services; this build uses Open VSX.
- Do not mount the Docker socket into this container. That turns the editor's terminal into root
  on the host, a different install with a threat model this prompt does not cover.
- Do not set `proxy-domain` or add a wildcard DNS record for the port proxy. A dev server is
  already reachable at https://<DOMAIN>/proxy/3000/.
- Do not `apt-get install` toolchains inside the running container. Anything added that way is
  gone at the next `docker compose pull`.
