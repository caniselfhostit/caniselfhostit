You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install WordPress 7.0.2 and the MySQL 8 it stores posts in under ~/selfhost/wordpress,
answering at http://localhost:8152.

## 1. Preflight

Say this before step 2 runs, because it decides whether they want this install: WordPress here
answers at an address only this computer can open, so no reader, phone or client ever sees it.
What they get is the editor and the whole site on their own disk.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash, and on Linux
the distribution ID prints too, for step 2. WordPress plus MySQL 8.4 wants 2048 MB of RAM
available and 10 GB free on the home disk, and both images publish amd64 and arm64. On macOS
and Windows the memory figure is the host's, and Docker Desktop takes its share out of it.
Under either floor, print both numbers and stop.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they
  confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/wordpress/html ~/selfhost/wordpress/backups
if [ "$(uname -s)" = "Linux" ]; then sudo chown 33:33 ~/selfhost/wordpress/html; fi
ls -la ~/selfhost/wordpress
```

Assert: `ls -la` shows `html` and `backups`. On Linux `html` now belongs to uid 33, the
`www-data` the image runs as, which is what lets WordPress install its own updates later; on
macOS and Windows that line is a no-op, because Docker Desktop settles ownership itself.

## 4. Secrets

Two secrets: the MySQL root password and the `wordpress` user's database password. Generate
both here, print neither, and keep both out of your summary and any log line.

```bash
umask 077
cat > ~/selfhost/wordpress/.env <<EOF
WORDPRESS_SITE_URL=http://localhost:8152
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
WORDPRESS_DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/wordpress/.env
umask 022
ls -l ~/selfhost/wordpress/.env
```

Assert: the file exists with mode `-rw-------`; Git Bash ships openssl, so these lines run the
same everywhere. Compose reads .env only from ~/selfhost/wordpress, so every docker command
below starts with a `cd`, and neither value is a browser login: that account comes in step 7.
On Windows those mode bits are advisory, and the boundary is the user's own account.

## 5. compose.yml

The first heredoc lifts PHP's 2 MB upload cap, smaller than a phone photo, in the conf.d file
the image reads; the second writes the compose file:

```bash
cat > ~/selfhost/wordpress/uploads.ini <<'EOF'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
EOF
cat > ~/selfhost/wordpress/compose.yml <<'EOF'
# WordPress · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image reference .... https://hub.docker.com/_/wordpress
#   wp-config template . https://github.com/docker-library/wordpress/blob/master/wp-config-docker.php
#   mysql image ........ https://hub.docker.com/_/mysql
#
# Two services on the computer you are sitting at, every path relative to
# ~/selfhost/wordpress/, which lets one file work on macOS, Linux and Windows.
# MySQL's data directory is a named volume because that image chowns it to its
# own uid, which a home-directory bind mount cannot allow on Windows; the site
# files stay a bind mount so themes, plugins and uploads show up in Finder or
# Explorer. Upstream requires MySQL 8.0 or newer and PHP 8.3 or newer, so this
# runs MySQL 8.4 and the 7.0.2-apache tag, the PHP 8.3 build.
#
# Nothing terminates TLS here, so WP_HOME and WP_SITEURL are the http address
# in .env, read when Compose runs from this folder. The eight authentication
# keys and salts are in neither file: the image writes a random value for each
# into wp-config.php in ./html, which every backup carries.
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
      - wordpress-mysql-data:/var/lib/mysql
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
      - ./html:/var/www/html
      # PHP's default caps uploads at 2 MB; conf.d is the documented override.
      - ./uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8152.
      - "127.0.0.1:8152:80"
    depends_on:
      mysql:
        condition: service_healthy

volumes:
  wordpress-mysql-data:
EOF
cd ~/selfhost/wordpress && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. A warning that `MYSQL_ROOT_PASSWORD` is not set means the
`cd` did not happen.

## 6. Nothing is public

Everything binds to loopback. There is no domain to resolve and no certificate, because there
is nothing to certify; browsers treat http://localhost as a secure context, so the editor works
normally. There is no firewall rule because nothing is published beyond this machine: 8152
answers on 127.0.0.1 and nowhere else, not on the user's phone, not on a laptop on the same
wifi, not on the internet. That is the point of this path, not a defect. Confirm it:

```bash
grep -n '"127.0.0.1:' ~/selfhost/wordpress/compose.yml
```

Assert: exactly one line, `- "127.0.0.1:8152:80"`. The pattern carries the quote and colon so
the MySQL healthcheck's own 127.0.0.1 does not count; MySQL publishes no host port.

## 7. Start and verify

The first start is slow; step 10 says why.

```bash
cd ~/selfhost/wordpress
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8152/wp-admin/install.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8152/wp-admin/install.php | grep -c 'WordPress &rsaquo; Installation'
```

Assert both, printing what you received: `200`, then `1`, the title served while no site
exists. If either misses, stop, run `docker compose logs --tail 40 wordpress` and
`docker compose logs --tail 20 mysql`, and name the likely cause: a MySQL that never reports
healthy is step 4, where an empty `MYSQL_ROOT_PASSWORD` stops it starting; a WordPress still
copying files wants more time. A running container is not success.

STOP: tell the user to open http://localhost:8152/wp-admin/install.php and finish the install,
and wait. Do not continue until they confirm. WordPress asks for a language, then a form with
`Site Title`, `Username`, `Password`, `Your Email` and a button reading `Install WordPress`.
The password goes in their password manager first, and the email address is only a login,
because no mail is configured.

Once they confirm, prove the door is shut:

```bash
curl -sS http://localhost:8152/wp-admin/install.php | grep -c 'Already Installed'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8152/
```

Assert: `1`, the heading WordPress serves once the database holds a site, then `200`. Both must
pass before you report success.

## 8. First backup and restore

A dump with the posts, pages, users and settings, and an archive with the themes, plugins,
uploads, wp-config.php and the files that rebuild the service.

```bash
cd ~/selfhost/wordpress
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers wordpress' | gzip > ~/selfhost/wordpress/backups/wordpress-db-$(date +%F).sql.gz
sudo tar -C ~/selfhost/wordpress -czf ~/selfhost/wordpress/backups/wordpress-site-$(date +%F).tar.gz html compose.yml uploads.ini .env
ls -lh ~/selfhost/wordpress/backups/
```

Assert: both exist, both non-empty, both sizes printed; the archive is tens of megabytes,
because WordPress core is in it. `sudo` is for Linux, where the files inside `html` belong to
uid 33. The password expands inside the container, so it never reaches this shell's history.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`. Assert: they confirm both arrived.

To restore: untar the archive into ~/selfhost/wordpress first, so .env is back before any
container starts, because MySQL reads its passwords from it when it initialises an empty
volume. Then `docker compose down -v`, the one place `-v` belongs, `docker compose up -d
mysql`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" wordpress'`,
then `docker compose up -d` and load http://localhost:8152/.

## 9. Updating later

WordPress updates itself: minor and security releases install in the background into
~/selfhost/wordpress/html, so core does not wait for a `docker compose pull`. The pinned tag
governs PHP, Apache and the system under it.
Releases are at https://wordpress.org/download/releases/ and digests on
https://hub.docker.com/_/wordpress. Back up first, then edit the image line to the new tag and
digest:

```bash
cd ~/selfhost/wordpress
docker compose pull
docker compose up -d
docker compose logs --tail 30 wordpress
```

Plugins and themes update separately, and nothing here does it for them: tell the user to open
the Updates screen weekly, after the dump.

## 10. What will probably go wrong

Something scheduled will not happen when you expect it. I set a post to publish at 06:00, left
the laptop closed, opened the site after lunch and found it had gone live at 12:04, the minute
I loaded a page. WordPress keeps no timer of its own: it runs scheduled work during somebody's
page load, and here the only somebody is you. Nothing is broken; a site nobody visits is one
where scheduled posts and update checks happen the next time you look.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not install plugins or themes for the user. Every plugin is somebody else's PHP running
  with the site's privileges, and that choice is theirs.
- Do not set `DISABLE_WP_CRON`, add a cron job as a fix for step 10, or configure SMTP: nothing
  here sends mail.
