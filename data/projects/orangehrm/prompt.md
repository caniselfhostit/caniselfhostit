You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install OrangeHRM Starter 5.9 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here. Architecture is a gate, not a preference: the
`orangehrm/orangehrm:5.9` tag publishes one image manifest and it is `linux/amd64`. OrangeHRM
needs 2048 MB of RAM available and 5 GB free on /srv, and the database grows with every uploaded
document, because attachments live in it as blobs, not on disk.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If the architecture is anything but `amd64`, print it and stop: there is no arm64 build to fall
back to. If available RAM is under 2048 MB or free disk under 5 GB, print both and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
name that does not resolve, and failed attempts spend a hidden rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/orangehrm /srv/orangehrm/backups
sudo install -d -m 700 /srv/orangehrm/mariadb
ls -la /srv/orangehrm
```

Assert: `ls -la` shows `backups` owned by the login user and `mariadb` at mode `700` owned by
root. The MariaDB image chowns its own data directory on first start, so leave that alone. The
application gets no directory here: its image declares `/var/www/html` a `VOLUME` and step 4
gives it a named Docker volume, because a bind mount would lay an empty folder over it.

## 3. Secrets

Two: the MariaDB root password and the password of the `orangehrm` database user. Generate both
on the server. Do not print either, do not repeat them in your summary, do not log them. Hex
rather than base64, because Compose reads these back out of `.env`, where a `$` would be
interpolated and a `#` would start a comment.

```bash
umask 077
cat > /srv/orangehrm/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 24)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/orangehrm/.env
umask 022
ls -l /srv/orangehrm/.env
```

Assert: the file exists with mode `-rw-------`. `DB_PASSWORD` is not only a compose variable:
OrangeHRM's installer is a browser wizard with nothing behind it to configure from outside, so at
step 7 the user reads that value and types it in. Give them the command then, not the value now.
The root password is typed nowhere; MariaDB refuses to start without one of its root options.

## 4. compose.yml

```bash
cat > /srv/orangehrm/compose.yml <<'EOF'
# OrangeHRM Starter · the deterministic fallback. Authored by caniselfhostit
# from the upstream packaging, not copied from a repository:
#   image build ....... https://github.com/orangehrm/orangehrm/blob/v5.9/Dockerfile
#   supported engines . https://github.com/orangehrm/orangehrm/blob/v5.9/installer/config/system_requirements.php
#   mariadb image ..... https://hub.docker.com/_/mariadb
#
# OrangeHRM Starter 5.9 on Apache with PHP 8.3, and the MariaDB holding every
# employee record. The image has no configuration environment variables: its
# browser installer writes lib/confs/Conf.php inside /var/www/html, which is why
# that path is a named volume. The database values are what that installer asks
# for with `Existing Empty Database` chosen. Digests read on 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mariadb:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: orangehrm-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: orangehrm
      MARIADB_USER: orangehrm
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      # The bind mount goes here: MariaDB chowns its own data directory.
      - /srv/orangehrm/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 15s
      interval: 10s
      retries: 30
    # No `ports:` at all: 3306 is reachable only from the other container.

  orangehrm:
    image: orangehrm/orangehrm:5.9@sha256:d692780efbb118b1ede754cfb153057baecf4c4c5f84627621ed015cf837ac28
    platform: linux/amd64
    container_name: orangehrm
    restart: unless-stopped
    # OrangeHRM reads the HTTPS server variable, never X-Forwarded-Proto, and
    # that sets the cookie's Secure flag and the scheme on every redirect. Only
    # Caddy reaches this container, and only over https.
    command: ["apache2-foreground", "-c", "SetEnv HTTPS on"]
    volumes:
      # The application, lib/confs/Conf.php included. Losing it loses the
      # install, not the data: the data is in MariaDB.
      - orangehrm-app:/var/www/html
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8194.
      - "127.0.0.1:8194:80"
    depends_on:
      mariadb:
        condition: service_healthy

volumes:
  orangehrm-app:
EOF
cd /srv/orangehrm && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. MariaDB creates the `orangehrm` database and its user on first
start and stops there, with no tables in it, which is the `Existing Empty Database` the wizard
asks about at step 7. That branch keeps the root credential out of a browser; the other needs a
user that can create databases and users.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site here.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-orangehrm
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# OrangeHRM Starter · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://caddyserver.com/docs/automatic-https and
# https://github.com/orangehrm/orangehrm/blob/v5.9/src/plugins/orangehrmCorePlugin/config/CorePluginConfiguration.php
#
# Append to /etc/caddy/Caddyfile with <DOMAIN> replaced by this box's hostname.

<DOMAIN> {
	encode zstd gzip

	# HSTS earns its place: OrangeHRM reads the scheme off the server environment,
	# which the compose file's Apache line sets, and this is the other half of it.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "same-origin"
		-Server
	}

	# 8194 is the loopback port compose publishes here, not a container port and
	# not open in the firewall.
	reverse_proxy 127.0.0.1:8194
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-orangehrm, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it alone.

## 6. Firewall

Two ports, both Caddy's, and idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8194 is bound to 127.0.0.1 and 3306 is never published, so neither belongs here. Assert:
`ufw status verbose` prints `Status: active`, those three, and no rule for 8194 or 3306.

## 7. Start and verify

Read the block first. OrangeHRM 5.9 has no environment variable that creates an administrator and
no scriptable installer: its command line installer refuses non-interactive mode outright. Only a
person in a browser can finish this, and until one does the hostname serves a setup wizard to
whoever loads it first. The wizard cannot pass its database screen without the password in a
mode-600 file here, and a finished install refuses the installer for good. Both narrow the
window; neither closes it, so hand it over the moment it answers.

```bash
cd /srv/orangehrm
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL https://<DOMAIN>/ | grep -c 'welcome-screen'
docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SELECT 1" "$MARIADB_DATABASE"'
```

Assert all three and print what you received. The loop ends printing `200`. The grep prints `1`:
an uninstalled OrangeHRM redirects its root into the installer, and that page carries the
`welcome-screen` component in its markup. The query prints `1` under a `1` heading, which is the
credential the wizard is about to be handed. A `0` from the grep means either Caddy is reaching
something other than this container or somebody has already finished this wizard, and the second
means rebuilding the box, so stop either way. On any other miss run
`docker compose logs --tail 40 orangehrm` and name the likely earlier step.

Give the user these four:

- Database Configuration: pick `Existing Empty Database`, then host `mariadb`, port `3306`,
  database `orangehrm`, user `orangehrm`, password from
  `sudo grep DB_PASSWORD /srv/orangehrm/.env`.
- Leave `Enable Data Encryption` unticked. It writes a key file every later backup has to carry,
  or the encrypted columns come back unreadable.
- Admin User screen: untick the box offering to register the system with OrangeHRM. It is ticked
  by default, and ticked it posts their name, email, phone and organisation name to OrangeHRM.
- The admin password wants 8 characters or more, no spaces, and a lower-case letter, an
  upper-case letter, a digit and a symbol.

STOP: tell the user to open https://<DOMAIN>, complete the setup wizard, and say when they reach
the screen that reports the installation is complete.
Do not continue until they confirm.

Now prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' 'https://<DOMAIN>/installer/index.php/installer/database-config'
curl -sSL https://<DOMAIN>/ | grep -c 'auth-login'
```

Assert both and print the values. The first prints `502`: with the configuration file written
upstream refuses every installer screen, and that is the security assert here. The second prints
`1`, the login component the root now redirects to. Anything but `502` means the wizard did not
finish and this install is still claimable, so stop and send the user back.

## 8. First backup and restore

Three artifacts. The dump holds every employee, leave request, timesheet and uploaded document.
The confs archive holds `lib/confs/Conf.php`; the config archive rebuilds the service around
both.

```bash
cd /srv/orangehrm
docker compose exec -T mariadb sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction "$MARIADB_DATABASE"' | gzip > backups/orangehrm-db-$(date +%F).sql.gz
docker compose exec -T orangehrm tar -C /var/www/html -czf - lib/confs > backups/orangehrm-confs-$(date +%F).tar.gz
sudo tar -czf backups/orangehrm-config-$(date +%F).tar.gz -C /srv/orangehrm compose.yml .env -C /etc/caddy Caddyfile
ls -lh backups/
```

Assert: all three exist, all three are non-empty, all three sizes printed. Nothing stops;
`--single-transaction` reads a consistent snapshot of the InnoDB tables. The MariaDB directory is
never archived: a copy of a live one is a corrupt database with a backup's name.

A backup on the same disk is not a backup. Run this on the user's machine:

```bash
mkdir -p ~/backups/orangehrm
scp vps:/srv/orangehrm/backups/* ~/backups/orangehrm/
```

To restore, in order. `docker compose down -v` drops the application volume and leaves the
MariaDB bind mount alone. `sudo rm -rf /srv/orangehrm/mariadb`, recreate it as in step 2, untar
the config archive into /srv/orangehrm so `.env` is back first, then
`docker compose up -d mariadb` and wait for healthy. Pipe `gunzip -c` on the dump into
`docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Put the configuration file back before Apache serves a request:
`docker compose run --rm --no-deps -T orangehrm tar -C /var/www/html -xzf - < backups/orangehrm-confs-<date>.tar.gz`,
which fills the fresh volume from the image and swaps the web server for `tar`. Then
`docker compose up -d`. Order matters: start the application first and it hands a setup wizard to
the internet in front of a database of staff records.

## 9. Updating later

Releases are at https://github.com/orangehrm/orangehrm/releases, image tags at
https://hub.docker.com/r/orangehrm/orangehrm/tags. Block 8's three backups are a prerequisite:
this is the one operation here that can lose data.

A newer image alone changes nothing: Docker fills a named volume from the image only when the
volume does not exist, so a pull on a new tag leaves 5.9 running in `orangehrm-app`. Upgrading
means taking the volume away. Edit the image line to the new tag and digest, then:

```bash
cd /srv/orangehrm
docker compose down
docker volume rm orangehrm_orangehrm-app
docker compose pull
docker compose up -d
```

The new code arrives with no `lib/confs/Conf.php`, so the site is a setup wizard again. Open it,
choose `Upgrading an Existing Installation`, give it step 7's database details, and pick the
version being upgraded from. Do not restore the confs archive into an upgrade: the new code
writes its own. Upstream's upgrader screen says to point it at a copy of the database, not the
original, because a failed migration does not roll back.

## 10. What will probably go wrong

The 1 MB ceiling on attachments will find you, and it will not look like a ceiling. OrangeHRM
sets its maximum attachment size as a constant in its own source, 1048576 bytes, with no
administration screen and no environment variable behind it, so when the form refuses a scanned
contract there is nothing here to turn up. I went looking for twenty minutes before reading the
source. Tell the user on day one: the answer is a second place to keep documents, not a setting.

## 11. Out of scope

- Do not configure SMTP or the Email Configuration screen. Leave and timesheet notifications are
  mail this install does not send, and the core loop works without them.
- Do not add a cron container. At 5.9 the only scheduled tasks upstream registers are LDAP user
  sync and workspace notification sends, both dormant unless turned on in the interface.
- Do not configure LDAP or an OpenID Connect provider. Both ship here, and both are a second
  system to keep working.
