This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing LimeSurvey 7.0.7 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box, and `<ADMIN_EMAIL>` with the address for your administrator account.

Read this before step 1. `<DOMAIN>` becomes `HOST_INFO`, the address LimeSurvey puts inside
every survey link and every participant invitation. Moving it later means every link you have
already sent stops working, so pick the hostname you intend to keep.

One more thing worth knowing up front: LimeSurvey publishes no Docker image of its own. The
image below, `martialblog/limesurvey`, is a community image under the MIT licence, maintained
outside the LimeSurvey project. Its Dockerfile downloads the official LimeSurvey 7.0.7+260729
release tarball from LimeSurvey's own repository and checks its sha256 before unpacking it, so
the application is upstream's; the packaging around it is not.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 1024 MB of RAM is
the other common stop: PHP and MariaDB in one box is the floor here, and the OOM killer arriving
during a survey activation looks like a LimeSurvey bug rather than a hosting decision.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/limesurvey /srv/limesurvey/backups
sudo install -d -m 700 /srv/limesurvey/mariadb
ls -la /srv/limesurvey
```

You should see: `backups` owned by you, and `mariadb` at mode `drwx------` owned by root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. There is deliberately no directory here for LimeSurvey's uploads: step 4 keeps
those in a named volume, because the image ships that directory's base content and an empty host
folder mounted over it would hide the themes and plugins the release comes with.

## 3. Secrets

Five secrets: the database password, the MariaDB root password, the administrator's password,
and the two data-encryption values LimeSurvey uses for participant records. All five are
generated here, on the server, and all five go straight into a file only you can read.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` and
`<ADMIN_EMAIL>` on the first two lines with your real values before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/limesurvey/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
all five values, which is fine before the database exists and a problem afterwards: MariaDB
keeps the password it was created with, and the two encryption values are how LimeSurvey reads
back anything it has already encrypted.

Do not paste that file, any of those five values, or any command output containing them into
this chat window. Those 24 and 32 hex bytes are the nonce and secret-box key lengths
LimeSurvey's own generator produces; keep them, because changing either one later means
encrypted participant records stop decrypting, permanently and with no recovery path.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/limesurvey/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/limesurvey/compose.yml` and paste again in one go. A warning that a variable is not
set means one of the five names in .env does not match the ones above, and the image's
entrypoint exits rather than starting with a blank password, which is the behaviour you want.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-limesurvey /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the container, which is why
`HOST_INFO` in .env says `https://`: without it LimeSurvey would build `http://` links for a
service only reachable over https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8130` or `3306`.

If you do not: delete anything for `8130` or `3306` with `sudo ufw delete allow 8130`. 8130 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and answer the
ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

On the first start the entrypoint waits for MariaDB, writes LimeSurvey's config, then runs the
console installer. Read step 10 before you interpret the log.

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

You should see, in order: the loop reaching `200`, then `1`, then `1`, then `1`, then `1`.

If you do not: the third line is the one worth understanding. It is the security check. Once
`application/config/config.php` exists, LimeSurvey's installer refuses to run and answers
`Installation has been done already. Installer disabled.`, so a `0` there means a setup form is
sitting open on a public hostname and you stop everything until it is not. A `0` on the second
line with a `200` from the loop usually means Caddy reached something other than LimeSurvey. If
the loop never gets to `200`, run `docker compose logs --tail 20 db` first, because a database
that never reports healthy is step 2 done wrong, and `docker compose logs --tail 60 app` second.
The last number is the count of administrator accounts, and `1` is the whole point: the account
was made by a console command with a generated password, not by anyone who found a setup wizard.

The first screen at https://<DOMAIN>/index.php/admin shows the heading `Administration` above
the words `Log in`, with a username field and a password field.

Now sign in. Read your password with `sudo grep ADMIN_PASSWORD /srv/limesurvey/.env`, put it in
your password manager, and log in as the user `admin`. Do not paste the password into this chat
window. Editing that line in .env afterwards changes nothing: it seeded the account once, and
the password now lives in the database and moves in the profile screen.

## 8. First backup and restore

Three artifacts. The dump holds every survey, question and response. The upload archive holds
themes, plugins and participant file uploads. The config archive rebuilds the service around
them and carries the encryption keys, without which the other two are half-readable.

```bash
cd /srv/limesurvey
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/limesurvey/backups/limesurvey-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - upload > /srv/limesurvey/backups/limesurvey-upload-$(date +%F).tar.gz
sudo tar -czf /srv/limesurvey/backups/limesurvey-config-$(date +%F).tar.gz -C /srv/limesurvey compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/limesurvey/backups/
```

You should see: three files, the dump and the config archive a few kilobytes on a fresh install
and the upload archive a little larger.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump` failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error. The
dump takes a read lock on each table as it reads it, because the survey tables are MyISAM and
there is no transaction to snapshot instead; on a fresh install that is under a second.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/limesurvey
scp vps:/srv/limesurvey/backups/* ~/backups/limesurvey/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/limesurvey/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/limesurvey
docker compose down
sudo rm -rf /srv/limesurvey/mariadb
sudo install -d -m 700 /srv/limesurvey/mariadb
docker compose up -d db
sleep 30
gunzip -c /srv/limesurvey/backups/limesurvey-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/index.php/admin/authentication/sa/login | grep -c 'x-test id="action::login"'
```

You should see: some `CREATE TABLE` chatter from the client, then `1` from the last command,
which means the login page came back from a database that was deleted and rebuilt.

If you do not: `Access denied for user` means .env was not in place before the database
container initialised its empty directory, so it created itself with a different password. That
is also why the restore order matters: untar the config archive first, always. Understand what
the encryption keys do while you are here. They live only in .env, they are written into the
container at every start, and a restore without them gives you rows you cannot read.

## 9. Updating later

Application versions are listed at https://github.com/LimeSurvey/LimeSurvey/tags and the image
tags that carry them at https://github.com/martialblog/docker-limesurvey/tags. Take all three
backup artifacts first, then edit the app `image:` line in /srv/limesurvey/compose.yml to the new
tag and its digest.

```bash
cd /srv/limesurvey
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

You should see: the config already provisioned, a database migration pass, then Apache starting,
and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. The entrypoint
runs `console.php updatedb` on every start, so the schema migrates itself, which also means a
half-finished migration is a real state to land in. Re-run all five checks from step 7 before
you call the update done.

## 10. What will probably go wrong

The first `docker compose logs app` prints a full PHP stack trace and reads like a failed
install. Mine did, and I spent ten minutes on it before noticing the line above telling me to
never mind the trace. That is the entrypoint asking an empty database whether it has been
migrated; the only way to ask is to try, and the try throws. The line after it reads
`Running console.php install`, which is the install working. If step 7 does fail, look for a
line about the connection to `db` instead.

## 11. Out of scope

- Do not configure SMTP. Anonymous link surveys are the whole product without it, and mail is
  what invitations and reminders need: a second install to do properly.
- Do not enable the RemoteControl API. It is off by default, and turning it on adds a credential
  nobody here is holding.
- Do not use ComfortUpdate or the in-app updater. This container is pinned by digest, and an
  updater rewriting files inside it puts the running code out of step with the tag.
- Do not switch the database to PostgreSQL. The image supports it and MariaDB is the choice here.
