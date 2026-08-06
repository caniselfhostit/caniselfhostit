This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing wallabag 2.6.14 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

One thing to know before you start, because step 7 depends on it. The image creates its first
account on first boot, a super admin whose username and password are both the word wallabag,
written in its own README. Step 7 replaces that password with one generated in step 3 and then
proves the old one no longer works. Do not stop between starting the container and finishing
that check.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that
does not resolve, and failed attempts count against a rate limit you cannot see. On the memory
line, wallabag is PHP: the floor is not the idle footprint, it is what saving a long article
with images costs while php-fpm is also serving the page you are looking at.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wallabag /srv/wallabag/backups
sudo install -d -m 750 -o 65534 -g 65534 /srv/wallabag/data /srv/wallabag/images
ls -la /srv/wallabag
```

You should see: `backups` owned by you, and `data` and `images` owned by `nobody`.

If you do not: leave those two owned by `nobody` on purpose. The image chowns
/var/www/wallabag to uid 65534 when it is built and runs php-fpm as that user, so a directory
owned by you is one wallabag cannot write to, and the symptom is a container that starts and
then serves a blank page. You will need `sudo` to read those two directories later, which is
why the backup command in step 8 uses it.

## 3. Secrets

Two secrets, both generated here on the server: the Symfony application secret and the password
that replaces the one the image ships with. Replace `<DOMAIN>` on the first line with your real
hostname before you paste.

```bash
umask 077
cat > /srv/wallabag/.env <<EOF
SYMFONY__ENV__DOMAIN_NAME=https://<DOMAIN>
SYMFONY__ENV__SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/wallabag/.env
umask 022
ls -l /srv/wallabag/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/wallabag/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
both values, which is fine before the container has ever started and a problem afterwards: a
changed application secret logs you out, and a changed `ADMIN_PASSWORD` no longer matches the
one already stored in the database.

Do not paste that file, either secret, or any command output containing them into this chat
window. The application secret matters because the image ships a default value for it in its
parameter template, so every wallabag that never set one is signing its remember-me cookies
with a string published on GitHub. Yours is now not one of those. One deliberate trade to
know about: `ADMIN_PASSWORD` rides this file into the container's environment so step 7 can
change the password without the value ever appearing in a command you type, which also means
`docker inspect` can show it. Reading it that way takes docker-group access, and Prompt Zero
already calls that root-equivalent.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/wallabag/compose.yml <<'EOF'
# wallabag · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image README ....... https://github.com/wallabag/docker/blob/master/README.md
#   parameter template . https://github.com/wallabag/docker/blob/master/root/etc/wallabag/parameters.template.yml
#   entrypoint ......... https://github.com/wallabag/docker/blob/master/root/entrypoint.sh
#   image definition ... https://github.com/wallabag/docker/blob/master/Dockerfile
#   parameter reference  https://doc.wallabag.org/admin/parameters/
#
# One service. The image runs nginx and php-fpm side by side and keeps every
# article in the SQLite file upstream ships as the default driver, at
# data/db/wallabag.sqlite. The two bind mounts are the two paths the upstream
# README names as worth keeping. The image chowns /var/www/wallabag to nobody,
# uid 65534, at build time, so both host directories are created with that owner
# and the login user reads them through sudo. Tag and digest were read from
# Docker Hub on 2026-08-06; the image publishes amd64, arm64 and armv7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  wallabag:
    image: wallabag/wallabag:2.6.14@sha256:4a527e027e0d59e87c14225ef11e005af3d4890374202ad319ce5e63dfc66709
    container_name: wallabag
    restart: unless-stopped
    env_file: /srv/wallabag/.env
    environment:
      # SQLite is the image default and it is the whole database here: one file
      # under data/db, with no second container to run and no dump to schedule.
      SYMFONY__ENV__DATABASE_DRIVER: pdo_sqlite
      # Public sign-up stays off. It is already off in the image, and writing it
      # here means a reviewer can see the posture without opening .env.
      SYMFONY__ENV__FOSUSER_REGISTRATION: "false"
      # The issuer name an authenticator app shows if you enable two-factor.
      SYMFONY__ENV__SERVER_NAME: wallabag
      # Upstream's default is 128M. Saving an article parses a whole page with
      # tidy and DOM, and 128M is where long pages start failing.
      PHP_MEMORY_LIMIT: 256M
    volumes:
      - /srv/wallabag/data:/var/www/wallabag/data
      - /srv/wallabag/images:/var/www/wallabag/web/assets/images
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8109.
      - "127.0.0.1:8109:80"
    # The image already carries a HEALTHCHECK that polls /api/info, so there is
    # no healthcheck block here to drift away from it.
EOF
cd /srv/wallabag && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/wallabag/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your
terminal: run `rm /srv/wallabag/compose.yml` and paste again in one go. There is no database
service in this file because there is no database process. SQLite is the driver upstream ships
as the default, it lives in one file under data/db, and that is what makes this install one
container and the backup in step 8 one archive.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-wallabag
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# wallabag · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/wallabag/docker/blob/master/root/etc/nginx/nginx.conf and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also SYMFONY__ENV__DOMAIN_NAME in .env, and wallabag builds its feed and
# sharing links from it, so the two have to stay the same string.

<DOMAIN> {
	# The nginx inside the container maps X-Forwarded-Proto onto the HTTPS
	# fastcgi parameter, and Caddy sets that header on every proxied request,
	# so PHP sees an https request and wallabag generates https links.
	# Nothing else has to be configured for that to happen.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		# Every article page links out to the site it was saved from. Without
		# this, each of those sites learns the hostname of a private reading
		# list and roughly what is in it.
		Referrer-Policy "no-referrer"
		-Server
	}

	# Article pages are HTML and the reading view is text, so compression is
	# worth more here than it is in front of an API.
	encode zstd gzip

	# 8109 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8109
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-wallabag /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and
not the other. Caddy requests the certificate itself and renews it on its own, so there is
nothing to schedule and no cron job to forget.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8109`.

If you do not: delete anything for `8109` with `sudo ufw delete allow 8109`. That port is
bound to 127.0.0.1 by the compose file, so Caddy is the only thing that can reach it and a
firewall rule would only widen that. 80/tcp redirects to HTTPS and answers the ACME challenge,
443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

Paste this whole block and let it run to the end. The stretch between the container answering
and the password change is the only window in which the credential from the image's README is
live on a public hostname.

```bash
cd /srv/wallabag
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8109/api/info); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
docker compose exec -T wallabag su -c '/var/www/wallabag/bin/console fos:user:change-password wallabag "$ADMIN_PASSWORD" --env=prod' -s /bin/sh nobody
curl -sS https://<DOMAIN>/api/info
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
curl -sS https://<DOMAIN>/login | grep -c 'Log in'
```

You should see, in order: a column of `000` for two or three minutes and then `200`; the line
`Changed password for user wallabag`; a small JSON object containing `"version":"2.6.14"` and
`"allowed_registration":false`; then `301`; then a number of at least `1`.

If you do not: the column of `000` is the normal first boot, not a fault, so let the loop run
its full sixty attempts before you conclude anything. If it never reaches `200`, run
`docker compose logs --tail 40 wallabag`. The `301` on `/register` is the one worth
understanding: it means wallabag is bouncing a sign-up attempt back to the login page because
public registration is off, so seeing it is the good outcome, and a `200` there would mean
anyone who finds your hostname can make themselves an account. A `404` in its place means
Caddy is not reaching the container at all: check `docker compose ps`.

Now prove the credential from the README is dead. This works from the server or your own
machine:

```bash
shipped=wallabag
jar=$(mktemp)
tok=$(curl -sS -c "$jar" https://<DOMAIN>/login | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)
echo "csrf token length ${#tok}"
curl -sS -b "$jar" -c "$jar" -L -d "_username=$shipped" -d "_password=$shipped" -d "_csrf_token=$tok" https://<DOMAIN>/login_check | grep -c 'unread/list' || true
rm -f "$jar"
```

You should see: a token length of about 40, then `0`.

If you do not: anything above zero on the last line means that login succeeded, so the password
change in the block above did not take, and your instance is open to anyone who has read the
image's README. Stop here. Run `docker compose logs --tail 40 wallabag`, re-run the
`fos:user:change-password` line on its own, and run this check again before you do anything
else. A token length of `0` is a different failure: the login was then rejected for a missing
token rather than a wrong password, so the `0` on the last line proved nothing and the check
has to be run again. A running container is not success.

The first screen at https://<DOMAIN>/login is a card with the wallabag logo, `Username` and
`Password` fields, and a button reading `Log in`. The browser tab reads
`Welcome to wallabag!`. Read your password once with
`sudo grep ADMIN_PASSWORD /srv/wallabag/.env`, put it in your password manager, and log in as
the user `wallabag`. There is no password-reset mail on this install, so that password manager
entry is the only copy you have.

## 8. First backup and restore

One archive. It holds the SQLite database with every saved article, the images directory, and
the two files that rebuild the service around them.

```bash
cd /srv/wallabag
docker compose stop
sudo tar -czf /srv/wallabag/backups/wallabag-$(date +%F).tar.gz -C /srv/wallabag data images compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/wallabag/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install.

If you do not: an archive of about 100 bytes means `tar` matched nothing, which happens if you
ran it from a different directory. The container is stopped for the copy on purpose, because a
SQLite file copied mid-write is not a database. Starting it again re-runs the image's
entrypoint, so wallabag takes another minute or two before it answers; that is expected, and
it is the same pause you saw in step 7.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/wallabag
scp vps:/srv/wallabag/backups/*.tar.gz ~/backups/wallabag/
```

You should see: one file copied, and listed by `ls -lh ~/backups/wallabag/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty reading list:

```bash
cd /srv/wallabag
docker compose down
sudo rm -rf /srv/wallabag/data /srv/wallabag/images
sudo install -d -m 750 -o 65534 -g 65534 /srv/wallabag/data /srv/wallabag/images
sudo tar -xzf /srv/wallabag/backups/wallabag-$(date +%F).tar.gz -C /srv/wallabag data images
docker compose up -d
sleep 120
curl -sS https://<DOMAIN>/api/info
```

You should see: the same JSON object as in step 7, with `"version":"2.6.14"`.

If you do not: give it another two minutes and try again, because the entrypoint is rebuilding
the cache from scratch on a directory it has only now been handed. If it still fails, run
`ls -la /srv/wallabag/data/db` and confirm `wallabag.sqlite` is there and owned by `nobody`.
Understand what that proved: every article you save from here on is a row in that one file, and
this archive is the only thing standing between a bad disk and starting over.

## 9. Updating later

New versions are listed at https://github.com/wallabag/wallabag/releases. Take the backup
first, then edit the `image:` line in /srv/wallabag/compose.yml to the new tag and its digest.

```bash
cd /srv/wallabag
docker compose pull
docker compose up -d
for i in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:8109/api/info && break; sleep 5; done
docker compose exec -T wallabag su -c '/var/www/wallabag/bin/console doctrine:migrations:migrate --env=prod --no-interaction' -s /bin/sh nobody
docker compose logs --tail 30 wallabag
```

You should see: the loop finishing, then the migration command either applying migrations or
reporting that there are none, then no repeating restart in the log.

If you do not: put the old tag and digest back and run the same commands. The loop is there
because the container cannot run a console command until it answers, which after an image
change takes the same two or three minutes as a first boot. The migration line is upstream's
documented way to move an existing database to a new release, and it is safe to run when there
is nothing to migrate. Re-run the `/api/info` check from step 7 and confirm the version string
moved before you call the update done.

## 10. What will probably go wrong

The first boot looks like a hang. The image's entrypoint deletes the Symfony cache and re-runs
its dependency install every time the container starts, so between `docker compose up -d` and
the first byte of HTML there is a stretch of two to three minutes where port 8109 accepts the
connection and returns nothing. I refreshed eleven times, checked `docker compose ps`, saw
`Up`, and went looking for a proxy misconfiguration that did not exist. Give the loop in step 7
its full sixty attempts, and expect the same pause after every restart, including step 8's.

## 11. Out of scope

- Do not configure SMTP or set `SYMFONY__ENV__MAILER_DSN`. wallabag works without outgoing
  mail; what it costs is password-reset email, which is why step 7 makes you save the password
  before anything else.
- Do not add a Redis container or start the async import worker. It exists for people
  importing tens of thousands of articles, and the browser upload handles an ordinary export.
- Do not change `SYMFONY__ENV__DATABASE_DRIVER` to pdo_mysql or pdo_pgsql. SQLite is the
  choice here and it is what makes the backup in step 8 one file.
- Do not set `SYMFONY__ENV__FOSUSER_REGISTRATION` to true. This install has one account by
  design, and open sign-up on a public hostname is a different service than the one you asked
  for.
