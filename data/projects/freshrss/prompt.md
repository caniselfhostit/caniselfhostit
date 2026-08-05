You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install FreshRSS 1.29.1 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. Its A record must already point at this server. FreshRSS needs 512 MB of RAM
available and 5 GB free on /srv, and the 1.29.1 image is published for amd64 and arm64.
Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop.
Do not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot
certify a hostname that does not resolve.

## 2. Layout

The data directory is owned by uid 33, because that is `www-data` inside the image and
Apache is what writes the database.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/freshrss /srv/freshrss/backups
sudo install -d -m 750 -o 33 -g 33 /srv/freshrss/data
ls -la /srv/freshrss
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by `33`.
Everything lives under /srv/freshrss, on local disk, and nothing is written outside it.

## 3. Secrets

One secret: the password for the user's FreshRSS account, generated on the server. Do not
print it, do not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/freshrss/.env <<EOF
TZ=UTC
CRON_MIN=13,43
TRUSTED_PROXY=172.16.0.0/12
ADMIN_USER=admin
ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/freshrss/.env
umask 022
ls -l /srv/freshrss/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user their username is `admin`,
that they can read the password with `sudo grep ADMIN_PASSWORD /srv/freshrss/.env`, and
that they should put it in their password manager now. `TRUSTED_PROXY` is the range Caddy
forwards from, so FreshRSS trusts the forwarded headers rather than logging the proxy as
the client.

## 4. compose.yml

```bash
cat > /srv/freshrss/compose.yml <<'EOF'
# FreshRSS · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image and env vars . https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md
#   built-in cron ...... https://freshrss.github.io/FreshRSS/en/admins/08_FeedUpdates.html
#   what to back up .... https://freshrss.github.io/FreshRSS/en/admins/05_Backup.html
#   reverse proxy ...... https://freshrss.github.io/FreshRSS/en/admins/Caddy.html
#
# One container. FreshRSS ships with SQLite, so the database, the user record and
# the favicons live under /var/www/FreshRSS/data, and that one directory is what a
# backup has to contain. CRON_MIN is the image's own cron daemon, and leaving it
# unset means nothing refreshes. Tag and digest are the 1.29.1 release read from
# Docker Hub on 2026-08-05, covering linux/amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  freshrss:
    image: freshrss/freshrss:1.29.1@sha256:ab6b363102ccdbc39f6a62db926f567c61a5289bf25ba460f1c34423d8cc1a4d
    container_name: freshrss
    restart: unless-stopped
    env_file: /srv/freshrss/.env
    volumes:
      # uid 33 (www-data) in the image writes here, hence the ownership in step 2.
      # Local disk only: SQLite needs real POSIX file locks to stay intact.
      - /srv/freshrss/data:/var/www/FreshRSS/data
    ports:
      # Loopback only. The Caddy that Prompt Zero installed on the host is the
      # only thing that can reach this port, and 8084 never enters the firewall.
      - "127.0.0.1:8084:80"
EOF
cd /srv/freshrss && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on port 80 inside itself and 8084
is bound to 127.0.0.1 on the host, so the only route in is Caddy.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by
the real hostname. Copy the file first: a syntax error here takes down every other site on
the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-freshrss
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# FreshRSS · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://freshrss.github.io/FreshRSS/en/admins/Caddy.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Upstream's own Caddy page
# uses a bare reverse_proxy for a subdomain; the headers are ours.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8084 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8084
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-freshrss, reload, and report what it objected to. Caddy
requests the certificate on the first request and renews it without a cron job. If a
FreshRSS link ever comes out as plain http, `base_url` in /srv/freshrss/data/config.php is
the documented override. Do not set it pre-emptively.

## 6. Firewall

Two ports open, both of them Caddy's, and 8084 is not one of them. These are idempotent,
so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. 8084 stays closed: bound to 127.0.0.1, a
rule for it would cover traffic that cannot arrive, and if 8084 shows up there a previous
run left it, which `sudo ufw delete allow 8084` fixes. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8084.

## 7. Start and verify

The web installer is skipped on purpose: until somebody completes it, it is open to
whoever reaches the hostname first. The password comes from the container's own
environment, so it never reaches shell history.

```bash
cd /srv/freshrss
docker compose pull
docker compose up -d
sleep 15
docker compose exec -T --user www-data freshrss cli/do-install.php --default-user admin
docker compose exec -T --user www-data freshrss sh -c 'cli/create-user.php --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"'
sudo ls -l /srv/freshrss/data/config.php
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -c 'FreshRSS'
```

Assert, all three: `ls -l` prints a line for `data/config.php`, the first curl prints
`200`, and the second prints a number greater than `0`, because `FreshRSS` appears in the
served document. Print what you actually received for each. If any of the three misses,
stop, run `docker compose logs --tail 30 freshrss`, and say which earlier step is the
likely cause. If `do-install.php` reports the install already exists, that is not an error
on a second run: carry on and check `config.php`, which is the security assert: that file
is what makes the web installer stop answering.

A running container is not success; three asserts passing is success. The first screen at
https://<DOMAIN> is a login form asking for a username and a password, and the user signs
in as `admin` with the password from step 3.

## 8. First backup and restore

Take the backup now, before the user imports a feed. Stop first: a SQLite file copied
mid-write is not a backup.

```bash
cd /srv/freshrss
docker compose stop
sudo tar -C /srv/freshrss -czf /srv/freshrss/backups/freshrss-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/freshrss/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds,
and `data` plus `.env` is the whole install. A backup on the same disk as the data is not
a backup, so run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/freshrss
scp vps:/srv/freshrss/backups/*.tar.gz ~/backups/freshrss/
```

To restore: `docker compose down`, `sudo rm -rf /srv/freshrss/data`,
`sudo tar -C /srv/freshrss -xzf` the archive, then `docker compose up -d`. The reader is a
SQLite file under `data/users/admin/`. Tell the user those four commands are the whole
disaster plan.

## 9. Updating later

New versions are listed at https://github.com/FreshRSS/FreshRSS/releases. Take a backup
first, then edit the image line in /srv/freshrss/compose.yml to the new tag and its
digest. FreshRSS migrates its own schema on the first request after an upgrade, so load
the page once before calling the update done.

```bash
cd /srv/freshrss
docker compose pull
docker compose up -d
docker compose logs --tail 20 freshrss
```

## 10. What will probably go wrong

Nothing, for about half an hour, and it looks exactly like a broken install. I added a
dozen feeds, refreshed, and got an empty reader. Two things were true: the image's cron
only fires at 13 and 43 minutes past the hour, and FreshRSS refuses to refresh a feed more
often than every twenty minutes no matter who asks. If the user says no articles are
arriving, check the clock before any log, and tell them the refresh button in the
interface proves it works now.

## 11. Out of scope

- Do not switch the database to PostgreSQL or MySQL. SQLite is why this is one container
  with one directory to copy.
- Do not configure SMTP. A single-user install sends no mail, and address validation stays
  off.
- Do not install FreshRSS extensions. Only `data/` is mounted, so one installed now
  disappears at the next image bump.
- Do not enable the Google Reader or Fever API. Each is a credential per app, and that is
  the user's call.
