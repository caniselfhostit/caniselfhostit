You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Actual Budget 26.8.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Actual is a small Node process, so it needs
512 MB of RAM available and 5 GB free on /srv, and the 26.8.0 image covers amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If RAM is under 512 MB or disk under 5 GB, print both numbers and stop. If `dig +short` prints
nothing, print that and stop: Caddy cannot certify a hostname that does not resolve.

## 2. Layout

The image creates an `actual` account with uid 1001 and runs as it, so the data directory
belongs to 1001 and not to the login user.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/actual-budget /srv/actual-budget/backups
sudo install -d -m 750 -o 1001 -g 1001 /srv/actual-budget/data
ls -la /srv/actual-budget
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by `1001`. Nothing is
written outside /srv/actual-budget.

## 3. Secrets

No secret is generated for this install, and there is no `.env` file. Actual has exactly one
credential, the server password, and it is chosen by the user in a browser at step 7 rather
than written into a file here. That is why this block has nothing to run.

Tell the user two things now, before they choose it. That one password is the whole door: it
guards every budget file on the server. And end-to-end encryption is a separate, per-file
setting inside Actual, off by default, so until they turn it on the budget data on this disk is
readable by anyone who can read the disk.

## 4. compose.yml

```bash
cat > /srv/actual-budget/compose.yml <<'EOF'
# Actual Budget · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   image, port, /data .. https://actualbudget.org/docs/install/docker
#   configuration ....... https://actualbudget.org/docs/config/
#   health route ........ https://github.com/actualbudget/actual/blob/master/packages/sync-server/src/scripts/health-check.js
#
# One container, no database process and no secret to generate: the sync server
# keeps account.sqlite and the budget blobs under /data, and the only credential
# is the server password you set in a browser at step 7. The image runs as uid
# 1001, hence the ownership in step 2. Tag and digest are the 26.8.0 release read
# from Docker Hub on 2026-08-05, for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  actual:
    image: actualbudget/actual-server:26.8.0@sha256:0b300f370dba85a74998a953736a831bd931cc8cb76c0d8ceac3d3fd288dfd4d
    container_name: actual
    restart: unless-stopped
    environment:
      # Caddy reaches the published port from the host, so the container sees
      # the Docker bridge as the client. Naming that range keeps the rate
      # limiter counting real clients instead of one proxy.
      ACTUAL_TRUSTED_PROXIES: 172.16.0.0/12
    volumes:
      # server-files holds account.sqlite, user-files holds the budget blobs.
      # Local disk only: SQLite needs real POSIX file locks to stay intact.
      - /srv/actual-budget/data:/data
    ports:
      # Loopback only. The Caddy that Prompt Zero installed on the host is the
      # only thing that can reach this port, and 8090 never enters the firewall.
      - "127.0.0.1:8090:5006"
EOF
cd /srv/actual-budget && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on 5006 inside itself and 8090 is bound
to 127.0.0.1 on the host, so the only route in is Caddy. Upstream's example publishes 5006 on
every interface, which is convenient on a laptop and wrong on a machine with a public IP.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-actual-budget
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Actual Budget · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://caddyserver.com/docs/automatic-https
# and https://actualbudget.org/docs/install/docker
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. Caddy runs under systemd. No Caddy container here.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8090 is the loopback port compose publishes; it is never in the firewall.
	# A full budget upload arrives as one request, so no body limit is set here
	# and ACTUAL_UPLOAD_FILE_SYNC_SIZE_LIMIT_MB stays at the upstream default.
	reverse_proxy 127.0.0.1:8090
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-actual-budget,
reload, and report what it objected to. Caddy gets the certificate on the first request and
renews it with no cron job. Actual runs HTTPS itself if you hand it a key and certificate; this
install does not, because Caddy already holds one and two certificate owners on one box is a
renewal argument waiting to happen.

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
is HTTP/3. 8090 stays closed: bound to 127.0.0.1, a rule for it would cover traffic that cannot
arrive, and if it appears there a previous run left it, which `sudo ufw delete allow 8090`
fixes. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and
no rule for 8090.

## 7. Start and verify

```bash
cd /srv/actual-budget
docker compose up -d
sleep 15
curl -sS https://<DOMAIN>/health
echo
curl -sS https://<DOMAIN>/account/needs-bootstrap
echo
```

Assert, both: `/health` prints JSON containing `"status":"UP"`, and `/account/needs-bootstrap`
prints JSON containing `"bootstrapped":false`. Print exactly what you received for each. If
either misses, stop, run `docker compose logs --tail 30 actual`, and name the likely earlier
step. A running container is not success. `bootstrapped:false` means the server is currently
open to whoever loads the page first, which is why the next line is a hard stop.

The first screen at https://<DOMAIN> asks the user to choose a password for this server.

STOP: tell the user to open https://<DOMAIN> now, set that password, and save it in their
password manager. Wait. Do not continue until they confirm.

```bash
curl -sS https://<DOMAIN>/account/needs-bootstrap
echo
```

Assert: this now prints `"bootstrapped":true`. That flip is the security assert for this
install: until it is true, anyone who finds the hostname owns the budget. If it still says
false, the password was not set, and nothing else matters yet.

## 8. First backup and restore

Take the backup now, before the user imports a single transaction. Stop first: a SQLite file
copied mid-write is not a backup.

```bash
cd /srv/actual-budget
docker compose stop
sudo tar -C /srv/actual-budget -czf /srv/actual-budget/backups/actual-budget-$(date +%F).tar.gz data
docker compose start
ls -lh /srv/actual-budget/backups/
```

Assert: the archive exists and is non-empty. Print its size. `data` is the whole install: there
is no `.env` here, and `data/server-files/account.sqlite` holds the password hash while
`data/user-files` holds the budgets. A backup on the same disk is not a backup, so run this
from the user's machine:

```bash
mkdir -p ~/backups/actual-budget
scp vps:/srv/actual-budget/backups/*.tar.gz ~/backups/actual-budget/
```

To restore: `docker compose down`, `sudo rm -rf /srv/actual-budget/data`,
`sudo tar -C /srv/actual-budget -xzf` the archive, then `docker compose up -d`. Those four
commands are the whole disaster plan. Tell the user Actual also exports a plain zip of any
budget from inside the interface, and that a monthly one of those in a different place is worth
more than any of this, because it is readable without a server.

## 9. Updating later

New versions are at https://github.com/actualbudget/actual/releases. Take a backup first, then
edit the image line in /srv/actual-budget/compose.yml to the new tag and digest. Actual migrates
its own database on the next boot, and the browser holds a cached copy of the app, so load the
page and hard-refresh once before calling this done.

```bash
cd /srv/actual-budget
docker compose pull
docker compose up -d
docker compose logs --tail 20 actual
```

## 10. What will probably go wrong

Nothing during the install, and then the user asks where their bank is. Actual does not connect
to banks on its own: it talks to GoCardless or SimpleFIN, each of which is a separate signup
with its own credentials, and in the United States the usable one is not free. I finished this
install in under ten minutes and then spent an hour discovering that the part I actually wanted
was a different product with a different bill. Tell the user before they start moving their
budget across, not after.

## 11. Out of scope

- Do not set `ACTUAL_HTTPS_KEY` or `ACTUAL_HTTPS_CERT`. Caddy terminates TLS on this box, and
  a second certificate owner is a renewal argument nobody wins.
- Do not configure GoCardless, SimpleFIN or any other bank aggregator. Each is a signup
  somewhere else, with its own credentials, and it is the user's decision.
- Do not enable OpenID login. One server password is the design here.
- Do not enable end-to-end encryption on the user's behalf. Losing that key loses the budget,
  and the choice belongs to whoever will have to remember it.
