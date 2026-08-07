This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing WordPress 7.0.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` becomes `WP_HOME` and `WP_SITEURL`, the address every menu
link, redirect and image URL on the finished site is built from. Moving the site to another
hostname later means editing one file and reissuing a certificate, so pick the name you intend
to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve and failed attempts count against a rate limit you cannot see. Under 2048 MB of RAM is
the case worth taking seriously: PHP and MySQL 8.4 both want room, and the OOM killer arrives
during your first image upload rather than now. Upstream's own requirements are PHP 8.3 or
greater and MySQL 8.0 or greater, which the pinned images below satisfy.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wordpress /srv/wordpress/backups
sudo install -d -m 750 /srv/wordpress/html
sudo install -d -m 700 /srv/wordpress/mysql
ls -la /srv/wordpress
```

You should see: `backups` owned by you, and `html` and `mysql` owned by root.

If you do not: leave both owned by root on purpose. The WordPress entrypoint starts as root,
copies the whole application into an empty `html` and chowns it to the `www-data` user Apache
runs as; the MySQL image does the same for its data directory, and a directory you have already
chowned to yourself makes MySQL refuse to initialise.

## 3. Secrets

Two secrets: the MySQL root password and the password for the `wordpress` database user. Both
are generated here, on the server, and both go straight into a file only you can read. Hex
rather than base64, because both travel inside connection strings.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/wordpress/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
both secrets, which is fine before the database exists and a problem afterwards: MySQL keeps
the password it was created with, so a changed value on an existing data directory shows up as
a connection error in the WordPress log rather than as anything about passwords.

Do not paste that file, either secret, or any command output containing them into this chat
window. Neither value is a login you will type into a browser: the account you write with is
created in step 7. WordPress also wants eight authentication keys and salts, and you are not
generating those: the image writes a random value for each into wp-config.php the first time it
starts, and step 8 backs that file up.

## 4. compose.yml

PHP's own default caps uploads at 2 MB, which is smaller than a photo from a phone. The first
heredoc below writes the override the image reads from conf.d, the second writes the compose
file. Paste each block whole, including its last line.

```bash
cat > /srv/wordpress/uploads.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
EOF
```

You should see: no output at all, which is what a successful heredoc looks like.

If you do not: `cat: /srv/wordpress/uploads.ini: Permission denied` means step 2 did not run, or
ran as a different user.

```bash
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

You should see: `compose OK` and nothing else.

If you do not: a warning that `MYSQL_ROOT_PASSWORD` is not set means the `cd` did not happen and
Compose never found .env, so run the last line again from /srv/wordpress. `services must be a
mapping` means the indentation was lost between the page and your terminal: run
`rm /srv/wordpress/compose.yml` and paste the block again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-wordpress /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the container, which is why the
site block matters beyond the certificate: its `reverse_proxy` sets X-Forwarded-Proto, and the
image's wp-config reads that header to work out that the visitor arrived over https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8152` or `3306`.

If you do not: delete anything for `8152` or `3306` with `sudo ufw delete allow 8152`. 8152 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to answer the ACME challenge and
redirect to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

MySQL initialises an empty data directory, and the WordPress entrypoint then copies the whole
application into /srv/wordpress/html. Both finish long after `docker ps` shows two containers,
so the loop below runs for up to seven minutes on purpose.

```bash
cd /srv/wordpress
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/wp-admin/install.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/wp-admin/install.php | grep -c 'WordPress &rsaquo; Installation'
docker compose exec -T wordpress php -r 'echo ini_get("upload_max_filesize"), "\n";'
```

You should see, in order: the loop climbing through `502` and reaching `200`, then `1`, then
`64M`.

If you do not: a loop that never leaves `502` for seven minutes is worth investigating with
`docker compose logs --tail 40 wordpress` and `docker compose logs --tail 20 mysql`. A MySQL
container that never reports healthy is step 2 done wrong. A `1` that comes back as `0` means
something is answering at that address which is not this WordPress. `64M` printing as `2M` means
the uploads.ini from step 4 is missing, so Docker mounted a directory in its place: remove
`/srv/wordpress/uploads.ini` if it is a directory, write the file again, and
`docker compose up -d --force-recreate wordpress`.

Now open https://<DOMAIN>/wp-admin/install.php in a browser and finish the install. Until you
do, whoever loads that page becomes the administrator of this site, so do it now rather than
tomorrow. WordPress asks for a language first, then shows a form with `Site Title`, `Username`,
`Password`, `Your Email` and a button reading `Install WordPress`. Choose a username that is not
`admin`, put the password in your password manager before you submit, and know that the email
address is a login and nothing else here, because no mail is configured.

Then prove the door is shut:

```bash
curl -sS https://<DOMAIN>/wp-admin/install.php | grep -c 'Already Installed'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `1`, the heading WordPress serves once the database holds a site, then `200`
from your new home page.

If you do not: a `0` from the first command means the wizard did not complete, so open the
address again and finish it. A running container is not success, and neither is a `200` on the
installer.

## 8. First backup and restore

Two artifacts. MySQL holds the posts, pages, users, comments and settings. The site archive
holds the themes, the plugins, the uploads, wp-config.php with its eight generated keys, and the
files that rebuild the service around them.

```bash
cd /srv/wordpress
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers wordpress' | gzip > /srv/wordpress/backups/wordpress-db-$(date +%F).sql.gz
sudo tar -C /srv/wordpress -czf /srv/wordpress/backups/wordpress-site-$(date +%F).tar.gz html compose.yml uploads.ini .env -C /etc/caddy Caddyfile
ls -lh /srv/wordpress/backups/
```

You should see: two files, the dump a few hundred kilobytes and the archive tens of megabytes,
because WordPress core is inside it. Nothing goes offline: `--single-transaction` snapshots a
running InnoDB database consistently.

If you do not: one warning line from mysqldump about passwords on the command line is expected
and harmless. A `.sql.gz` of about 20 bytes is an empty dump, which means mysqldump failed and
the shell created the file anyway, so run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/wordpress
scp vps:/srv/wordpress/backups/* ~/backups/wordpress/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/wordpress/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty site:

```bash
cd /srv/wordpress
docker compose down
sudo rm -rf /srv/wordpress/mysql /srv/wordpress/html
sudo install -d -m 750 /srv/wordpress/html
sudo install -d -m 700 /srv/wordpress/mysql
sudo tar -C /srv/wordpress -xzf /srv/wordpress/backups/wordpress-site-$(date +%F).tar.gz html
docker compose up -d mysql
sleep 45
gunzip -c /srv/wordpress/backups/wordpress-db-$(date +%F).sql.gz | docker compose exec -T mysql sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" wordpress'
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `200` from the last command, from a site whose database and files were both
deleted and rebuilt a minute earlier.

If you do not: `ERROR 1045 (28000): Access denied` means .env and the data directory disagree
about the password, which happens if you rewrote .env after MySQL first started. `Error
establishing a database connection` in a browser means MySQL had not finished initialising when
the load ran, so wait and repeat the `gunzip` line. These are the seven commands that are your
whole disaster plan; the tar extracts only `html` because compose.yml and .env are already in
place.

## 9. Updating later

WordPress updates itself. Minor and security releases install in the background into
/srv/wordpress/html, which is how upstream gets fixes onto older sites, so core does not wait
for a `docker compose pull`. What the pinned tag governs is PHP, Apache and the base system
underneath, and the major version a fresh install starts from. Releases are listed at
https://wordpress.org/download/releases/ and digests on https://hub.docker.com/_/wordpress. Take
both backups first, then edit the image line in /srv/wordpress/compose.yml to the new tag and
digest.

```bash
cd /srv/wordpress
docker compose pull
docker compose up -d
docker compose logs --tail 30 wordpress
```

You should see: the containers recreated, then Apache's start-up lines, and no repeating
restart.

If you do not: put the old tag and digest back and run the same three commands. Then load the
site and the admin before you call the update done. Plugins and themes are the other half of
this job and nothing here updates them: open the Updates screen in the admin every week, and
dump the database before you apply anything.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a broken install for a minute or two. I watched
`docker ps` report two running containers while https://<DOMAIN> answered `502 Bad Gateway`, and
had the Caddy config open hunting for a typo before it cleared on its own. Nothing was wrong.
MySQL spends its first half minute initialising an empty data directory, and the entrypoint then
unpacks WordPress into the empty html directory before Apache binds port 80. The log prints
`WordPress not found in /var/www/html - copying now...` and then `Complete! WordPress has been
successfully copied`. That is what step 7's loop waits for.

## 11. Out of scope

- Do not configure SMTP. WordPress serves the site without it, and mail is a provider choice
  with its own DNS records, made once you have something to send.
- Do not install plugins or themes yet. Every plugin is somebody else's PHP running with the
  site's privileges, and the shorter that list stays, the less there is to keep patched.
- Do not set `DISABLE_WP_CRON` or add a system cron job. WordPress runs scheduled work on page
  loads, and moving that to the host is a change to make deliberately, later.
- Do not enable multisite with `WP_ALLOW_MULTISITE`. It rewrites how URLs and users work and
  cannot be undone from the admin.
