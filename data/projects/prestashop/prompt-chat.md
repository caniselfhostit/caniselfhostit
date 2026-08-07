This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing PrestaShop 9.1.4 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box
and `<ADMIN_EMAIL>` with the address you want to sign in with.

Read this before step 1. The installer writes `<DOMAIN>` into PrestaShop's own shop-url table, so
it ends up inside every product link, image URL and checkout page. Moving the shop to another
hostname later is a database edit, not a config edit. Pick the name you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of RAM is
the one to take seriously here: the image sets PHP's `memory_limit` to 512M, MariaDB wants its
own, and the console installer that runs on first boot is the heaviest thing this shop will ever
do. A 1 GB box gets killed halfway through and leaves half a schema behind.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/prestashop /srv/prestashop/backups
sudo install -d -m 700 /srv/prestashop/mariadb
ls -la /srv/prestashop
```

You should see: `backups` owned by you, and `mariadb` at mode `drwx------` owned by root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. There is no directory here for the shop's own files: step 4 keeps those in a named
volume, because the image copies 300 MB of application into that path on first boot and has to own
what it wrote.

## 3. Secrets

Four values, generated here on the server and written straight into a file only you can read: the
database password, the MariaDB root password, the administrator's password, and the name of the
back-office directory. Replace `<DOMAIN>` and `<ADMIN_EMAIL>` on the first two lines with your
real values before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/prestashop/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all four
values, which is fine before the database exists and a problem afterwards: MariaDB keeps the
password it was created with, so a changed `DB_PASSWORD` against an existing data directory shows
up as a connection failure in the PrestaShop log rather than anything mentioning passwords.

The fourth value is the one that looks out of place. Upstream calls renaming the back-office
directory good practice, the image does that rename for you, and a name printed in a public
document would be the same name on every shop that ever followed it. Yours is random, and it is
also the URL you sign in at, so it goes in your password manager next to the password.

Do not paste that file, any of those four values, or any command output containing them into this
chat window. Read them later with
`sudo grep -E 'PS_FOLDER_ADMIN|ADMIN_PASSWORD' /srv/prestashop/.env`, in your terminal, and put
them straight into your password manager.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/prestashop/compose.yml` and paste again in one go. A warning about
`PS_FOLDER_ADMIN` or `ADMIN_PASSWORD` being unset means step 3 did not write `.env` into
/srv/prestashop, and every one of those `${...}` would resolve to an empty string. Note what this
file does not contain: the image ships `demo@prestashop.com` and a published string as the
defaults for the two admin variables, and both are replaced here by values you generated.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-prestashop /etc/caddy/Caddyfile`, reload,
and paste again. The one line worth understanding is `reverse_proxy`: Caddy terminates TLS and
speaks plain http to the container, and it sets `X-Forwarded-Proto` on the way through. That
header is how PrestaShop decides a request arrived over https and builds its links accordingly.
Strip it in front of Caddy and the shop starts writing `http://` URLs on an https site.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8138` or `3306`.

If you do not: delete anything for `8138` or `3306` with `sudo ufw delete allow 8138`. 8138 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has no
host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and answer the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

On the first start the entrypoint waits for MariaDB, renames the back-office directory, runs
PrestaShop's console installer, then deletes the install directory. That takes several minutes and
Apache does not answer until it finishes, so read step 10 before you conclude anything.

```bash
cd /srv/prestashop
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose logs app | grep -c -- '-- Installation successful! --'
docker compose exec -T app sh -c 'for d in install admin; do [ -d "/var/www/html/$d" ] && echo "$d PRESENT" || echo "$d GONE"; done'
docker compose exec -T app test -f /var/www/html/app/config/parameters.php && echo "parameters OK"
curl -sS -o /dev/null -w '%{http_code}\n' "https://<DOMAIN>/$(sudo grep -m1 '^PS_FOLDER_ADMIN=' /srv/prestashop/.env | cut -d= -f2)/"
```

You should see, in order: the loop climbing through `000` or `502` for several minutes and then
reaching `200`; then `1`; then `install GONE` and `admin GONE`; then `parameters OK`; then `200`.

If you do not: the third line is the one with security meaning. `install PRESENT` means the
console installer did not finish, so a setup wizard is sitting on a public address right now,
and you should take the stack down with `docker compose down` before you debug it. `admin PRESENT`
means `PS_FOLDER_ADMIN` was empty when the container first started, so the back office is at the
path every scanner tries first. If the loop never reaches `200`, run
`docker compose logs --tail 20 db` first, because a database that never reports healthy is step 2
done wrong, and `docker compose logs --tail 80 app` second. `Field admin_email is not valid` in
that log is a typo in `<ADMIN_EMAIL>` back in step 3.

The first screen at your back-office URL shows the PrestaShop logo above a card with the fields
`Email address` and `Password` and a `Log in` button. Read your directory name and password with
`sudo grep -E 'PS_FOLDER_ADMIN|ADMIN_PASSWORD' /srv/prestashop/.env`, put both in your password
manager, then open https://<DOMAIN>/ followed by that directory name and sign in with the address
you used for `<ADMIN_EMAIL>`. Editing `ADMIN_PASSWORD` in .env afterwards changes nothing: it
seeds the account once, and the password then lives in the database.

## 8. First backup and restore

Three artifacts. The dump holds the catalogue, the customers and the orders. The shop archive
holds product images, modules, themes and `app/config/parameters.php`, which carries the cookie
keys PrestaShop generated while installing. The config archive rebuilds the service around both.

```bash
cd /srv/prestashop
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/prestashop/backups/prestashop-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - app/config/parameters.php img modules themes translations upload download > /srv/prestashop/backups/prestashop-shop-$(date +%F).tar.gz
sudo tar -czf /srv/prestashop/backups/prestashop-config-$(date +%F).tar.gz -C /srv/prestashop compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/prestashop/backups/
```

You should see: three files. The dump is a few hundred kilobytes, the shop archive a few hundred
megabytes because the shipped modules and demo images are in it, the config archive a few
kilobytes. Nothing goes offline: `mariadb-dump` reads a consistent snapshot of the InnoDB tables.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump` failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/prestashop
scp vps:/srv/prestashop/backups/* ~/backups/prestashop/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/prestashop/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now read the restore, because the order is not the one you would guess:

```bash
cd /srv/prestashop
docker compose down -v
sudo rm -rf /srv/prestashop/mariadb
sudo install -d -m 700 /srv/prestashop/mariadb
sudo tar -xzf backups/prestashop-config-<date>.tar.gz -C /srv/prestashop compose.yml .env
docker compose up -d db
sleep 30
gunzip -c backups/prestashop-db-<date>.sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose run --rm --no-deps -T app tar -C /var/www/html -xzf - < backups/prestashop-shop-<date>.tar.gz
docker compose up -d
```

You should see: no output from the load, and the shop answering again at https://<DOMAIN>/.

If you do not: the step people get wrong is the second-to-last one. `docker compose run` with a
command replaces the image's start-up script with `tar`, so the volume is created from the image
and your files land on top of it without the installer ever running. Bring the app up before that
and the entrypoint finds no `app/config/parameters.php`, decides this is a fresh machine, and
installs from scratch over the database you restored a minute earlier. Understand the stakes
before you skip the practice run: the dump is every order anyone has ever placed with you.

## 9. Updating later

Two updates that move separately, and this is the part of PrestaShop that surprises people. The
three commands below pull a newer image and restart on it, which changes PHP, Apache and the copy
of PrestaShop inside the image. They do not change the shop: its files already live in the
`prestashop-html` volume, and the entrypoint leaves them alone once `parameters.php` exists.

```bash
cd /srv/prestashop
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

You should see: the app starting without repeating restarts, and the shop answering again.

If you do not: put the old tag and digest back and run the same three commands. Image tags are
listed at https://hub.docker.com/r/prestashop/prestashop/tags and the releases behind them at
https://github.com/PrestaShop/PrestaShop/releases. Take all three backups first, then edit the
image line in /srv/prestashop/compose.yml to the new tag and its digest. Moving PrestaShop itself
to a new version is upstream's Update Assistant, run from the back office under Advanced
Parameters and documented at
https://devdocs.prestashop-project.org/9/basics/keeping-up-to-date/update/. Do that with a fresh
backup and a quiet hour, never during a sale.

## 10. What will probably go wrong

I watched the first `docker compose up -d` sit for six minutes with `curl` returning nothing, and
I was certain it had hung. It had not: the console installer builds 234 tables and loads the demo
catalogue before Apache is ever started, and there is no half-built page to look at meanwhile.
Then the shop opened and it was already selling t-shirts and mugs. That is upstream's fixtures
dataset, loaded because the flag that turns it off is not one the image exposes. Those demo
products and customers delete from the back office; clearing them is the first afternoon of owning
a shop.

## 11. Out of scope

- Do not configure SMTP. This shop records orders without it, and mail that reaches inboxes is
  a separate build: domain reputation, SPF and DKIM, and a relay somebody pays for.
- Do not install a payment module or connect a processor. That is your contract, your money and
  your liability, not a step to take while following an install guide.
- Do not enable PS_DEV_MODE or PS_DEMO_MODE. The first prints stack traces to customers, the
  second turns the back office into a shared demonstration.
- Do not run the Update Assistant now. It is the upgrade path, not a fresh install.
