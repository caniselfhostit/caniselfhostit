You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install SiYuan 3.7.3 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things to the user before anything installs, because together they decide whether they
want this at all. SiYuan is the outliner shape: blocks, block references, two-way links and daily
notes, edited in a browser. The container serves that same application over HTTP, and upstream
states plainly that the Docker deployment does not accept desktop or mobile application
connections and supports browsers only. So every device opens the same workspace on this server,
the way a hosted graph works, and the SiYuan apps in the app stores are not part of that.
Second: the sync feature inside SiYuan is not how this install keeps devices together, and they
should not turn it on. There is one workspace on one server, and the kernel gates every sync
provider it offers, S3, WebDAV and a plain local folder alike, behind a paid SiYuan account.

SiYuan needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and arm64.
Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a hostname that does not resolve.

## 2. Layout

Three directories. The workspace belongs to uid 1000, because that is the account the image
entrypoint creates and re-execs the kernel as.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/siyuan /srv/siyuan/backups
sudo install -d -m 700 -o 1000 -g 1000 /srv/siyuan/workspace
ls -la /srv/siyuan
```

Assert: `ls -la` shows `backups` owned by the login user and `workspace` at mode `700` owned by
uid `1000`. The entrypoint chowns that directory to `PUID:PGID` on every start, so setting it now
matches what the container will do. Everything SiYuan keeps lives under `workspace`, and nothing
is written outside /srv/siyuan.

## 3. Secrets

One secret: the lock screen code. It is the only thing standing between this hostname and every
note on it, so treat it the way you would treat a vault password. Generate it on the server. Do
not print it, do not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/siyuan/.env <<EOF
SIYUAN_ACCESS_AUTH_CODE=$(openssl rand -hex 32)
EOF
chmod 600 /srv/siyuan/.env
umask 022
ls -l /srv/siyuan/.env
```

Assert: the file exists with mode `-rw-------`. Upstream documents this value both as an
`--accessAuthCode` flag and as this environment variable, and says the command line wins when
both are set. The env file is used here on purpose: a value on the command line is readable in
every process listing inside the container.

There is no account behind this code. SiYuan has one workspace and one gate, and whoever holds
the code holds the notebook.

## 4. compose.yml

```bash
cat > /srv/siyuan/compose.yml <<'EOF'
# SiYuan · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker deployment .. https://github.com/siyuan-note/siyuan/blob/v3.7.3/README.md
#   image entrypoint ... https://github.com/siyuan-note/siyuan/blob/v3.7.3/kernel/entrypoint.sh
#   kernel http api .... https://github.com/siyuan-note/siyuan/blob/v3.7.3/docs/API.md
#   access gate ........ https://github.com/siyuan-note/siyuan/blob/v3.7.3/kernel/model/session.go
#
# One service and one workspace directory. The `command:` line is not optional:
# from v3.7.0 the kernel is a subcommand tree and the entrypoint pulls
# --workspace out of the arguments, puts it back in front of whatever is left,
# and hands the rest to the kernel, so `serve` has to be written here.
#
# The lock screen code arrives as SIYUAN_ACCESS_AUTH_CODE out of the env file
# instead of on the command line, where every process listing inside the
# container would carry it. Upstream documents both spellings and says the
# command line wins when both are set, so only one is used here.
#
# PUID and PGID are the ids the entrypoint creates a user for and re-execs as,
# and it chowns the mounted workspace to them on every start. SIYUAN_LANG pins
# the interface language so the check in step 7 has one right answer; upstream
# states it is applied on every start-up and overrides the language chosen in
# Settings. Tag and digest read from Docker Hub on 2026-08-06; the image
# publishes amd64, arm64, armv7 and armv8.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  siyuan:
    image: b3log/siyuan:v3.7.3@sha256:908faf8ec55d391d95244982c081edabbaec118552d01fc3dc189d098cc0ffc8
    container_name: siyuan
    restart: unless-stopped
    command: ["serve", "--workspace=/siyuan/workspace"]
    env_file: /srv/siyuan/.env
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "UTC"
      SIYUAN_LANG: "en"
    volumes:
      # conf/, data/ and temp/ appear under here on the first start. Notebooks
      # are folders of .sy JSON files under data/, and anything pasted into a
      # note lands beside them in data/assets.
      - /srv/siyuan/workspace:/siyuan/workspace
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8141.
      - "127.0.0.1:8141:6806"
    healthcheck:
      # Registered without the auth middleware, so it answers whether or not
      # anyone has unlocked the workspace yet.
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:6806/api/system/version"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s
EOF
cd /srv/siyuan && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no database container. The
kernel keeps its index in SQLite inside the workspace, and the notes are JSON files beside it.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-siyuan
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# SiYuan · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/siyuan-note/siyuan/blob/v3.7.3/README.md and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream asks for
# a reverse proxy in front of 6806 that also carries the /ws WebSocket route,
# and asks you not to reach the app through a URL rewrite because the rewrite
# breaks its authentication. Caddy's reverse_proxy upgrades WebSocket
# connections on its own and rewrites nothing, so one directive covers both.

<DOMAIN> {
	# The editor bundle and the kernel's JSON responses compress well. Caddy's
	# default encode matcher covers text, JSON, JavaScript and SVG only, so an
	# image pasted into a note passes through untouched.
	encode zstd gzip

	# SiYuan marks its session cookie HttpOnly, and marks it Secure only when
	# the kernel itself terminated TLS, which here it did not. HSTS is what
	# keeps that cookie off a plaintext request, and every request to this host
	# carries it.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8141 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Caddy applies no
	# default request body limit, so a large attachment upload gets through.
	reverse_proxy 127.0.0.1:8141
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-siyuan, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it on its own, so there is nothing to
schedule.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8141 stays closed because compose binds it to 127.0.0.1 and Caddy is the only thing
that speaks to it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule mentioning 8141 or 6806.

## 7. Start and verify

The kernel builds its index on the first start, so the loop below is doing real work, not waiting
on a socket.

```bash
cd /srv/siyuan
docker compose pull
docker compose up -d
for i in $(seq 1 30); do body=$(curl -sS https://<DOMAIN>/api/system/bootProgress || true); echo "$i $body"; echo "$body" | grep -q '"progress":100' && break; sleep 10; done
curl -sS https://<DOMAIN>/api/system/version; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS -A 'Mozilla/5.0' -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/check-auth | grep -o 'Unlock access'
```

Assert all five, and print what you received for each. The loop ends on a body containing
`"progress":100`. The version call prints `{"code":0,"msg":"","data":"3.7.3"}`, which is the pin
confirming itself. The plain request to the root prints `401`, the kernel's answer to anything
that is not a browser, and the security assert in this block. The same request with a browser
user agent prints `302` to the unlock screen, and the last command prints `Unlock access`, the
button on it. If any of the five misses, stop, run `docker compose logs --tail 40 siyuan`, and say
which earlier step is the likely cause: a container that exits within seconds is step 3, because
the kernel refuses to boot in a container with no access code and exits rather than serving an
open workspace; a `502` from Caddy with a running container is step 5. A running container is not
success.

The first screen at https://<DOMAIN> is that unlock page: a heading reading `workspace`, one
password box whose placeholder reads `Please enter the lock screen password`, and the
`Unlock access` button.

STOP: tell the user to read their code with
`sudo grep SIYUAN_ACCESS_AUTH_CODE /srv/siyuan/.env`, put it in their password manager, open
https://<DOMAIN>, paste it into that box, press `Unlock access`, and wait. Do not continue until
they confirm the editor has loaded. Tell them a few wrong answers add a captcha to that box, so a
paste that lost a character is worth checking before a third try.

## 8. First backup and restore

One archive: the whole workspace, the compose file, the env file and the live Caddy site block.
Take it now, before the user writes anything they would miss.

```bash
cd /srv/siyuan
docker compose stop
sudo tar -czf /srv/siyuan/backups/siyuan-$(date +%F).tar.gz -C /srv/siyuan workspace compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/siyuan/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds, and
the container is stopped on purpose, because the kernel holds a SQLite index open and a database
copied mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/siyuan
scp vps:/srv/siyuan/backups/*.tar.gz ~/backups/siyuan/
```

To restore: `docker compose down`, `sudo rm -rf /srv/siyuan/workspace`, recreate the three
directories as in step 2, untar the archive back into /srv/siyuan, put the Caddy block back if
that is what was lost, then `docker compose up -d`. Tell the user what is inside: every notebook
is a folder of `.sy` JSON files under `workspace/data`, and every image they paste is an ordinary
file in `workspace/data/assets`, so a single lost document can be pulled from the archive with
`tar -xzf` and a copy rather than a full restore.

## 9. Updating later

New versions are listed at https://github.com/siyuan-note/siyuan/releases. Take a backup first,
then edit the image line in /srv/siyuan/compose.yml to the new tag and its digest. The Docker Hub
tag keeps the leading `v`, so release `v3.7.4` is image tag `v3.7.4`.

```bash
cd /srv/siyuan
docker compose pull
docker compose up -d
docker compose logs --tail 30 siyuan
```

SiYuan migrates its own workspace on the way up and can rebuild the index while it does. Watch
that log until it settles, then re-run step 7's boot progress and version checks before calling
the update done.

## 10. What will probably go wrong

The first thing you will do after step 7 is curl the root URL to see whether it is alive, and it
will answer `401` with a JSON body saying `Auth failed [session]`. I read that as a broken proxy
and spent ten minutes in the Caddy config. Nothing was wrong. The kernel sends a redirect to the
unlock page only when the request carries a browser user agent, and answers everything else with
that 401, so a bare `curl` gets the JSON and a browser gets the screen. Look in a browser before
changing anything, and use `/api/system/bootProgress` for a machine-readable answer.

## 11. Out of scope

- Do not set `SIYUAN_ACCESS_AUTH_CODE_BYPASS`. It removes the only gate this install has, and
  upstream added it for people serving a workspace on loopback, not on a public hostname.
- Do not configure sync in the Settings screen. Every provider the kernel offers, S3, WebDAV and
  a plain local folder alike, checks for a paid SiYuan account and switches sync back off when
  that check fails.
- Do not install the desktop or mobile app and point it at this hostname. Upstream lists
  application connections as unsupported for the Docker deployment, and the browser is the client
  here.
- Do not run the kernel's other subcommands against this workspace while the server is up. One
  kernel serves a workspace at a time, and a second process on the same files is how an index
  and a note stop agreeing.
