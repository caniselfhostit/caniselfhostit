This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing SiYuan 3.7.3 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Two things to know before step 1, because together they decide whether you want this at all.
SiYuan is the outliner shape: blocks, block references, two-way links and daily notes, edited in
a browser. The container serves that same application over HTTP, and upstream states plainly that
the Docker deployment does not accept desktop or mobile application connections and supports
browsers only. So every device you use opens the same workspace on this server, the way a hosted
graph works, and the SiYuan apps in the app stores are not part of that. Second: the sync feature
inside SiYuan is not how this install keeps your devices together, and you should not turn it on.
There is one workspace on one server, and the kernel gates every sync provider it offers, S3,
WebDAV and a plain local folder alike, behind a paid SiYuan account.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for this
hostname, because the certificate would be issued to somebody else's edge and the editor's
WebSocket has to reach your box.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/siyuan /srv/siyuan/backups
sudo install -d -m 700 -o 1000 -g 1000 /srv/siyuan/workspace
ls -la /srv/siyuan
```

You should see: `backups` owned by you, and `workspace` at mode `drwx------` owned by uid `1000`,
which may print as a bare number if no account on the box has that id.

If you do not: leave `workspace` owned by 1000 on purpose. The image creates a user with that id
and runs the kernel as it, and it chowns this directory to that id on every start, so setting it
now matches what the container will do rather than fighting it. Everything SiYuan keeps lives
under `workspace`, and nothing is written outside /srv/siyuan.

## 3. Secrets

One secret: the lock screen code. It is the only thing between this hostname and every note on
it, so treat it the way you would treat a vault password. It is generated here, on the server,
straight into a file only you can read.

```bash
umask 077
cat > /srv/siyuan/.env <<EOF
SIYUAN_ACCESS_AUTH_CODE=$(openssl rand -hex 32)
EOF
chmod 600 /srv/siyuan/.env
umask 022
ls -l /srv/siyuan/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/siyuan/.env` and carry on.
If the file already existed from an earlier attempt, this block has now replaced the code, which
is fine before the container has ever run and confusing afterwards: the code the container is
using is whatever it read at start-up, so restart it after any change here.

Read it once with `sudo grep SIYUAN_ACCESS_AUTH_CODE /srv/siyuan/.env` and put it in your
password manager. There is no account behind it and no reset link: SiYuan has one workspace and
one gate, and whoever holds the code holds the notebook.

Do not paste that file, the code, or any command output containing it into this chat window. The
agent path never sees the value at all; this path will hand it to a third party unless you make a
point of not doing that.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/siyuan/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/siyuan/compose.yml` and paste again in one go. There is no database container here,
and that is correct rather than something missing: the kernel keeps its index in SQLite inside
the workspace, and the notes are JSON files beside it.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-siyuan /etc/caddy/Caddyfile`, reload, and
paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the other.
Caddy requests the certificate on the first request to the hostname and renews it on its own, so
there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8141` or `6806`.

If you do not: delete anything for `8141` or `6806` with `sudo ufw delete allow 8141`. 8141 is
bound to 127.0.0.1 by the compose file, so nothing outside the box can reach it and no rule is
needed. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem:
Prompt Zero left this firewall enabled, so something has turned it off since, and `sudo ufw
enable` puts it back before you go any further.

## 7. Start and verify

The kernel builds its index on the first start, so the loop below is doing real work, not waiting
on a socket. It can take a couple of minutes on a small box.

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

You should see, in order: the loop ending on a body containing `"progress":100`, then
`{"code":0,"msg":"","data":"3.7.3"}`, then `401`, then `302`, then `Unlock access`.

If you do not: the `401` is the one worth understanding, because it looks like a failure and is
not. The kernel redirects to the unlock page only when the request carries a browser user agent,
and answers everything else with that 401, so a bare `curl` gets JSON and a browser gets the
screen. Seeing it means the gate is closed, which is the point of step 3. A container that exits
within seconds is step 3 done wrong: the kernel refuses to boot inside a container with no access
code and exits rather than serving an open workspace, and `docker compose logs --tail 40 siyuan`
says so in one line. A `502` from Caddy with a running container is step 5. If the loop never
reaches `"progress":100`, give it another round before you touch anything, then read the same
log. A running container is not success.

The first screen at https://<DOMAIN> is that unlock page: a heading reading `workspace`, one
password box whose placeholder reads `Please enter the lock screen password`, and the
`Unlock access` button. Open it now, paste in the code you saved in step 3, and press
`Unlock access`. A few wrong answers add a captcha to the box, so a paste that lost a character
is worth checking before a third try.

You should see, after unlocking: the editor, with a notebook list down the left side and an empty
document area.

## 8. First backup and restore

One archive: the whole workspace, the compose file, the env file and the live Caddy site block.
Take it now, before you write anything you would miss.

```bash
cd /srv/siyuan
docker compose stop
sudo tar -czf /srv/siyuan/backups/siyuan-$(date +%F).tar.gz -C /srv/siyuan workspace compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/siyuan/backups/
```

You should see: one file, a few megabytes on a fresh install. Downtime is about ten seconds, and
the container is stopped on purpose, because the kernel holds a SQLite index open and a database
copied mid-write is not a backup.

If you do not: an archive of a few hundred bytes means `tar` found nothing, which usually means
the container has never successfully started and `workspace` is still empty. Go back to step 7.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/siyuan
scp vps:/srv/siyuan/backups/*.tar.gz ~/backups/siyuan/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/siyuan/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty notebook:

```bash
cd /srv/siyuan
docker compose down
sudo rm -rf /srv/siyuan/workspace
sudo install -d -m 700 -o 1000 -g 1000 /srv/siyuan/workspace
sudo tar -xzf /srv/siyuan/backups/siyuan-$(date +%F).tar.gz -C /srv/siyuan workspace
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/api/system/bootProgress; echo
```

You should see: `"progress":100` again, and the same code still unlocking the same workspace in a
browser.

If you do not: check that the untar put `conf` and `data` back under /srv/siyuan/workspace. What
is in there is worth knowing before you need it: every notebook is a folder of `.sy` JSON files
under `workspace/data`, and every image you paste is an ordinary file in `workspace/data/assets`,
so a single lost document can be pulled from the archive with `tar -xzf` and a copy rather than a
full restore.

## 9. Updating later

New versions are listed at https://github.com/siyuan-note/siyuan/releases. Take a backup first,
then edit the `image:` line in /srv/siyuan/compose.yml to the new tag and its digest. The Docker
Hub tag keeps the leading `v`, so release `v3.7.4` is image tag `v3.7.4`.

```bash
cd /srv/siyuan
docker compose pull
docker compose up -d
docker compose logs --tail 30 siyuan
```

You should see: the boot banner, then index and workspace messages, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
boot progress and version checks from step 7 before you call the update done, and open a real
note as well, because a kernel that reports `"progress":100` can still be rebuilding an index
that a search will miss.

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
