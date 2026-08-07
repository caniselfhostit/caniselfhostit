You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install WordPress 7.0.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer. Its
A record must already point at this server. Say why when you ask: it becomes `WP_HOME` and
`WP_SITEURL`, and every link on the finished site is built from it.

WordPress plus MySQL 8.4 needs 2048 MB of RAM available and 10 GB free on /srv. Upstream requires
PHP 8.3 or greater and MySQL 8.0 or greater, which the pinned images meet, and states that HTTPS
is required for every install. Both publish amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a name
that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wordpress /srv/wordpress/backups
sudo install -d -m 750 /srv/wordpress/html
sudo install -d -m 700 /srv/wordpress/mysql
ls -la /srv/wordpress
```

Assert: `ls -la` shows `backups` owned by the login user, and `html` and `mysql` owned by root.
Leave both alone. The WordPress entrypoint copies the application into an empty `html` and chowns
it to the `www-data` user Apache runs as, MySQL does the same for its data, and a directory you
chowned yourself first makes MySQL refuse to initialise.

## 3. Secrets

Two secrets: the MySQL root password and the `wordpress` database user's password. Generate both
on the server. Do not print either, do not repeat them in your summary, and do not put them in a
log line. Hex rather than base64: both travel inside connection strings.

```bash
umask 077
cat > /srv/wordpress/.env <<EOF
WORDPRESS_SITE_URL=https://<DOMAIN>
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
WORDPRESS_DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/wordpress/.env
umask 022
ls -l /srv/wordpress/.env
```

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the real
hostname before writing it. Compose reads this file only when it runs from /srv/wordpress, so
every docker command below is preceded by a `cd`. Neither value is a browser login: the account
the user writes with is created in step 7. The eight authentication keys and salts are the image's
job, not this prompt's: it writes a random value for each into wp-config.php, which step 8 backs
up.

## 4. compose.yml

PHP's default caps uploads at 2 MB, smaller than a phone photo, so the first heredoc below writes
the override the image reads from conf.d, and the second writes the compose file:

```bash
cat > /srv/wordpress/uploads.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
EOF
cat > /srv/wordpress/compose.yml <<'EOF'
# WordPress · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image reference .... https://hub.docker.com/_/wordpress
#   wp-config template . https://github.com/docker-library/wordpress/blob/master/wp-config-docker.php
#   mysql image ........ https://hub.docker.com/_/mysql
#
# Two services: WordPress on Apache, and the MySQL it keeps posts, pages and
# settings in. Upstream requires MySQL 8.0 or newer and PHP 8.3 or newer, so
# this runs the MySQL 8.4 long-term series and the 7.0.2-apache tag, which is
# the PHP 8.3 build.
#
# The host's Caddy terminates TLS and this container speaks plain http on 80,
# which its wp-config works out from X-Forwarded-Proto. WP_HOME and WP_SITEURL
# come from .env, read only when Compose runs from /srv/wordpress, so no request
# header can rewrite the site address. The eight authentication keys and salts
# are in neither file: the image writes a random value for each into
# wp-config.php in /srv/wordpress/html, which every backup carries.
#
# Digests read from the registries on 2026-08-06; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mysql:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: wordpress-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    volumes:
      - /srv/wordpress/mysql:/var/lib/mysql
    healthcheck:
      # `$$` sends a literal dollar to the container instead of interpolating.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u root -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      retries: 30
      start_period: 60s
    # No `ports:`: 3306 is reachable only from the other container.

  wordpress:
    image: wordpress:7.0.2-apache@sha256:b2d7e3153c8a96f90305a3102fb6439335237fb1a9655b617d15c5168ce2f7a3
    container_name: wordpress
    restart: unless-stopped
    environment:
      WORDPRESS_DB_HOST: mysql
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_SITE_URL: ${WORDPRESS_SITE_URL}
      # Evaluated inside wp-config.php. The first two make the site address a
      # file rather than a database row; the third removes the admin editor.
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_HOME', getenv('WORDPRESS_SITE_URL'));
        define('WP_SITEURL', getenv('WORDPRESS_SITE_URL'));
        define('DISALLOW_FILE_EDIT', true);
    volumes:
      # Core, themes, plugins, uploads and wp-config.php. Posts are in MySQL.
      - /srv/wordpress/html:/var/www/html
      # PHP's default caps uploads at 2 MB; conf.d is the documented override.
      - /srv/wordpress/uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8152.
      - "127.0.0.1:8152:80"
    depends_on:
      mysql:
        condition: service_healthy
EOF
cd /srv/wordpress && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. A warning that `MYSQL_ROOT_PASSWORD` is not set means the `cd`
did not happen and Compose never found .env; run it again from /srv/wordpress.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-wordpress
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# WordPress · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://developer.wordpress.org/advanced-administration/security/https/,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also WORDPRESS_SITE_URL in .env, which becomes WP_HOME and WP_SITEURL, so the
# two must always agree.

<DOMAIN> {
	# HTML, JSON and theme assets all compress well.
	encode zstd gzip

	# WordPress speaks plain http here and has to be told the visitor did not.
	# reverse_proxy sets X-Forwarded-Proto itself, ignoring what the client
	# sent, and the image's wp-config reads that header.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# No frame-blocking header: the editor and the theme customiser render the
	# site in same-origin iframes, and WordPress sends SAMEORIGIN itself.

	# 8152 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8152
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-wordpress, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it alone.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8152 is bound to 127.0.0.1 and 3306 is never published, so neither has a host port to
firewall. Assert: `ufw status verbose` prints `Status: active`, those three rules, and nothing for
8152 or 3306.

## 7. Start and verify

The first start is slow and step 10 says why, so give the loop below its full run.

```bash
cd /srv/wordpress
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/wp-admin/install.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/wp-admin/install.php | grep -c 'WordPress &rsaquo; Installation'
docker compose exec -T wordpress php -r 'echo ini_get("upload_max_filesize"), "\n";'
```

Assert all three, printing what you received. The loop ends on `200`. The second prints `1`, the
page title WordPress serves while no site exists. The third prints `64M`, step 4's override. If
any misses, stop, run `docker compose logs --tail 40 wordpress` and
`docker compose logs --tail 20 mysql`, and name the likely cause: a MySQL container that never
reports healthy is step 2, a lasting `502` is step 5, a certificate error is step 1's A record.
A running container is not success.

Until the wizard is finished, whoever loads that page becomes the administrator of this site.

STOP: tell the user to open https://<DOMAIN>/wp-admin/install.php and finish the install, and
wait. Do not continue until they confirm. WordPress asks for a language, then shows a form with
`Site Title`, `Username`, `Password`, `Your Email` and a button reading `Install WordPress`. Tell
them to pick a username other than `admin` and to put the password in their password manager
before submitting; the email address is a login and nothing else, because no mail is configured.

Once they confirm, prove the door is shut:

```bash
curl -sS https://<DOMAIN>/wp-admin/install.php | grep -c 'Already Installed'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert: the first prints `1`, the heading WordPress serves once the database holds a site, and the
second `200`. Both must pass before you report success.

## 8. First backup and restore

Two artifacts. MySQL holds the posts, pages, users, comments and settings. The site archive holds
themes, plugins, uploads, wp-config.php with its eight keys, and the files that rebuild the
service.

```bash
cd /srv/wordpress
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers wordpress' | gzip > /srv/wordpress/backups/wordpress-db-$(date +%F).sql.gz
sudo tar -C /srv/wordpress -czf /srv/wordpress/backups/wordpress-site-$(date +%F).tar.gz html compose.yml uploads.ini .env -C /etc/caddy Caddyfile
ls -lh /srv/wordpress/backups/
```

Assert: both exist and both are non-empty. Print both sizes; the archive runs to tens of megabytes
because WordPress core is in it. The password expands in a shell inside the container, so it never
reaches this machine's history, and mysqldump's warning line about it is expected.
`--single-transaction` snapshots a running InnoDB database, so nothing goes offline.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/wordpress
scp vps:/srv/wordpress/backups/* ~/backups/wordpress/
```

To restore: `docker compose down`, `sudo rm -rf /srv/wordpress/mysql /srv/wordpress/html`,
recreate both as in step 2, untar the site archive into /srv/wordpress, `docker compose up -d
mysql`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" wordpress'`, then
`docker compose up -d`. Order matters: the archive carries .env, and MySQL reads its passwords
from it when it initialises an empty data directory.

## 9. Updating later

WordPress updates itself: minor and security releases install in the background into
/srv/wordpress/html, which is how upstream gets fixes onto older sites, so core does not wait for
a `docker compose pull`. The pinned tag governs PHP, Apache and the base system underneath, and
the major version a fresh install starts from. Releases are at
https://wordpress.org/download/releases/ and digests on https://hub.docker.com/_/wordpress. Take
both backups, then edit the image line in compose.yml to the new tag and digest:

```bash
cd /srv/wordpress
docker compose pull
docker compose up -d
docker compose logs --tail 30 wordpress
```

Plugins and themes are the other half of the job and nothing here updates them. Tell the user to
open the Updates screen weekly and to dump the database first.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a broken install for a minute or two. I watched
`docker ps` report two running containers while https://<DOMAIN> answered `502 Bad Gateway`, and
had the Caddy config open hunting for a typo before it cleared on its own. Nothing was wrong.
MySQL spends its first half minute initialising an empty data directory, and the entrypoint then
unpacks WordPress into the empty html directory before Apache binds port 80. The log prints
`WordPress not found in /var/www/html - copying now...` and then `Complete! WordPress has been
successfully copied`. That is what step 7's loop waits for.

## 11. Out of scope

- Do not configure SMTP. WordPress serves the site without it, and mail is a provider choice with
  its own DNS records, made once the user has something to send.
- Do not install plugins or themes. Every plugin is somebody else's PHP running with the site's
  privileges, and which ones are worth that is the user's call.
- Do not set `DISABLE_WP_CRON` or add a system cron job. WordPress runs scheduled work on page
  loads, and moving that to the host is a change to make deliberately, later.
- Do not enable multisite with `WP_ALLOW_MULTISITE`. It rewrites how URLs and users work and
  cannot be undone.
