This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing code-server 4.131.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. code-server is VS Code with a browser front end, and VS Code comes with
an integrated terminal, so `<DOMAIN>` becomes a shell on this server behind one password. Every
step below treats that password as the whole security boundary, because it is. The editor also
opens an empty folder: nothing is copied here from your laptop, and there is nothing to browse
until you clone a repository into it.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line. Upstream's stated floor is 1 GB of RAM and 2 CPU cores; the 10 GB
covers the image, the extensions and whatever you build.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 10 GB free is worth
taking seriously here rather than rounding down: the image alone is several hundred megabytes
compressed, and a dependency folder in a real project is often larger than the editor.

## 2. Layout

Four directories and one configuration file. The container runs as uid 1000, the `coder` user
baked into the image, so three of the four belong to that uid rather than to you.

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

You should see: `local`, `project` and `config` owned by `1000`, `backups` owned by you, and the
three config lines printed back.

If you do not: if `ls` shows your own username on `local` or `project`, the `chown` did not take,
and the container will fail to write its settings on first start. Re-run the second `install`
line. Upstream writes that config file itself on first start, with a random password inside it,
and refuses to overwrite one that already exists. Writing it first keeps that second
credential-shaped string off your disk and turns telemetry off before a request leaves the box.
There is deliberately no `password` line in it: step 3 supplies that from the environment, and
the environment wins over the file either way.

## 3. Secrets

One secret, generated on the server, and it stands between the internet and a terminal on this
machine.

```bash
umask 077
cat > /srv/code-server/.env <<EOF
PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/code-server/.env
umask 022
ls -l /srv/code-server/.env
```

You should see: mode `-rw-------` and your own username twice. Read the value once with
`grep PASSWORD /srv/code-server/.env` and put it in your password manager. Hex rather than
base64, because Docker Compose reads this same file for variable interpolation and a `$` inside
the value would be expanded. Sixty-four hex characters is 256 bits, which is not overkill on a
login that is also a shell.

Do not paste that file, the password, or any command output containing it into this chat window.
The agent path never sees the value; this path will hand it to a third party unless you keep it
out yourself.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/code-server/.env` and carry
on. If the file already existed from an earlier attempt, this block has now replaced the
password, and the container will accept only the new one after the next restart.

Two things worth knowing about how the value travels. code-server deletes the variable from its
own environment before it starts anything else, so the terminal the editor opens does not inherit
it. And the login route refuses more than 2 attempts a minute plus 12 an hour, so a wrong
password three times in a row makes the next attempt fail even when you finally get it right;
wait a minute and try again.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/code-server/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/code-server/compose.yml` and paste again in one go. There is no database here. The
editor keeps settings and extensions under `local` and your work under `project`, and both are
ordinary files on this disk.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-code-server /etc/caddy/Caddyfile`, reload,
and paste again. The WebSocket question is the one people ask here and the answer is that there
is nothing to do: Caddy performs the upgrade by default, and it forwards the original host, which
is the header code-server compares the browser's Origin against before accepting the connection.
A proxy that rewrote the host would break the editor with a `Forbidden` on the websocket and a
blank workbench, which is why this block does not touch it.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8137` or `8080`.

If you do not: delete anything for `8137` with `sudo ufw delete allow 8137`. 8137 is bound to
127.0.0.1 by the compose file, so a firewall rule for it would be opening a terminal to the
internet without the certificate or the proxy in front of it. 80/tcp answers the ACME challenge
and redirects to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The first `docker compose pull` moves several hundred megabytes, so give it a minute.

```bash
cd /srv/code-server
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/healthz; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/login | grep -o -E '<title>[^<]*</title>|Welcome to code-server|Password was set from .PASSWORD'
```

You should see, in order: the loop reaching `200`; a small JSON object containing
`"lastHeartbeat"`; then `302`; then three lines reading `<title>code-server login</title>`,
`Welcome to code-server`, and `Password was set from $PASSWORD`.

If you do not: two of those deserve explanation. The health object's `status` field reads
`expired` on a brand-new install, and that is correct rather than broken, because the field
reports whether a browser is currently holding the editor open. And the `302` is the security
check in this step: an unauthenticated request being redirected to the login page. If that line
prints `200`, authentication is not on and you should stop here rather than open the hostname in
a browser. The third of the three grep lines is the other one that matters: code-server prints
`Password was set from $PASSWORD` only when the password came from the environment, so seeing it
proves step 3's value reached the container. If the loop never reaches `200`, run
`docker compose logs --tail 40 code-server`; a container that exits immediately is almost always
step 2 leaving a directory owned by somebody other than uid 1000.

Now open https://<DOMAIN> in a browser and sign in with the password from step 3. The first
screen is one card reading `Welcome to code-server` above `Please log in below.`, with a single
`PASSWORD` box, a `SUBMIT` button and no username field.

```bash
curl -sS https://<DOMAIN>/healthz; echo
```

You should see: `status` now reading `alive`.

If you do not: the field falls back to `expired` a minute after the last request, so `expired`
here means the browser tab is no longer open, or was never really connected. Reload the editor
and run the command again. A running container is
not success, and neither is a login page: `alive` is a real session holding a real workbench. Once
you are in, the folder on the left is `/home/coder/project` and it is empty. A `git clone` in the
editor's own terminal is how it fills.

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

You should see: one file, a few megabytes on a fresh install. Downtime is about five seconds, and
the container is stopped on purpose because a file the editor is midway through writing is not a
backup.

If you do not: an archive of a few hundred bytes means the `tar` ran before the directories had
anything in them, which is harmless today and useless tomorrow. Once you have installed
extensions and cloned a repository, this archive grows quickly, and the folders that drive that
are `local` and any dependency directory inside `project`. Exclude `node_modules` and build
output from later runs and let the package manager rebuild them.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/code-server
scp vps:/srv/code-server/backups/*.tar.gz ~/backups/code-server/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/code-server/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty folder:

```bash
cd /srv/code-server
docker compose down
sudo rm -rf /srv/code-server/config /srv/code-server/local /srv/code-server/project
sudo tar -xzf /srv/code-server/backups/code-server-$(date +%F).tar.gz -C /srv/code-server config local project
sudo chown -R 1000:1000 /srv/code-server/config /srv/code-server/local /srv/code-server/project
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `302`, which means the editor came back with its configuration and its password
intact.

If you do not: a `502` means the container did not start, and the usual cause is the `chown` line
being skipped, because `tar` restores the uids it recorded and a mismatch leaves the container
unable to write. Note what is not in that archive: only those three folders and the two files.
Anything you installed into the container itself with `apt-get` is not in there and never was,
which is the honest limit of this backup and the reason a real toolchain belongs in your
project's own configuration.

## 9. Updating later

New versions are listed at https://github.com/coder/code-server/releases. The Docker Hub tag
drops the leading `v`, so release `v4.132.0` is image tag `4.132.0`. Take the backup first, then
edit the `image:` line in /srv/code-server/compose.yml to the new tag and its digest.

```bash
cd /srv/code-server
docker compose pull
docker compose up -d
docker compose logs --tail 30 code-server
```

You should see: the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Your extensions
and settings survive an update because they live in `local` on this disk rather than in the
image. Re-run the `/healthz` and `302` checks from step 7 before you call the update done, and
reload the browser tab as well: an old workbench talking to a new server reconnects badly and
looks like a failed update when it is a stale tab.

## 10. What will probably go wrong

The health endpoint told me the install was dead when it was fine. I ran the `/healthz` check in
step 7, read `"status":"expired"` with `"lastHeartbeat":0`, and spent several minutes in the
container logs looking for a crash that had not happened. That field reports whether a browser is
holding the editor open, and on a server nobody has signed into the honest answer is no. The
`200` is the assert; the word in the body is not, and it flips to `alive` seconds after the first
sign-in.

## 11. Out of scope

- Do not repoint the extension gallery at Microsoft's Visual Studio Marketplace. Their terms
  restrict those offerings to Visual Studio products and services; this build uses Open VSX.
- Do not mount the Docker socket into this container. That turns the editor's terminal into root
  on the host, a different install with a threat model this prompt does not cover.
- Do not set `proxy-domain` or add a wildcard DNS record for the port proxy. A dev server is
  already reachable at https://<DOMAIN>/proxy/3000/.
- Do not `apt-get install` toolchains inside the running container. Anything added that way is
  gone at the next `docker compose pull`.
