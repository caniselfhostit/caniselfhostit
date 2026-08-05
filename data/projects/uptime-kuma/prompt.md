You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Uptime Kuma 2.5.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Uptime Kuma needs 512 MB of RAM available and
5 GB free on /srv, and the 2.5.0 image covers amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If RAM is under 512 MB or disk under 5 GB, print both numbers and stop. If `dig +short` prints
nothing, print that and stop: Caddy cannot certify a hostname that does not resolve.

One thing to say out loud to the user before installing a monitor on the machine it will be
monitoring: this box cannot tell them it is down. If they have another server, this belongs on
the other one.

## 2. Layout

The image runs as the `node` user, uid 1000, so the data directory belongs to 1000 and not to
the login user. `db-config.json` is written now, before the first boot, because it is what
picks the database: with that file present Uptime Kuma uses SQLite and skips its database
setup screen entirely.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/uptime-kuma /srv/uptime-kuma/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/uptime-kuma/data
printf '{\n    "type": "sqlite"\n}\n' | sudo tee /srv/uptime-kuma/data/db-config.json >/dev/null
sudo chown 1000:1000 /srv/uptime-kuma/data/db-config.json
ls -la /srv/uptime-kuma/data
```

Assert: `ls -la` shows `db-config.json` owned by `1000`. Nothing is written outside
/srv/uptime-kuma, and the data directory is on local disk, because SQLite on a network mount
corrupts quietly and weeks later.

## 3. Secrets

No secret is generated for this install, and there is no `.env` file. Uptime Kuma's only
credential is the administrator account, and it is created in a browser at step 7 rather than
written into a file here. That is why this block has nothing to run.

Say one thing to the user now: between the container starting and them creating that account,
the setup screen is open to whoever reaches the hostname first. Step 7 is written to make that
window as short as it can be, and it is a hard stop for exactly that reason.

## 4. compose.yml

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

Assert: that prints `compose OK`. The container serves on 3001 inside itself and 8091 is bound
to 127.0.0.1 on the host, so the only route in is Caddy. Do not add a Caddy service to this
file: Caddy is already running under systemd on this box, and a container claiming 80 and 443
would fail to start and take every other site down with it.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every site on the box.

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

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-uptime-kuma,
reload, and report what it objected to. Caddy gets the certificate on the first request and
renews it with no cron job.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8091 stays closed: bound to 127.0.0.1, a rule for it would cover traffic that cannot
arrive, and if it appears there a previous run left it, which `sudo ufw delete allow 8091`
fixes. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and
no rule for 8091.

## 7. Start and verify

The image's own health check allows a three-minute start period, so give the first boot time
before treating anything as broken.

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

Assert, all three: `docker inspect` prints `healthy`, the JSON line contains `"needSetup":false`
because step 2 already chose SQLite, and the last prints a number greater than `0`. Print what
you received for each. If health is `starting`, wait 60 seconds and check again. If anything
still misses, stop, run `docker compose logs --tail 40 uptime-kuma`, and name the likely
earlier step. A running container is not success.

The first screen at https://<DOMAIN> is a form asking for a username and a password to create
the administrator account. Until it is submitted, anyone who loads that page can submit it.

STOP: tell the user to open https://<DOMAIN> right now, create the administrator account, and
save the password in their password manager. Wait until they confirm.

Then have them prove it closed: ask them to open https://<DOMAIN> in a private window and
confirm they see a sign-in form and no create-account fields. Assert: they confirm that in
words. Do not report success on the strength of the container being up.

## 8. First backup and restore

Take the backup now, before the user adds a monitor. Stop first: a SQLite file copied mid-write
is not a backup.

```bash
cd /srv/uptime-kuma
docker compose stop
sudo tar -C /srv/uptime-kuma -czf /srv/uptime-kuma/backups/uptime-kuma-$(date +%F).tar.gz data
docker compose start
ls -lh /srv/uptime-kuma/backups/
```

Assert: the archive exists and is non-empty. Print its size. `data` is the whole install: there
is no `.env` here, and `data/kuma.db` holds the monitors, the account and every heartbeat ever
recorded. A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/uptime-kuma
scp vps:/srv/uptime-kuma/backups/*.tar.gz ~/backups/uptime-kuma/
```

To restore: `docker compose down`, `sudo rm -rf /srv/uptime-kuma/data`,
`sudo tar -C /srv/uptime-kuma -xzf` the archive, then `docker compose up -d`. Those four
commands are the whole disaster plan. Tell the user that heartbeat history is kept forever by
default, so this archive grows with the number of monitors times the check interval, and the
retention setting in the interface is the lever if the disk starts filling.

## 9. Updating later

New versions are at https://github.com/louislam/uptime-kuma/releases. Take a backup first, then
edit the image line in /srv/uptime-kuma/compose.yml to the new tag and digest. Uptime Kuma
migrates its own database on the next boot, so wait for the health check to go green before
calling this done.

```bash
cd /srv/uptime-kuma
docker compose pull
docker compose up -d
docker compose logs --tail 20 uptime-kuma
```

## 10. What will probably go wrong

The alert that never arrives. I set up a monitor, watched it go green, and assumed the whole
thing worked, including the notification channel I had configured and never fired. It had a
typo in the webhook URL, and I found out three weeks later when a real outage produced silence.
Tell the user to do this on day one, not later: point a second monitor at a hostname that does
not exist, wait for it to go red, and confirm the alert lands on their phone. An untested alert
channel is not an alert channel, and this failure is invisible until the day it matters.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy is already running under systemd on
  this box, and a second one would fight it for 80 and 443.
- Do not configure MariaDB. `db-config.json` picks SQLite, which is why this is one container.
- Do not configure notification channels. Every one of them is an account or a token somewhere
  else, and the user picks those in the interface.
- Do not publish 3001 on the host or open it in the firewall. Caddy is the only way in.
