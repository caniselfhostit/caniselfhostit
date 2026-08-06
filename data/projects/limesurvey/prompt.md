You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install LimeSurvey 7.0.7 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` becomes `HOST_INFO`, the address inside every survey link, and its A
record must already point here. `<ADMIN_EMAIL>` goes on the administrator account the installer
creates, stored rather than mailed to, because this install configures no mail.

LimeSurvey and its database need 1024 MB of RAM available and 5 GB free on /srv. Both images
publish amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name nobody can resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/limesurvey /srv/limesurvey/backups
sudo install -d -m 700 /srv/limesurvey/mariadb
ls -la /srv/limesurvey
```

Assert: `backups` owned by the login user, `mariadb` at mode `700` owned by root. Leave that one
alone; the MariaDB image chowns its own data directory and refuses one somebody claimed first.
Uploads get no directory here: step 4 keeps those in a named volume.

## 3. Secrets

Five secrets, all generated here: the database password, the MariaDB root password, the
administrator's password, and the two encryption values LimeSurvey uses for participant records.
Print none of them, and keep them out of your summary and every log line.

```bash
umask 077
cat > /srv/limesurvey/.env <<EOF
HOST_INFO=https://<DOMAIN>
ADMIN_EMAIL=<ADMIN_EMAIL>
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
ENCRYPT_NONCE=$(openssl rand -hex 24)
ENCRYPT_SECRET_BOX_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/limesurvey/.env
umask 022
ls -l /srv/limesurvey/.env
```

Assert: mode `-rw-------` and the login user's name twice. Those 24 and 32 hex bytes are the
nonce and secret-box key lengths LimeSurvey's own generator produces. Tell the user, without
printing anything, that this file is now the most valuable object on the box: change those two
values and encrypted participant records stop decrypting for good.

## 4. compose.yml

```bash
cat > /srv/limesurvey/compose.yml <<'EOF'
# LimeSurvey · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   requirements ..... https://www.limesurvey.org/manual/Installation_-_LimeSurvey_CE
#   config reference . https://www.limesurvey.org/manual/Optional_settings
#   image README ..... https://github.com/martialblog/docker-limesurvey/blob/7.0.7-260729/README.md
#   image entrypoint . https://github.com/martialblog/docker-limesurvey/blob/7.0.7-260729/7.0/apache/entrypoint.sh
#
# The LimeSurvey project publishes no Docker image. martialblog/limesurvey is a
# community image, MIT, maintained outside that project; its Dockerfile fetches
# the official LimeSurvey 7.0.7+260729 tarball and checks its sha256.
#
# Two services: Apache with PHP, and the MariaDB it keeps surveys and responses
# in. Every ${...} comes from /srv/limesurvey/.env, mode 600. `upload` is a named
# volume because the image ships that directory's base content, which a bind
# mount would hide. Digests read 2026-08-06; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: limesurvey-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: limesurvey
      MARIADB_USER: limesurvey
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - /srv/limesurvey/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  app:
    image: martialblog/limesurvey:7.0.7-260729-apache@sha256:556d09839640f4702ee5ef6618a426c68f0688ded967b2805a0bd903a241f051
    container_name: limesurvey-app
    restart: unless-stopped
    environment:
      DB_TYPE: mysql
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: limesurvey
      DB_USERNAME: limesurvey
      DB_PASSWORD: ${DB_PASSWORD}
      # Upstream's default engine for the wide table each survey gets. InnoDB
      # caps a row near 8 KB, which a long questionnaire goes past.
      DB_MYSQL_ENGINE: MyISAM
      # The entrypoint exits without ADMIN_PASSWORD; these four seed the
      # LimeSurvey console installer once, on first boot.
      ADMIN_USER: admin
      ADMIN_NAME: Site administrator
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      # Caddy terminates TLS, so LimeSurvey is told the scheme and host it
      # should build absolute links from.
      HOST_INFO: ${HOST_INFO}
      # Written to application/config/security.php on every start. Change
      # either one and encrypted participant data stops decrypting.
      ENCRYPT_NONCE: ${ENCRYPT_NONCE}
      ENCRYPT_SECRET_BOX_KEY: ${ENCRYPT_SECRET_BOX_KEY}
    volumes:
      - limesurvey-upload:/var/www/html/upload
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8080/index.php/admin/authentication/sa/login || exit 1"]
      start_period: 30s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8130.
      # The container listens on 8080 and runs as www-data, not root.
      - "127.0.0.1:8130:8080"
    depends_on:
      db:
        condition: service_healthy

volumes:
  limesurvey-upload:
EOF
cd /srv/limesurvey && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The image's entrypoint exits with an error if `DB_PASSWORD` or
`ADMIN_PASSWORD` is missing, so this install has no default account and no blank password.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-limesurvey
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# LimeSurvey · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/martialblog/docker-limesurvey/blob/7.0.7-260729/README.md and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also HOST_INFO in .env, and it is the
# address inside every survey link you hand out.

<DOMAIN> {
	encode zstd gzip

	# LimeSurvey sets its own framing and content-security headers on the
	# admin side; these are the rest. The referrer is trimmed because a
	# shared survey link would otherwise carry its token onward.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8130 is the loopback port compose publishes on this host, not a
	# container port and not open in the firewall. Caddy passes the Host
	# header through, which is what the image README asks of a proxy in
	# front of LimeSurvey, and the image reads a response's client address
	# from X-Real-IP through Apache's mod_remoteip.
	reverse_proxy 127.0.0.1:8130 {
		header_up X-Real-IP {remote_host}
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-limesurvey, reload,
and report the objection. Caddy gets the certificate on the first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8130 is bound to 127.0.0.1 and 3306 is never published, so neither has a host port.
Assert: `Status: active`, rules for 80, 443/tcp and 443/udp, nothing else.

## 7. Start and verify

On the first start the entrypoint waits for MariaDB, writes LimeSurvey's config, then runs the
console installer. Read step 10 before interpreting that log.

```bash
cd /srv/limesurvey
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/index.php/admin/authentication/sa/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/index.php/admin/authentication/sa/login | grep -c 'x-test id="action::login"'
curl -sS https://<DOMAIN>/index.php/installer | grep -c 'Installation has been done already'
docker compose exec -T app grep -c "'hostInfo' => 'https://<DOMAIN>'" application/config/config.php
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from lime_users" "$MARIADB_DATABASE"'
```

Assert all five, printing what you received for each. The loop ends on `200`. The second prints
`1`: that marker is the tag LimeSurvey's own test suite looks for to confirm the login page
rendered, so PHP reached the database. The third prints `1`, the security assert here, because a
config file exists and the browser installer now refuses whoever finds that URL. The fourth
prints `1`, so absolute links carry https and the right hostname. The fifth prints `1`, one
administrator, made by the console installer rather than a form on a public address. If any of
the five misses, stop, run `docker compose logs --tail 60 app` and
`docker compose logs --tail 20 db`, and name the likely step: a database that never reports
healthy is step 2, a lasting `502` is step 5. A running container is not success.

The first screen at https://<DOMAIN>/index.php/admin shows the heading `Administration` above
the words `Log in`, with a username and a password field.

STOP: tell the user to read their administrator password with
`sudo grep ADMIN_PASSWORD /srv/limesurvey/.env`, put it in their password manager, sign in at
https://<DOMAIN>/index.php/admin as the user `admin`, and wait. Do not continue until they
confirm they are on the dashboard. Editing that value in .env afterwards changes nothing: it
seeds the account once, and the password then lives in the database.

## 8. First backup and restore

Three artifacts: a dump holding every survey, question and response, an archive of themes,
plugins and participant uploads, and the config archive that rebuilds the service around them
and carries the encryption keys the other two need.

```bash
cd /srv/limesurvey
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/limesurvey/backups/limesurvey-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - upload > /srv/limesurvey/backups/limesurvey-upload-$(date +%F).tar.gz
sudo tar -czf /srv/limesurvey/backups/limesurvey-config-$(date +%F).tar.gz -C /srv/limesurvey compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/limesurvey/backups/
```

Assert: all three exist, all three are non-empty, all three sizes printed. The dump read-locks
each table as it reads it, because the survey tables are MyISAM and there is no transaction to
snapshot. On a fresh install that is under a second.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/limesurvey
scp vps:/srv/limesurvey/backups/* ~/backups/limesurvey/
```

To restore: `docker compose down`, `sudo rm -rf /srv/limesurvey/mariadb`, recreate it as in
step 2, untar the config archive into /srv/limesurvey so `.env` is back first,
`docker compose up -d db`, wait about 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz`
into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`, then the uploads with
`docker compose exec -T app tar -C /var/www/html -xzf - < backups/limesurvey-upload-<date>.tar.gz`.
Tell the user why `.env` comes back first: MariaDB reads its password from it the moment it
initialises an empty directory, and its encryption values are the only way restored participant
data decrypts.

## 9. Updating later

Application versions are listed at https://github.com/LimeSurvey/LimeSurvey/tags and the image
tags carrying them at https://github.com/martialblog/docker-limesurvey/tags. Take all three
backups first, then edit the app image line in /srv/limesurvey/compose.yml to the new tag and
digest:

```bash
cd /srv/limesurvey
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

The entrypoint runs `console.php updatedb` on every start, so a version bump migrates the schema
on its own. Watch that log until it settles, then re-run step 7's five checks.

## 10. What will probably go wrong

The first `docker compose logs app` prints a full PHP stack trace and reads like a failed
install. Mine did, and I spent ten minutes on it before noticing the line above telling me to
never mind the trace. That is the entrypoint asking an empty database whether it has been
migrated; the only way to ask is to try, and the try throws. The line after
it reads `Running console.php install`, which is the install working. If step 7 does fail, look
for a line about the connection to `db` instead.

## 11. Out of scope

- Do not configure SMTP. Anonymous link surveys are the whole product without it, and mail is
  what invitations and reminders need: a second install to do properly.
- Do not enable the RemoteControl API. It is off by default, and turning it on adds a credential
  nobody here is holding.
- Do not use ComfortUpdate or the in-app updater. This container is pinned by digest, and an
  updater rewriting files inside it puts the running code out of step with the tag.
- Do not switch the database to PostgreSQL. The image supports it and MariaDB is the choice here.
