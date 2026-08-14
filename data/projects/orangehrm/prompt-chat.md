This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing OrangeHRM Starter 5.9 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1, because it decides whether you want this install at all. OrangeHRM 5.9
has no environment variable that creates an administrator and no scriptable installer: its own
command line installer refuses non-interactive mode outright. The only thing that finishes this
install is you, in a browser, and between the moment the container answers and the moment you
finish that wizard, the hostname is showing a setup wizard to whoever loads it first. Step 7 is
written so that gap is minutes rather than an afternoon, and it ends by proving the door is shut.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `5` G free, `amd64`, and your server's IP
on the last line.

If you do not: `amd64` is not a preference here. The `orangehrm/orangehrm:5.9` tag on Docker Hub
publishes one image manifest and it is `linux/amd64`, so an `arm64` box has nothing to run and
this install stops here. An empty last line means the A record does not exist yet: add it, wait a
minute, run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that
does not resolve and failed attempts spend a rate limit you cannot see. The 2 GB floor is PHP
under Apache plus a MariaDB, and the disk figure matters more over time than it looks: OrangeHRM
stores uploaded documents in the database as blobs, so the database is where the growth lands.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/orangehrm /srv/orangehrm/backups
sudo install -d -m 700 /srv/orangehrm/mariadb
ls -la /srv/orangehrm
```

You should see: `backups` owned by you, and `mariadb` at mode `drwx------` owned by `root`.

If you do not: those two owners are deliberate. The MariaDB image chowns its own data directory
the first time it starts, so leaving that one to root is correct rather than sloppy. There is no
directory here for the application itself, and that is also deliberate: its image declares
`/var/www/html` as a `VOLUME`, step 4 gives it a named Docker volume, and a bind mount there
would put an empty folder over the application and leave you staring at an Apache error page.

## 3. Secrets

Two secrets, both generated on the server, neither of them printed here. `DB_PASSWORD` is the
password of the `orangehrm` database user, and `MARIADB_ROOT_PASSWORD` exists because the MariaDB
image refuses to start unless one of its three root options is set. Hex rather than base64,
because Compose reads these back out of `.env`, where a `$` would be interpolated and a `#` would
start a comment.

**Do not paste the contents of `.env`, either password, or any command output containing one into
this chat window.** The values below never leave your server unless you carry them out. You will
need `DB_PASSWORD` yourself at step 7, in a browser, and the command to read it is there.

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

You should see: one line beginning `-rw-------`, owned by you.

If you do not: a mode with any group or other bits set means `umask 077` did not take, most often
because the heredoc was pasted without the first line. Delete the file and run the whole block
again from `umask 077`. If `openssl` is missing, `sudo apt-get install -y openssl` first; do not
substitute a password you thought of yourself, because you will reuse it somewhere else.

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

You should see: `compose OK`.

If you do not: `docker compose config` prints the line it objected to. A complaint about
`DB_PASSWORD` or `MARIADB_ROOT_PASSWORD` being unset means you are not in `/srv/orangehrm`, since
Compose reads `.env` from the directory it runs in. A YAML indentation error means the heredoc
picked up your terminal's autoindent: paste it again into a fresh session. What this file sets up
is an empty `orangehrm` database with an `orangehrm` user on it, which is exactly the
`Existing Empty Database` the wizard asks about at step 7, and taking that branch is what keeps
the root credential out of a browser.

## 5. Caddy and TLS

Copy the Caddyfile first, because a syntax error in it takes down every other site on this box
and the copy is how you get them back. Replace `<DOMAIN>` in the block below with your real
hostname before you paste it: it appears twice, once in a comment and once as the site address.

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

You should see: `Valid configuration` from validate, and nothing at all from the reload.

If you do not: restore with
`sudo cp /etc/caddy/Caddyfile.before-orangehrm /etc/caddy/Caddyfile && sudo systemctl reload caddy`
and read what validate objected to. The usual cause is `<DOMAIN>` left literal, which Caddy reads
as a hostname it cannot get a certificate for. Replace it with your real hostname everywhere it
appears in the block above and run the whole thing again.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 80/tcp, 443/tcp and 443/udp and nothing else new.

If you do not: an inactive firewall means Prompt Zero did not finish; `sudo ufw enable` and read
its warning about your session before you answer. If 8194 or 3306 appears in that list, remove it
with `sudo ufw delete allow 8194` or `sudo ufw delete allow 3306`. Neither belongs there: 8194 is
bound to 127.0.0.1 so only Caddy reaches it, and 3306 is never published to the host at all.

## 7. Start and verify

```bash
cd /srv/orangehrm
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL https://<DOMAIN>/ | grep -c 'welcome-screen'
docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SELECT 1" "$MARIADB_DATABASE"'
```

You should see: the loop ending on `200`, then `1`, then a `1` under a `1` heading.

If you do not: a loop that runs out still printing `000` is DNS or a certificate, so check
`dig +short <DOMAIN>` and `sudo journalctl -u caddy --no-pager -n 30`. A `502` means Caddy is up
and the container is not, so read `docker compose logs --tail 40 orangehrm`. A `0` from the grep
is the serious one: either Caddy is reaching something other than this container, or somebody has
already finished this wizard on your hostname, and the second case means rebuilding this box
rather than carrying on. If the query is refused, the wizard would be refused the same way, so
read `docker compose logs --tail 20 mariadb` before going further.

Now go and claim the install, and do it now rather than after lunch. Read all four of these
first, because two of them cannot be undone afterwards.

- Open https://<DOMAIN> in a browser. On the Database Configuration screen, select
  `Existing Empty Database`, then enter host `mariadb`, port `3306`, database name `orangehrm`,
  user `orangehrm`, and the password you read with `sudo grep DB_PASSWORD /srv/orangehrm/.env`.
- Leave `Enable Data Encryption` unticked. Ticking it writes a key file that every backup from
  then on has to carry, or the encrypted columns come back unreadable, and it is decided once.
- On the Admin User screen, untick the box offering to register your system with OrangeHRM. It is
  ticked by default, and ticked it posts your name, email address, telephone number, organisation
  name and a profile of this server to OrangeHRM's registration endpoint.
- Your admin password needs 8 characters or more, no spaces, and a lower-case letter, an
  upper-case letter, a digit and a symbol. Put it in your password manager before you submit it.
  Nothing on this server can reset it for you.

When the wizard reports the installation is complete, prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' 'https://<DOMAIN>/installer/index.php/installer/database-config'
curl -sSL https://<DOMAIN>/ | grep -c 'auth-login'
```

You should see: `502`, then `1`.

If you do not: `502` here is upstream's own answer, not an error. Once the configuration file
exists, OrangeHRM refuses every installer screen, for good, and that refusal is the security
assert in this step. Anything else on the first command means the wizard did not actually finish
and your hostname is still claimable by a stranger, so go back and finish it before you do
anything else. A `0` from the second means the root is not landing on the sign-in page; read
`docker compose logs --tail 40 orangehrm` before touching the Caddyfile.

## 8. First backup and restore

Three artifacts. The dump holds every employee, leave request, timesheet and uploaded document,
because attachments live in the database as blobs rather than on disk. The confs archive holds
`lib/confs/Conf.php`, the file the wizard wrote, which is the only thing between an installed
system and an open setup wizard. The config archive rebuilds the service around both.

```bash
cd /srv/orangehrm
docker compose exec -T mariadb sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction "$MARIADB_DATABASE"' | gzip > backups/orangehrm-db-$(date +%F).sql.gz
docker compose exec -T orangehrm tar -C /var/www/html -czf - lib/confs > backups/orangehrm-confs-$(date +%F).tar.gz
sudo tar -czf backups/orangehrm-config-$(date +%F).tar.gz -C /srv/orangehrm compose.yml .env -C /etc/caddy Caddyfile
ls -lh backups/
```

You should see: three files, all three non-empty, with their sizes.

If you do not: a zero-byte dump means the database credentials in `.env` are not the ones the
wizard was given, so re-read them and check the wizard used `mariadb` as the host rather than
`localhost`. Nothing stops during this: `--single-transaction` reads a consistent snapshot of the
InnoDB tables while the site stays up. The MariaDB directory itself is deliberately not archived,
because a copy of a live InnoDB directory is a corrupt database wearing a backup's extension.

A backup on the same disk is not a backup. Run this one on your own machine, not the server:

```bash
mkdir -p ~/backups/orangehrm
scp vps:/srv/orangehrm/backups/* ~/backups/orangehrm/
```

To restore, in this order. `docker compose down -v`, which drops the application volume and
leaves the MariaDB bind mount alone. `sudo rm -rf /srv/orangehrm/mariadb`, then recreate it as in
step 2. Untar the config archive into /srv/orangehrm so `.env` is back before anything starts.
`docker compose up -d mariadb`, wait until `docker compose ps` shows it healthy, then pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Put the configuration file back before Apache ever serves a request:
`docker compose run --rm --no-deps -T orangehrm tar -C /var/www/html -xzf - < backups/orangehrm-confs-<date>.tar.gz`,
which fills the fresh volume from the image and swaps the web server for `tar` in one step.
Finally `docker compose up -d`. That order is the whole disaster plan, and the reason for it is
step 7: start the application before that one file is back and it hands a setup wizard to the
internet in front of a database of staff records.

## 9. Updating later

Releases are listed at https://github.com/orangehrm/orangehrm/releases and the image tags at
https://hub.docker.com/r/orangehrm/orangehrm/tags. Take all three backups first. This is the one
operation on this page that can lose data, and upstream says so itself.

A newer image on its own changes nothing, and this surprises people. The application lives in the
`orangehrm-app` volume, and Docker fills a named volume from the image only when the volume does
not yet exist, so pulling a new tag leaves 5.9 running. Upgrading means taking the volume away.
Edit the image line in `/srv/orangehrm/compose.yml` to the new tag and its digest first, then:

```bash
cd /srv/orangehrm
docker compose down
docker volume rm orangehrm_orangehrm-app
docker compose pull
docker compose up -d
```

You should see: `docker volume rm` printing the volume name it removed, then a pull that actually
downloads layers, then both containers coming back up.

If you do not: `volume is in use` means the `down` did not finish, so run it again and check
`docker compose ps` is empty first. If the volume name is wrong, run `docker volume ls` and look
for your project directory name followed by `_orangehrm-app`.

The new code arrives with no `lib/confs/Conf.php`, so your site is a setup wizard again. Open it,
choose `Upgrading an Existing Installation` rather than a fresh install, give it the same
database details from step 7, and pick the version you are coming from in the dropdown. Do not
restore the confs archive into an upgrade: the point is that the new code writes its own. That
open window is step 7's claim race a second time, and it closes the same way. Upstream's own
upgrader screen tells you to point it at a copy of your database rather than the original,
because a failed migration does not roll back, so the careful version of this is to rehearse
against a restored dump somewhere else before you touch the live one.

## 10. What will probably go wrong

The 1 MB ceiling on attachments will find you, and it will not look like a ceiling. OrangeHRM
sets its maximum attachment size as a constant in its own source, 1048576 bytes, with no
administration screen and no environment variable behind it, and a fixed list of accepted file
types beside it. So the first time somebody drags a scanned contract onto an employee record and
the form refuses it, there is nothing on this server to turn up. I went looking for that setting
for twenty minutes before reading the source. Decide on day one where documents actually live,
because a 1 MB cap is a different product from the one you may think you are moving off.

## 11. Out of scope

- Do not configure SMTP or the Email Configuration screen. Leave and timesheet notifications are
  mail this install does not send, and the core loop works without them.
- Do not add a cron container. At 5.9 the only scheduled tasks upstream registers are LDAP user
  sync and workspace notification sends, both dormant unless you turn them on in the interface,
  so nothing is silently not running.
- Do not configure LDAP or an OpenID Connect provider. Both ship in this edition, and both are a
  second system to keep working.
