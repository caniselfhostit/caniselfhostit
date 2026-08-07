You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install PrestaShop 9.1.4 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until they
answer. The installer writes `<DOMAIN>` into PrestaShop's shop-url table as `PS_DOMAIN`, making it
the address inside every product link and checkout page, and its A record must already point here.
`<ADMIN_EMAIL>` is the login of the one back-office account this creates.

PrestaShop and its database need 2048 MB of RAM available and 10 GB free on /srv: the image sets
PHP's `memory_limit` to 512M and MariaDB wants its own. Both publish amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a name nobody can resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/prestashop /srv/prestashop/backups
sudo install -d -m 700 /srv/prestashop/mariadb
ls -la /srv/prestashop
```

Assert: `backups` owned by the login user, `mariadb` at mode `700` owned by root. Leave it
alone; the MariaDB image chowns its own data directory and refuses one somebody claimed first. The
shop's files get no directory here: step 4 keeps them in a named volume, because the image copies
300 MB of application into that path and must own what it wrote.

## 3. Secrets

Four values, all generated here: the database password, the MariaDB root password, the
administrator's password, and the name of the back-office directory. Print none of them, and keep
them out of your summary and every log line.

```bash
umask 077
cat > /srv/prestashop/.env <<EOF
PS_DOMAIN=<DOMAIN>
ADMIN_EMAIL=<ADMIN_EMAIL>
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
PS_FOLDER_ADMIN=admin-$(openssl rand -hex 4)
EOF
chmod 600 /srv/prestashop/.env
umask 022
ls -l /srv/prestashop/.env
```

Assert: mode `-rw-------` and the login user's name twice. The fourth value looks out of place and
is not: upstream calls renaming the back-office directory good practice, the image performs the
rename, and a name written into a prompt that ships to strangers is the same on every shop that
ran it. This one is per install, and without it nobody signs in.

## 4. compose.yml

```bash
cat > /srv/prestashop/compose.yml <<'EOF'
# PrestaShop · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker guide ..... https://devdocs.prestashop-project.org/9/basics/installation/environments/docker/
#   image entrypoint . https://github.com/PrestaShop/docker/blob/master/base/config_files/docker_run.sh
#   mariadb image .... https://hub.docker.com/_/mariadb
#
# Apache with PHP 8.5 serving PrestaShop 9.1.4, and the MariaDB holding the
# catalogue and the orders. Every ${...} comes from /srv/prestashop/.env, mode
# 600. /var/www/html is a named volume because the image copies the application
# into it on first boot with `cp -p` and must keep the ownership Apache needs,
# as upstream's own example does. Digests read 2026-08-06, amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: prestashop-db
    restart: unless-stopped
    # Upstream asks for utf8mb4_general_ci, not MariaDB 11.8's own default.
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_general_ci
    environment:
      MARIADB_DATABASE: prestashop
      MARIADB_USER: prestashop
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      # The bind mount goes here: MariaDB chowns its own data directory.
      - /srv/prestashop/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  app:
    image: prestashop/prestashop:9.1.4-apache@sha256:2f339136154feddf679f9dd6868542466e760f54865a95ae2d0fb065efb14a1f
    container_name: prestashop-app
    restart: unless-stopped
    environment:
      DB_SERVER: db
      DB_NAME: prestashop
      DB_USER: prestashop
      DB_PASSWD: ${DB_PASSWORD}
      # Runs the console installer once, then deletes install/ itself.
      PS_INSTALL_AUTO: "1"
      PS_ERASE_DB: "0"
      PS_FOLDER_ADMIN: ${PS_FOLDER_ADMIN}
      PS_FOLDER_INSTALL: install
      # Caddy sets X-Forwarded-Proto, which is how PrestaShop knows https.
      PS_DOMAIN: ${PS_DOMAIN}
      PS_ENABLE_SSL: "1"
      PS_COUNTRY: GB
      ADMIN_MAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWD: ${ADMIN_PASSWORD}
    volumes:
      - prestashop-html:/var/www/html
    ports:
      # Loopback only: the host's Caddy is the one thing reaching 8138.
      - "127.0.0.1:8138:80"
    depends_on:
      db:
        condition: service_healthy

volumes:
  prestashop-html:
EOF
cd /srv/prestashop && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No default credential survives this file: the image's defaults
for the two admin variables are a demo address and a published string, overridden by step 3.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-prestashop
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# PrestaShop · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://devdocs.prestashop-project.org/9/basics/installation/environments/docker/ and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box, the same value as PS_DOMAIN in .env.

<DOMAIN> {
	encode zstd gzip

	# PrestaShop sets its own cache and cookie headers; these are the rest. The
	# referrer is trimmed so a checkout URL does not travel onward.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8138 is the loopback port compose publishes here, not a container port and
	# not open in the firewall. reverse_proxy sets X-Forwarded-Proto itself,
	# which is how PrestaShop knows a request is https.
	reverse_proxy 127.0.0.1:8138
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-prestashop, reload,
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
HTTP/3. 8138 is on 127.0.0.1 and 3306 is never published, so neither has a host port to firewall.
Assert: `Status: active`, rules for 80, 443/tcp and 443/udp, nothing else.

## 7. Start and verify

On first start the entrypoint waits for MariaDB, renames the back-office directory, runs
PrestaShop's console installer, then deletes the install directory. Apache answers only when that
finishes, several minutes later.

```bash
cd /srv/prestashop
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose logs app | grep -c -- '-- Installation successful! --'
docker compose exec -T app sh -c 'for d in install admin; do [ -d "/var/www/html/$d" ] && echo "$d PRESENT" || echo "$d GONE"; done'
docker compose exec -T app test -f /var/www/html/app/config/parameters.php && echo "parameters OK"
curl -sS -o /dev/null -w '%{http_code}\n' "https://<DOMAIN>/$(grep -m1 '^PS_FOLDER_ADMIN=' /srv/prestashop/.env | cut -d= -f2)/"
```

Assert all five, printing what you received for each. The loop ends on `200`, the storefront. The
second prints `1`, the installer's own success line. The third prints `install GONE` and
`admin GONE`, the security assert here: an install directory left in place is a second setup
wizard on a public address, and a back office at the guessable path is what everybody scans for.
The fourth prints `parameters OK`, the last `200` for the login page at the generated path,
without putting that path in your output. If any of the five misses, stop, run
`docker compose logs --tail 80 app` and name the likely step: a database that never reports
healthy is step 2, a lasting `502` is step 5, `Field admin_email is not valid` a typo in step 3.
A running container is not success.

The first screen at the back-office URL shows the PrestaShop logo above a card with the fields
`Email address` and `Password` and a `Log in` button.

STOP: tell the user to read the two values they need with
`sudo grep -E 'PS_FOLDER_ADMIN|ADMIN_PASSWORD' /srv/prestashop/.env`, put both in their password
manager, then open https://<DOMAIN>/ followed by that directory name and sign in with
`<ADMIN_EMAIL>`. Wait, and do not continue until they confirm they are on the dashboard. Editing
`ADMIN_PASSWORD` later changes nothing: it seeds the account once.

## 8. First backup and restore

Three artifacts: the dump holds the catalogue, the customers and the orders; the shop archive
holds product images, modules, themes and `app/config/parameters.php` with the cookie keys the
installer generated; the config archive rebuilds the service around both.

```bash
cd /srv/prestashop
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/prestashop/backups/prestashop-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - app/config/parameters.php img modules themes translations upload download > /srv/prestashop/backups/prestashop-shop-$(date +%F).tar.gz
sudo tar -czf /srv/prestashop/backups/prestashop-config-$(date +%F).tar.gz -C /srv/prestashop compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/prestashop/backups/
```

Assert: all three exist, all three are non-empty, all three sizes printed. The shop archive runs
to a few hundred megabytes: the shipped modules and demo images are in it. Nothing stops:
`mariadb-dump` reads a consistent snapshot of the InnoDB tables.

A backup on the same disk is not a backup. Run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/prestashop
scp vps:/srv/prestashop/backups/* ~/backups/prestashop/
```

To restore, in this order: `docker compose down -v`, `sudo rm -rf /srv/prestashop/mariadb`,
recreate it as in step 2, untar the config archive into /srv/prestashop so `.env` is back first,
`docker compose up -d db`, wait 30 seconds for healthy, then pipe `gunzip -c` on the `.sql.gz`
into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Then put the shop files back before the app container runs its start-up script:
`docker compose run --rm --no-deps -T app tar -C /var/www/html -xzf - < backups/prestashop-shop-<date>.tar.gz`.
That swaps the script for `tar`, so files land on a volume the image has filled. Finally
`docker compose up -d`. Order matters: the entrypoint looks for `app/config/parameters.php` to
decide whether to install from scratch, so starting the app first reruns the installer and drops
what was restored a minute earlier.

## 9. Updating later

Two updates that move separately. A newer image tag changes PHP, Apache and the image's copy of
PrestaShop, but the shop's files live in the `prestashop-html` volume and the entrypoint leaves
them alone once `parameters.php` exists, so these three commands move the runtime, not the shop:

```bash
cd /srv/prestashop
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

Image tags are at https://hub.docker.com/r/prestashop/prestashop/tags and the releases behind
them at https://github.com/PrestaShop/PrestaShop/releases. Take all three backups first, then
edit the image line in compose.yml to the new tag and digest. Moving PrestaShop itself
is upstream's Update Assistant, in the back office under Advanced Parameters, documented at
https://devdocs.prestashop-project.org/9/basics/keeping-up-to-date/update/. Do that with a fresh
backup and a quiet hour, never during a sale.

## 10. What will probably go wrong

I watched the first `docker compose up -d` sit for six minutes with `curl` returning nothing,
certain it had hung. It had not: the console installer builds 234 tables and loads the demo
catalogue before Apache is ever started, and there is no half-built page to look at meanwhile.
Then the shop opened and it was already selling t-shirts and mugs. That is upstream's fixtures
dataset, loaded because the flag that turns it off is not one the image exposes. Those demo
products and customers delete from the back office; clearing them is the first afternoon of
owning a shop.

## 11. Out of scope

- Do not configure SMTP. This shop records orders without it, and mail that reaches inboxes is
  a separate build: domain reputation, SPF and DKIM, and a relay somebody pays for.
- Do not install a payment module or connect a processor. That is the user's contract, their
  money and their liability, not a step an agent takes for them.
- Do not enable PS_DEV_MODE or PS_DEMO_MODE. The first prints stack traces to customers, the
  second turns the back office into a shared demonstration.
- Do not run the Update Assistant now. It is the upgrade path, not a fresh install.
