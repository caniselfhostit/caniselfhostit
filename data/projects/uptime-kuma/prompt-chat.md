This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Uptime Kuma 2.5.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

One thing to sit with before you start: a monitor running on this server cannot tell you when
this server is down. If you have a second machine anywhere, this belongs on that one, and you
should keep a free external check pointed at whichever box ends up hosting it.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP address on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it at your DNS
provider, wait a minute, and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate
for a hostname that does not resolve, and failed attempts count against a rate limit you cannot
see.

## 2. Layout

The image runs as the `node` user, uid 1000, so `data` belongs to 1000 and not to you. The
`db-config.json` written here is what picks the database: with that file in place Uptime Kuma
uses SQLite and never shows you its database setup screen.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/uptime-kuma /srv/uptime-kuma/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/uptime-kuma/data
printf '{\n    "type": "sqlite"\n}\n' | sudo tee /srv/uptime-kuma/data/db-config.json >/dev/null
sudo chown 1000:1000 /srv/uptime-kuma/data/db-config.json
ls -la /srv/uptime-kuma/data
```

You should see: `db-config.json` owned by `1000`, a few dozen bytes.

If you do not: a file owned by `root` means the `chown` line did not run, and the container
will refuse to write beside it. Run that line again on its own. This directory has to be on
local disk: SQLite needs real POSIX file locks, and a network mount corrupts the database
quietly, weeks later.

## 3. Secrets

There is nothing to generate and no `.env` file. Uptime Kuma has one credential, the
administrator account, and you create it in a browser at step 7.

Between the container starting and that account existing, the setup form is open to whoever
reaches your hostname first. Step 7 is written to make that window short, which is why it asks
you to stop reading and go create the account the moment the checks pass.

Nothing in this guide asks you to paste a credential into this chat window. Do not paste the
administrator password, or the output of any command containing it, at any point.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/uptime-kuma/compose.yml <<'EOF'
# Uptime Kuma · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose shape ...... https://github.com/louislam/uptime-kuma/blob/master/compose.yaml
#   install notes ...... https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install
#   reverse proxy ...... https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy
#
# One container. There is no Caddy service here: Prompt Zero already runs Caddy
# under systemd on the host, and a second one in a container would fight it for
# 80 and 443. Upstream pins the floating `2` tag and publishes 3001 on every
# interface; this file pins the exact release and binds to loopback instead. The
# image runs as the node user (uid 1000), hence the ownership in step 2. Tag and
# digest are the 2.5.0 release read from Docker Hub on 2026-08-05, for
# linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  uptime-kuma:
    image: louislam/uptime-kuma:2.5.0@sha256:a8610b3b4c38077922ba51b036691e06887d7cefd91fe620fd3d6d23d03dc240
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      # kuma.db and db-config.json both live here. Local disk only: SQLite
      # needs real POSIX file locks, and a network mount corrupts it quietly.
      - /srv/uptime-kuma/data:/app/data
    ports:
      # Loopback only. The Caddy that Prompt Zero installed on the host is the
      # only thing that can reach this port, and 8091 never enters the firewall.
      - "127.0.0.1:8091:3001"
EOF
cd /srv/uptime-kuma && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/uptime-kuma/compose.yml` and paste the block again in one go.

If you have seen an Uptime Kuma compose file elsewhere with a `caddy` service in it, do not
merge the two. Caddy is already running under systemd on this box, and a container claiming 80
and 443 would fail to start and take every other site with it.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-uptime-kuma
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Uptime Kuma · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# The dashboard is a WebSocket application. Caddy negotiates the upgrade on
	# its own, so there are no Upgrade or Connection headers to set by hand,
	# which is the step every nginx guide spends a paragraph on.
	#
	# 8091 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8091
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-uptime-kuma /etc/caddy/Caddyfile`,
reload, and paste again, checking that the blank line from the second command really landed.
Caddy asks Let's Encrypt for the certificate on the first request to your hostname and renews
it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8091` or `3001`.

If you do not: a rule for either port from an earlier attempt should go, with
`sudo ufw delete allow 3001`. 8091 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it and a firewall rule for it would cover traffic that cannot
arrive.

## 7. Start and verify

The image's own health check allows a three-minute start period, so the first boot is slower
than you expect. That is not a failure.

```bash
cd /srv/uptime-kuma
docker compose pull
docker compose up -d
sleep 60
docker inspect --format '{{.State.Health.Status}}' uptime-kuma
curl -sS https://<DOMAIN>/setup-database-info
echo
curl -sSL https://<DOMAIN>/ | grep -ci 'uptime kuma'
```

You should see: `healthy`, then a line of JSON containing `"needSetup":false`, then a number
greater than `0`.

If you do not: `starting` is not a failure yet, so wait 60 seconds and run the `docker inspect`
line again. `"needSetup":true` means `db-config.json` did not take, so go back to step 2 and
check its ownership. `000` or `502` from curl means the certificate is not there yet, so run
`sudo journalctl -u caddy -n 30`.

A container listed in `docker ps` is not proof of anything. The three checks above are.

Now open https://<DOMAIN> and create your administrator account. Do it before you make coffee:
until it exists, anyone who loads that page can create it instead. Then open the same URL in a
private window.

You should see: a sign-in form, with no create-account fields.

If you do not: a create-account form in the private window means your account was not saved.
Go back and finish it before you do anything else.

## 8. First backup and restore

Do this before you add a monitor, so you find out now whether it works. The stop matters: a
SQLite file copied mid-write is not a backup.

```bash
cd /srv/uptime-kuma
docker compose stop
sudo tar -C /srv/uptime-kuma -czf /srv/uptime-kuma/backups/uptime-kuma-$(date +%F).tar.gz data
docker compose start
ls -lh /srv/uptime-kuma/backups/
```

You should see: one `.tar.gz` file, a few hundred kilobytes on a fresh install.

If you do not: `tar: data: Cannot open` means the `cd` did not happen. A size of `45` bytes
means tar wrote an empty archive because the paths were wrong, so check
`sudo ls /srv/uptime-kuma/data` before you trust it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not on
the server:

```bash
mkdir -p ~/backups/uptime-kuma
scp vps:/srv/uptime-kuma/backups/*.tar.gz ~/backups/uptime-kuma/
```

You should see: one file copied, and the same file listed by `ls -lh ~/backups/uptime-kuma/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake. The
`vps:` prefix only means something on your own machine.

Now prove the restore, because a backup you have never restored is a guess:

```bash
cd /srv/uptime-kuma
docker compose down
sudo rm -rf /srv/uptime-kuma/data
sudo tar -C /srv/uptime-kuma -xzf /srv/uptime-kuma/backups/uptime-kuma-$(date +%F).tar.gz
docker compose up -d
```

You should see: `Created` and `Started`, then after a minute a sign-in page at https://<DOMAIN>
that still accepts your administrator account.

If you do not: a page that has turned back into a create-account form means the archive did not
contain `data/kuma.db`. Stop and go back to the tar step. Those four commands are the whole
disaster plan, and you have now run them once.

Heartbeat history is kept forever by default, so this archive grows with the number of monitors
times how often they check. On a small disk that is the thing that fills it, and the retention
setting in the interface is the lever.

## 9. Updating later

New versions are at https://github.com/louislam/uptime-kuma/releases. Take a backup first, then
edit the `image:` line in /srv/uptime-kuma/compose.yml to the new tag and its digest.

```bash
cd /srv/uptime-kuma
docker compose pull
docker compose up -d
docker compose logs --tail 20 uptime-kuma
```

You should see: `Recreated`, then startup and migration lines, then no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Uptime Kuma
migrates its own database on the next boot, so wait for
`docker inspect --format '{{.State.Health.Status}}' uptime-kuma` to print `healthy` before you
call the update done.

## 10. What will probably go wrong

The alert that never arrives. I set up a monitor, watched it go green, and assumed the whole
thing worked, including the notification channel I had configured and never fired. It had a
typo in the webhook URL, and I found out three weeks later when a real outage produced silence.
Do this on day one: point a second monitor at a hostname that does not exist, wait for it to go
red, and confirm the alert lands on your phone. An untested alert channel is not an alert
channel, and this failure is invisible until the day it matters.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy already runs under systemd here.
- Do not configure MariaDB. `db-config.json` picks SQLite, which is why this is one container.
- Do not configure notification channels while installing. Each is an account or a token
  somewhere else, and you pick those in the interface afterwards.
- Do not publish 3001 on the host or open it in the firewall. Caddy is the only way in.
