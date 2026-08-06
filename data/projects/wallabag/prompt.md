You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install wallabag 2.6.14 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and the same hostname becomes
`SYMFONY__ENV__DOMAIN_NAME`, the string wallabag puts in every feed URL and share link.

wallabag needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64,
arm64 and armv7. Measure all four before installing anything:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wallabag /srv/wallabag/backups
sudo install -d -m 750 -o 65534 -g 65534 /srv/wallabag/data /srv/wallabag/images
ls -la /srv/wallabag
```

Assert: `ls -la` shows `backups` owned by the login user, and `data` and `images` owned by
`nobody`. That owner is not decoration: the image chowns /var/www/wallabag to uid 65534 when it
is built and runs php-fpm as that user, so a directory owned by anyone else is one wallabag
cannot write to. Nothing for this service is written outside /srv/wallabag.

## 3. Secrets

Two secrets, both generated here on the server: the Symfony application secret and the password
that replaces the one the image ships with. Do not print either, do not repeat them in your
summary, and do not put them in any log line.

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

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the
real hostname before running the block. The application secret matters because the image ships
a default value for it in its parameter template, so every wallabag that never set one signs
its remember-me cookies with a string published on GitHub. `ADMIN_PASSWORD` is read by step 7
from inside the container; the user reads it with
`sudo grep ADMIN_PASSWORD /srv/wallabag/.env`.

## 4. compose.yml

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

Assert: that prints `compose OK`. There is no database service because there is no database
process: SQLite is the driver upstream ships as the default and it lives in one file under
data/db. That is why this install is one container.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-wallabag, reload, and report what it objected to. Caddy requests
the certificate itself and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. The commands are idempotent, so on a box Prompt Zero configured
they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8109 stays closed because compose binds it to 127.0.0.1, so Caddy is the
only path in and a rule for 8109 would widen that. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8109.

## 7. Start and verify

Read this first. The image creates its first account on first boot with a username and a
password that are both the word wallabag, documented in its README, and that account is a super
admin. The password change below is not tidying up, it closes a published credential on a host
that already resolves, so run the block in one go.

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

Assert, all five, and print what you received. The loop ends on `200`, after a column of `000`
while the first boot rebuilds the Symfony cache. The console prints
`Changed password for user wallabag`. `/api/info` contains `"version":"2.6.14"` and
`"allowed_registration":false`. `/register` prints `301`, a sign-up attempt sent back to the
login page because public registration is off, and that is the security assert here. The last
prints at least `1`.

Now prove the shipped credential is dead. Server or user's machine, either works:

```bash
shipped=wallabag
jar=$(mktemp)
tok=$(curl -sS -c "$jar" https://<DOMAIN>/login | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)
echo "csrf token length ${#tok}"
curl -sS -b "$jar" -c "$jar" -L -d "_username=$shipped" -d "_password=$shipped" -d "_csrf_token=$tok" https://<DOMAIN>/login_check | grep -c 'unread/list' || true
rm -f "$jar"
```

Assert: the token length is not `0` and the last line prints `0`. A successful login lands on
the unread list, whose HTML carries `unread/list`, and a rejected one goes back to the login
form; a zero-length token would mean the login failed for a missing token rather than a wrong
password, and would prove nothing. Anything above zero means the password change did not take:
stop, run `docker compose logs --tail 40 wallabag`, and do not tell the user the install is
finished. If any of the earlier five misses, stop, pull the same log, and name the likely
cause: a loop stuck on `000` means the container is still doing first-boot work, and a `404`
where a `301` was expected means Caddy is not reaching the container. A running container is
not success.

The first screen at https://<DOMAIN>/login is a card with the wallabag logo, `Username` and
`Password` fields, and a button reading `Log in`. The tab reads `Welcome to wallabag!`.

STOP: tell the user to read their password with
`sudo grep ADMIN_PASSWORD /srv/wallabag/.env`, put it in their password manager, log in at
https://<DOMAIN>/login as the user `wallabag`, and wait. Do not continue until they confirm
they are looking at an empty article list. There is no password-reset mail on this install, so
that password manager entry is the only copy.

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

Assert: the archive exists and is non-empty. Print its size. The container is stopped for the
copy on purpose: a SQLite file copied mid-write is not a database. Starting it again re-runs
the entrypoint, so wallabag takes another minute or two to answer. That is expected.

A backup on the same disk as the data is not a backup. Run this one from the user's machine,
not the server:

```bash
mkdir -p ~/backups/wallabag
scp vps:/srv/wallabag/backups/*.tar.gz ~/backups/wallabag/
```

To restore: `docker compose down`, `sudo rm -rf /srv/wallabag/data /srv/wallabag/images`,
recreate both directories exactly as step 2 does, untar the archive into /srv/wallabag with
`sudo tar -xzf`, then `docker compose up -d` and wait for /api/info to answer 200. The articles
are in `data/db/wallabag.sqlite`. Tell the user those five commands are the whole disaster
plan.

## 9. Updating later

New versions are listed at https://github.com/wallabag/wallabag/releases. Take the backup
first, then edit the image line in /srv/wallabag/compose.yml to the new tag and its digest:

```bash
cd /srv/wallabag
docker compose pull
docker compose up -d
for i in $(seq 1 60); do curl -sf -o /dev/null http://127.0.0.1:8109/api/info && break; sleep 5; done
docker compose exec -T wallabag su -c '/var/www/wallabag/bin/console doctrine:migrations:migrate --env=prod --no-interaction' -s /bin/sh nobody
docker compose logs --tail 30 wallabag
```

The loop is there because the container is not ready to run a console command until it answers.
The migration command is upstream's documented way to move an existing database to a new
release, and it is safe when there is nothing to migrate. Confirm the version string moved
before calling the update done.

## 10. What will probably go wrong

The first boot looks like a hang. The image's entrypoint deletes the Symfony cache and re-runs
its dependency install every time the container starts, so between `docker compose up -d` and
the first byte of HTML there is a stretch of two to three minutes where port 8109 accepts the
connection and returns nothing. I refreshed eleven times, checked `docker compose ps`, saw
`Up`, and went looking for a proxy misconfiguration that did not exist. Give the loop in step 7
its full sixty attempts, and expect the same pause after every restart, including step 8's.

## 11. Out of scope

- Do not configure SMTP or set `SYMFONY__ENV__MAILER_DSN`. The cost is password-reset mail,
  which is why step 7 makes the user save the password before anything else.
- Do not add a Redis container or start the async import worker. It exists for people importing
  tens of thousands of articles; the browser upload handles an ordinary export.
- Do not change `SYMFONY__ENV__DATABASE_DRIVER` to pdo_mysql or pdo_pgsql. SQLite is the choice
  here and it is what makes the backup in step 8 one file.
- Do not set `SYMFONY__ENV__FOSUSER_REGISTRATION` to true. This install has one account by
  design, and open sign-up on a public hostname is a different service.
