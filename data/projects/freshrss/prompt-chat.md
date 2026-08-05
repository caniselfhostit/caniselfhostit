This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing FreshRSS 1.29.1 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A
record already points at the box.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and
your server's IP address on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it at your
DNS provider, wait a minute, and run `dig +short <DOMAIN>` again. Do not go on without it:
Caddy cannot get a certificate for a hostname that does not resolve, and failed attempts
count against a rate limit you cannot see.

## 2. Layout

The `data` directory is owned by uid 33 because that is `www-data` inside the image, and
Apache in the container is the process that writes the database.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/freshrss /srv/freshrss/backups
sudo install -d -m 750 -o 33 -g 33 /srv/freshrss/data
ls -la /srv/freshrss
```

You should see: `backups` owned by your own username, and `data` owned by `33`.

If you do not: `data` owned by you instead of `33` means the second command did not run,
and the container will fail to write its database with a permission error that mentions
nothing about ownership. Run the second line again on its own.

## 3. Secrets

One secret: the password for your own FreshRSS account. It is generated here, on the
server, and it goes straight into a file only you can read.

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

You should see: mode `-rw-------`, your own username twice, and the path. Your FreshRSS
username will be `admin`. Read the password once with
`sudo grep ADMIN_PASSWORD /srv/freshrss/.env` and put it straight into your password
manager.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens
if you pasted the lines one at a time in different shells. Run
`chmod 600 /srv/freshrss/.env` and carry on.

Do not paste the contents of that file, the password, or any command output containing it
into this chat window. Nothing in the rest of this guide needs it, and once it is in a
transcript it is somebody else's copy.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/freshrss/.env not found` means step 3 did not write the
file, so go back. `services must be a mapping` means the indentation was lost between the
page and your terminal: run `rm /srv/freshrss/compose.yml` and paste the block again in
one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>`
in the block with your hostname before you paste. The first line takes a copy, because a
syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-freshrss /etc/caddy/Caddyfile`,
reload, and paste again, checking that the blank line from the second command really
landed. Caddy asks Let's Encrypt for the certificate on the first request to your hostname
and renews it on its own, so there is nothing to schedule.

Later on, if a link inside FreshRSS comes out as plain `http`, the documented fix is
`base_url` in /srv/freshrss/data/config.php. Do not set it now.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8084`.

If you do not: a rule for `8084` from an earlier attempt should go, with
`sudo ufw delete allow 8084`. 8084 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it and a firewall rule for it would cover traffic that
cannot arrive. 80/tcp is there to redirect to HTTPS and answer the ACME challenge, 443/tcp
is the only way in, and 443/udp is HTTP/3.

## 7. Start and verify

You are skipping the web installer on purpose. Until somebody completes that wizard it is
open to whoever reaches the hostname first, and the command line installer closes the
window without a browser being involved. The password is read from the container's own
environment, so it never reaches your shell history.

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

You should see: a line of installer output, a line of user output, then a listing for
`data/config.php`, then `200`, then a number greater than `0`.

If you do not: `No such file or directory` for `config.php` is the important failure,
because that file is what makes the web installer stop answering. Until it exists a
stranger who finds your hostname can finish the wizard and own the reader, so fix this
before anything else: run `docker compose logs --tail 30 freshrss` and look for a
permission error on `/var/www/FreshRSS/data`, which is step 2 done wrong. If the installer
says the install already exists, that is fine on a second run. If the first curl prints
`000` or `502`, the certificate is not there yet: run `sudo journalctl -u caddy -n 30`.

A container listed in `docker ps` is not proof of anything. The three checks above are.

Now open https://<DOMAIN> in a browser. The first screen is a login form asking for a
username and a password. Sign in as `admin` with the password from step 3.

## 8. First backup and restore

Do this before you import a single feed, so you find out now whether it works. The stop
matters: a SQLite file copied mid-write is not a backup.

```bash
cd /srv/freshrss
docker compose stop
sudo tar -C /srv/freshrss -czf /srv/freshrss/backups/freshrss-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/freshrss/backups/
```

You should see: one `.tar.gz` file, a few hundred kilobytes on a fresh install. The site
is down for a few seconds while this runs, which is the price of a backup that is actually
consistent.

If you do not: `tar: data: Cannot open` means the `cd` did not happen. A size of `45`
bytes means tar wrote an empty archive because the paths were wrong, so check
`sudo ls /srv/freshrss/data` before you trust it.

A backup on the same disk as the data is not a backup. Run this one on your own machine,
not on the server:

```bash
mkdir -p ~/backups/freshrss
scp vps:/srv/freshrss/backups/*.tar.gz ~/backups/freshrss/
```

You should see: one file copied, and the same file listed by `ls -lh ~/backups/freshrss/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake.
The `vps:` prefix only means something on your own machine.

Now prove the restore, because a backup you have never restored is a guess:

```bash
cd /srv/freshrss
docker compose down
sudo rm -rf /srv/freshrss/data
sudo tar -C /srv/freshrss -xzf /srv/freshrss/backups/freshrss-$(date +%F).tar.gz
docker compose up -d
```

You should see: `Created` and `Started`, then a working login page at https://<DOMAIN>
with your `admin` account still there.

If you do not: a login page that has turned back into the installation wizard means the
archive did not contain `data/config.php`. Stop and go back to the tar step. Those four
commands are the whole disaster plan, and you have now run them once.

## 9. Updating later

New versions are listed at https://github.com/FreshRSS/FreshRSS/releases. Take a backup
first, then edit the `image:` line in /srv/freshrss/compose.yml to the new tag and its
digest.

```bash
cd /srv/freshrss
docker compose pull
docker compose up -d
docker compose logs --tail 20 freshrss
```

You should see: `Recreated`, then Apache startup lines and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. FreshRSS
migrates its own schema on the first request after an upgrade, so load the page once and
read the log before you call the update done.

## 10. What will probably go wrong

Nothing, for about half an hour, and it looks exactly like a broken install. I added a
dozen feeds, refreshed, and got an empty reader. Two things were true: the image's cron
only fires at 13 and 43 minutes past the hour, and FreshRSS refuses to refresh a feed more
often than every twenty minutes no matter who asks. If no articles are arriving, check the
clock before any log, and use the refresh button in the interface to prove it works now.

## 11. Out of scope

- Do not switch the database to PostgreSQL or MySQL. SQLite is why this is one container
  with one directory to copy.
- Do not configure SMTP. A single-user install sends no mail, and address validation stays
  off.
- Do not install FreshRSS extensions. Only `data/` is mounted, so one installed now
  disappears at the next image bump.
- Do not enable the Google Reader or Fever API. Each is a credential per app, and that is
  your call to make later.
