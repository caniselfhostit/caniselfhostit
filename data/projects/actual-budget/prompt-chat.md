This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Actual Budget 26.8.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

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

The image creates an `actual` account with uid 1001 and runs as it, so `data` belongs to 1001
and not to you.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/actual-budget /srv/actual-budget/backups
sudo install -d -m 750 -o 1001 -g 1001 /srv/actual-budget/data
ls -la /srv/actual-budget
```

You should see: `backups` owned by your own username, and `data` owned by `1001`.

If you do not: `data` owned by you means the second command did not run, and the container will
fail to write account.sqlite with a permission error that mentions nothing about ownership.
Run the second line again on its own.

## 3. Secrets

There is nothing to generate and no `.env` file in this install. Actual has exactly one
credential, the server password, and you choose it in a browser at step 7.

Two things to know before you pick it. That one password is the whole door: it guards every
budget file on this server. And end-to-end encryption is a separate setting inside Actual, per
budget file, off by default, so until you turn it on your budget on this disk is readable by
anyone who can read the disk. If you do turn it on, losing that key loses the budget, and
nobody can reset it for you.

Nothing in this guide asks you to paste a credential into this chat window. Do not, at any
point, paste the server password or the output of any command that contains it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/actual-budget/compose.yml` and paste the block again in one go.

Upstream's own example publishes port 5006 on every interface. That is convenient on a laptop
and wrong on a machine with a public IP, which is why this one binds to 127.0.0.1.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-actual-budget /etc/caddy/Caddyfile`,
reload, and paste again, checking that the blank line from the second command really landed.
Caddy asks Let's Encrypt for the certificate on the first request to your hostname and renews
it on its own. Actual can serve HTTPS itself if you hand it a key and certificate; do not, on
this box. Two certificate owners is a renewal argument nobody wins.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8090`.

If you do not: a rule for `8090` from an earlier attempt should go, with
`sudo ufw delete allow 8090`. 8090 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it and a firewall rule for it would cover traffic that cannot
arrive.

## 7. Start and verify

```bash
cd /srv/actual-budget
docker compose pull
docker compose up -d
sleep 15
curl -sS https://<DOMAIN>/health
echo
curl -sS https://<DOMAIN>/account/needs-bootstrap
echo
```

You should see: a line of JSON containing `"status":"UP"`, then a line of JSON containing
`"bootstrapped":false`.

If you do not: `000` or `502` means the certificate is not there yet, so run
`sudo journalctl -u caddy -n 30`. Nothing at all from `/health` means the container did not
start: run `docker compose logs --tail 30 actual` and look for a permission error on `/data`,
which is step 2 done wrong.

A container listed in `docker ps` is not proof of anything. The two lines of JSON are.

`"bootstrapped":false` means this server is open to whoever loads the page first. Open
https://<DOMAIN> now, choose the server password, and save it in your password manager before
you do anything else. Then check the flip:

```bash
curl -sS https://<DOMAIN>/account/needs-bootstrap
echo
```

You should see: `"bootstrapped":true`.

If you do not: the password was not saved. Go back to the browser and finish. Nothing on this
server is yours until that says true.

## 8. First backup and restore

Do this before you import a single transaction, so you find out now whether it works. The stop
matters: a SQLite file copied mid-write is not a backup.

```bash
cd /srv/actual-budget
docker compose stop
sudo tar -C /srv/actual-budget -czf /srv/actual-budget/backups/actual-budget-$(date +%F).tar.gz data
docker compose start
ls -lh /srv/actual-budget/backups/
```

You should see: one `.tar.gz` file, tens of kilobytes on a fresh install.

If you do not: `tar: data: Cannot open` means the `cd` did not happen. A size of `45` bytes
means tar wrote an empty archive because the paths were wrong, so check
`sudo ls /srv/actual-budget/data` before you trust it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not on
the server:

```bash
mkdir -p ~/backups/actual-budget
scp vps:/srv/actual-budget/backups/*.tar.gz ~/backups/actual-budget/
```

You should see: one file copied, and the same file listed by `ls -lh ~/backups/actual-budget/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake. The
`vps:` prefix only means something on your own machine.

Now prove the restore, because a backup you have never restored is a guess:

```bash
cd /srv/actual-budget
docker compose down
sudo rm -rf /srv/actual-budget/data
sudo tar -C /srv/actual-budget -xzf /srv/actual-budget/backups/actual-budget-$(date +%F).tar.gz
docker compose up -d
sleep 15
curl -sS https://<DOMAIN>/account/needs-bootstrap
echo
```

You should see: `Created`, `Started`, then `"bootstrapped":true` again, and the same server
password still works in the browser.

If you do not: `"bootstrapped":false` after a restore means the archive did not contain
`server-files/account.sqlite`. Stop and go back to the tar step. Those four commands are the
whole disaster plan, and you have now run them once.

One more thing worth doing tonight: inside Actual, export a zip of your budget and keep it
somewhere else. It is readable without a server, which is more than any archive on this box can
say.

## 9. Updating later

New versions are at https://github.com/actualbudget/actual/releases. Take a backup first, then
edit the `image:` line in /srv/actual-budget/compose.yml to the new tag and its digest.

```bash
cd /srv/actual-budget
docker compose pull
docker compose up -d
docker compose logs --tail 20 actual
```

You should see: `Recreated`, then a few startup lines and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Your browser
caches the app, so after an upgrade load the page and hard-refresh once before deciding
anything is broken.

## 10. What will probably go wrong

Nothing during the install, and then you will ask where your bank is. Actual does not connect
to banks by itself: it talks to GoCardless or SimpleFIN, each a separate signup with its own
credentials, and in the United States the usable one is not free. I finished this install in
under ten minutes and then spent an hour discovering that the part I actually wanted was a
different product with a different bill. Decide how you feel about that before you move a
year of budget across, not after.

## 11. Out of scope

- Do not set `ACTUAL_HTTPS_KEY` or `ACTUAL_HTTPS_CERT`. Caddy terminates TLS on this box.
- Do not configure GoCardless, SimpleFIN or any other bank aggregator yet. Each is a signup
  somewhere else with its own credentials, and it is a decision, not a step.
- Do not enable OpenID login. One server password is the design here.
- Do not turn on end-to-end encryption until you have somewhere safe for the key. Losing it
  loses the budget, and nobody can reset it for you.
