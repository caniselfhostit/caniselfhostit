This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Akaunting 3.1.21 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box and `<ADMIN_EMAIL>` with the address you want to sign in as.

Read this before step 1. Akaunting is source-available rather than open source, and its licence
grants free production use for up to two users, one company and one thousand invoices. Past any
of those you buy an on-premise plan from upstream. The double-entry ledger, the bank feeds and
the inventory module are separate paid apps; what this installs is invoices, bills, expenses, a
client portal, a profit and loss and a tax summary.

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
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a name that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of
available memory, stop and resize the box: PHP under Apache and a MariaDB on 1 GB is an install
that dies during the first month-end report rather than during the install.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/akaunting /srv/akaunting/backups
sudo install -d -m 700 /srv/akaunting/mariadb
ls -la /srv/akaunting
```

You should see: `backups` owned by you, and `mariadb` at mode `drwx------` owned by root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. There is no directory for the application here, and that is also on
purpose: step 4 keeps it in a named volume, because the image ships Akaunting inside
/var/www/html and a bind mount over that path would hide it.

## 3. Secrets

Three secrets: the MariaDB password for the `akaunting` database user, the MariaDB root
password, and the password the installer puts on your first account. All three are generated
here, on the server, into a file only you can read. Replace `<DOMAIN>` and both copies of
`<ADMIN_EMAIL>` before you paste.

```bash
umask 077
cat > /srv/akaunting/.env <<EOF
APP_URL=https://<DOMAIN>
LOCALE=en-US
COMPANY_NAME=My Company
COMPANY_EMAIL=<ADMIN_EMAIL>
ADMIN_EMAIL=<ADMIN_EMAIL>
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
AKAUNTING_SETUP=true
EOF
chmod 600 /srv/akaunting/.env
umask 022
ls -l /srv/akaunting/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

Do not paste that file, either password, or any command output containing them into this chat
window. The agent path never sees those values; this one hands them to a third party unless you
keep them off the screen. Read your own password once, when step 7 tells you to, and put it
straight into your password manager.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/akaunting/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
all three values, which is fine before the database exists and a problem afterwards: MariaDB
keeps the password it was created with, so a changed `DB_PASSWORD` on an existing data
directory shows up as `Unable to find database!` in the application log rather than as anything
about passwords.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/akaunting/compose.yml <<'EOF'
# Akaunting · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image README ... https://github.com/akaunting/docker/blob/master/README.md
#   entrypoint ..... https://github.com/akaunting/docker/blob/master/files/akaunting.sh
#   variables ...... https://github.com/akaunting/docker/blob/master/env/run.env.example
#
# Akaunting's Apache image and the MariaDB holding the books. /var/www/html is
# a named volume because the image ships the application there and chowns it;
# MariaDB chowns its own directory, so that one is the bind mount. 3.1.21 is the
# newest tag akaunting/docker has published, and 3.2.1 has no image behind it.
# Digests read 2026-08-06, amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: akaunting-db
    restart: unless-stopped
    # Upstream's install page asks for utf8mb4_general_ci.
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_general_ci
    environment:
      MARIADB_DATABASE: akaunting
      MARIADB_USER: akaunting
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - /srv/akaunting/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  akaunting:
    image: akaunting/akaunting:3.1.21@sha256:50940112be48a229a2f567dc50ace9886fe5b14e1fe33f0232e704d0fb96f29f
    container_name: akaunting
    restart: unless-stopped
    environment:
      # The <base href> on every page: the scheme and host Caddy answers on.
      APP_URL: ${APP_URL}
      LOCALE: ${LOCALE}
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: akaunting
      DB_USERNAME: akaunting
      DB_PASSWORD: ${DB_PASSWORD}
      DB_PREFIX: ""
      COMPANY_NAME: ${COMPANY_NAME}
      COMPANY_EMAIL: ${COMPANY_EMAIL}
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      # The installer runs while AKAUNTING_SETUP is set; step 7 deletes it.
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:-}
      AKAUNTING_SETUP: ${AKAUNTING_SETUP:-}
    volumes:
      - akaunting-html:/var/www/html
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8151.
      - "127.0.0.1:8151:80"
    depends_on:
      db:
        condition: service_healthy

volumes:
  akaunting-html:
EOF
cd /srv/akaunting && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/akaunting/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/akaunting/compose.yml` and paste again in one go. Two things in that file are
worth knowing. `AKAUNTING_SETUP` is what makes the container run the installer, once, and step
7 removes it. PHP's own defaults ride along untouched, so an attachment larger than 2 MB is
refused; that ceiling belongs to the image rather than to this file.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-akaunting
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Akaunting · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/akaunting/docker/blob/master/env/run.env.example and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_URL in .env, the <base href> on every page, so the two stay equal.

<DOMAIN> {
	# The interface is HTML and JSON; PDFs are already compressed.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy: invoice templates are editable here, and
	# one written blind breaks a printed invoice rather than an attack.

	# 8151 is the loopback port compose publishes here, not a container
	# port, and not open in the firewall.
	reverse_proxy 127.0.0.1:8151
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-akaunting /etc/caddy/Caddyfile`,
reload, and paste again. The hostname in this block and `APP_URL` in step 3 have to be the same
string: Akaunting prints `APP_URL` as the `<base href>` of every page, so a mismatch shows up as
a login form with no styling rather than as an error.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8151` or `3306`.

If you do not: delete anything for `8151` or `3306` with `sudo ufw delete allow 8151`. 8151 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

MariaDB initialises, then the entrypoint runs `php artisan install`: it writes the
application's own .env inside the volume with a fresh `APP_KEY`, builds the schema, and creates
the company and the account. Apache starts only when that finishes, a minute or two later, so
the first two minutes look like nothing is happening.

```bash
cd /srv/akaunting
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/auth/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/auth/login | grep -o 'Login to start your session'
docker compose logs akaunting | grep -c 'Creating admin'
```

You should see, in order: the loop reaching `200`, the line `Login to start your session`, and
then `1`.

If you do not: run `docker compose logs --tail 60 akaunting`. `Unable to find database!` after
about 30 seconds of retries means step 3's password never reached the database container, which
usually means .env was rewritten after MariaDB had already initialised its data directory.
`Missing options are` means one of the identity values in .env is empty, most often because you
pasted the heredoc with `<ADMIN_EMAIL>` still literal. A `502` that never clears is step 5.
A green `docker compose ps` is not success on its own; the three checks above are.

The first screen at https://<DOMAIN>/ redirects to https://<DOMAIN>/auth/login, which shows the
Akaunting logo over the line `Login to start your session`, an `Email` box, a `Password` box
and a `Login` button.

Now read your password, once, and sign in:

```bash
grep ADMIN_PASSWORD /srv/akaunting/.env
```

You should see: one line with a long random value. Put it in your password manager now, sign in
at https://<DOMAIN>/auth/login with `<ADMIN_EMAIL>`, and rename the company under Settings so
your invoices carry your own name rather than `My Company`. Do not paste that line into this
chat.

If you do not: an empty result means step 3 never ran or was overwritten. There is no
password-reset email on this install, because nothing here sends mail, so if you lose that
value the recovery is a console command on the server rather than a link in your inbox.

Once you are on the dashboard, close the bootstrap out:

```bash
cd /srv/akaunting
sed -i -e '/^ADMIN_PASSWORD/d' -e '/^AKAUNTING_SETUP/d' /srv/akaunting/.env
docker compose up -d --force-recreate akaunting
sleep 45
docker compose logs akaunting | grep -c 'Creating admin' || true
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/auth/login
```

You should see: `0`, then `200`.

If you do not: a count above `0` means the two lines are still in .env, so check
`grep -c AKAUNTING /srv/akaunting/.env` and paste the block again. That `0` is the point of
this step: the replaced container brings Apache up without running the installer a second time,
so there is no second company, no second account, and no bootstrap password sitting on the
disk.

## 8. First backup and restore

Three artifacts. The dump holds the customers, vendors, invoices, bills and transactions. The
application archive holds the .env from inside the volume, whose `APP_KEY` is what Laravel
encrypts sessions and stored credentials with, plus your uploaded attachments. The config
archive rebuilds the service around both.

```bash
cd /srv/akaunting
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --no-tablespaces -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/akaunting/backups/akaunting-db-$(date +%F).sql.gz
docker compose exec -T akaunting tar -C /var/www/html -czf - .env storage modules > /srv/akaunting/backups/akaunting-app-$(date +%F).tar.gz
sudo tar -czf /srv/akaunting/backups/akaunting-config-$(date +%F).tar.gz -C /srv/akaunting compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/akaunting/backups/
```

You should see: three files, the dump a few tens of kilobytes on a fresh install and the
application archive a few megabytes. Nothing goes offline: `--single-transaction` snapshots a
running InnoDB database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump`
failed and the shell created the file anyway. Run the dump line without `| gzip` to read the
error. `--no-tablespaces` is in there because the `akaunting` user is not a superuser and the
dump fails without it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/akaunting
scp vps:/srv/akaunting/backups/* ~/backups/akaunting/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/akaunting/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty company:

```bash
cd /srv/akaunting
docker compose down -v
sudo rm -rf /srv/akaunting/mariadb
sudo install -d -m 700 /srv/akaunting/mariadb
tar -xzf backups/akaunting-config-$(date +%F).tar.gz -C /srv/akaunting compose.yml .env
docker compose up -d db
sleep 30
gunzip -c backups/akaunting-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d akaunting
sleep 90
docker compose exec -T akaunting tar -C /var/www/html -xzf - < backups/akaunting-app-$(date +%F).tar.gz
docker compose restart akaunting
sleep 30
curl -sS https://<DOMAIN>/auth/login | grep -o 'Login to start your session'
```

You should see: the login line again, and your own company name on the dashboard after you sign
in with the same password as before.

If you do not: the order is what matters. The config archive has to land before any container
starts, because MariaDB reads its passwords from .env the moment it initialises an empty data
directory. The application archive has to land after `docker compose up -d akaunting`, because
Docker only fills that volume from the image when it is empty, and the restart afterwards is
what puts the file ownership back. Understand the stakes before you skip this: that database is
what you file taxes from.

## 9. Updating later

Two things move separately here, and it surprises people. A newer image tag moves PHP, Apache
and the image's own copy of the application, but the copy that runs lives in the
`akaunting-html` volume, which Docker filled once and will not fill again. So these three
commands move the runtime and nothing else:

```bash
cd /srv/akaunting
docker compose pull
docker compose up -d
docker compose logs --tail 30 akaunting
```

You should see: Apache starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Image tags are
at https://hub.docker.com/r/akaunting/akaunting/tags and the releases behind them at
https://github.com/akaunting/akaunting/releases. Take all three backups from step 8 first, then
edit the image line in /srv/akaunting/compose.yml to the new tag and its digest. Akaunting
itself moves with the updater upstream documents, one console command:
`docker compose exec -T akaunting php artisan update:all`. Do that with a fresh backup and an
hour when nobody needs the books.

## 10. What will probably go wrong

The first two minutes look like a failed install. `docker compose ps` says the application
container is `Up`, curl returns nothing at all, and the log sits on
`Connecting to database akaunting@db:3306` while the entrypoint retries every five seconds. I
went hunting for the bug and there was not one: the entrypoint runs the whole installer before
Apache starts, so there is no half-built page to look at while it works. Give step 7's loop its
full 40 rounds. When it fails for real it fails loudly, with `Unable to find database!` after
30 seconds of retries, and that points at step 3.

## 11. Out of scope

- Do not configure SMTP. Akaunting runs without it, and the cost is that Email Invoice does
  nothing, so you send the PDF or the portal link yourself.
- Do not add a cron container or a scheduler service. Nothing here runs Laravel's scheduler, so
  recurring invoices and reminder mail never fire.
- Do not enter an Akaunting API key or install anything from the app store. Those apps are
  purchases tied to an akaunting.com account, and the double-entry ledger is one of them.
- Do not create a second company or extra user accounts. The licence grants production use for
  one company and two users.
