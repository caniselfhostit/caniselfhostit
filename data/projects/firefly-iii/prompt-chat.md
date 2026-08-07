This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Firefly III 6.6.6 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1, because it is the expectation Firefly III does not meet. It has no
bank connection. Nothing you install here logs into a bank, and no transaction appears by
itself. You export a CSV from your bank and import it, or you type transactions in, or you run
the separate Firefly III Data Importer on a second hostname and pay a data provider such as
SimpleFIN. That last option is not part of this install.

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
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of
available RAM, stop and resize the box rather than watching PHP and MariaDB fight the OOM
killer during your first import.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/firefly-iii /srv/firefly-iii/backups
sudo install -d -m 700 /srv/firefly-iii/mariadb
sudo install -d -m 750 -o 33 -g 33 /srv/firefly-iii/upload
ls -la /srv/firefly-iii
```

You should see: `backups` owned by you, `mariadb` at mode `drwx------` owned by root, and
`upload` owned by uid `33`.

If you do not: leave `mariadb` owned by root on purpose, because the MariaDB image chowns its
own data directory the first time it starts and one you have already chowned makes it refuse to
initialise. `upload` is the opposite case. The Firefly III image runs as `www-data`, uid 33,
from its first instruction and never chowns a mount, so if that folder belongs to you, saving
an attachment fails with a permission error while every other page keeps working.

## 3. Secrets

Three secrets, all generated here on the server: the Laravel application key, the database
password, and the token the cron container uses to call the application. Hex for all three,
because upstream documents `APP_KEY` and `STATIC_CRON_TOKEN` as exactly 32 characters with
special characters avoided, and `openssl rand -hex 16` is 32 characters of `0-9a-f`.

```bash
umask 077
cat > /srv/firefly-iii/.env <<EOF
APP_URL=https://<DOMAIN>
TZ=UTC
TRUSTED_PROXIES=**
APP_KEY=$(openssl rand -hex 16)
DB_PASSWORD=$(openssl rand -hex 32)
STATIC_CRON_TOKEN=$(openssl rand -hex 16)
EOF
chmod 600 /srv/firefly-iii/.env
umask 022
ls -l /srv/firefly-iii/.env
awk -F= '/^APP_KEY=/{print "APP_KEY length: " length($2)}' /srv/firefly-iii/.env
```

You should see: mode `-rw-------`, your own username twice, and then `APP_KEY length: 32`.
Replace `<DOMAIN>` on the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/firefly-iii/.env` and
carry on. A length other than 32 means Firefly III will refuse to boot with a key-length error;
delete the file and paste the block again in one go. If the file already existed from an
earlier attempt, this block has now replaced all three secrets, which is fine before the
database exists and a problem afterwards: MariaDB keeps the password it was created with, and a
changed `APP_KEY` makes previously encrypted data unreadable.

Do not paste that file, any of the three secrets, or any command output containing them into
this chat window. `APP_KEY` is the one worth being careful about twice: upstream's backup page
names it first, and a database restored without it is a ledger nobody can read.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/firefly-iii/compose.yml <<'EOF'
# Firefly III · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.firefly-iii.org/how-to/firefly-iii/installation/docker/
#   variable reference . https://github.com/firefly-iii/firefly-iii/blob/v6.6.6/.env.example
#   cron jobs .......... https://docs.firefly-iii.org/how-to/firefly-iii/advanced/cron/
#
# Three services. `app` is nginx and PHP-FPM in one image, running as www-data,
# uid 33, which never chowns a mount, so step 2 hands it /srv/firefly-iii/upload
# already owned by 33. `db` is the MariaDB upstream's compose file uses, pinned
# to a version instead of the moving `lts` tag. `cron` is BusyBox crond calling
# the application's own cron endpoint daily, because upstream states the image
# runs no scheduler; upstream's cron container installs tzdata at every start,
# dropped here in favour of one fixed timezone. Every ${...} comes from
# /srv/firefly-iii/.env, mode 600. Digests read 2026-08-07, all three multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: firefly
      MARIADB_USER: firefly
      MARIADB_PASSWORD: ${DB_PASSWORD}
      # Upstream's database.env has the image invent a root password rather
      # than store one. It lands in this container's log once and is never used.
      MARIADB_RANDOM_ROOT_PASSWORD: "true"
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/firefly-iii/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other containers.

  app:
    image: fireflyiii/core:version-6.6.6@sha256:ae69fdd95cdef9038cd7a460a5aec731f14813973e4f096511d5a4ea9ff0e972
    restart: unless-stopped
    env_file: /srv/firefly-iii/.env
    environment:
      APP_ENV: production
      DB_CONNECTION: mysql
      DB_HOST: db
      DB_PORT: "3306"
      DB_DATABASE: firefly
      DB_USERNAME: firefly
      # Laravel's log mailer, upstream's own default: nothing waits on SMTP.
      MAIL_MAILER: log
      # The image's health check curls the path this names. Its default,
      # /healthcheck, is not a route here; /health answers with `OK`.
      HEALTHCHECK_PATH: /health
    volumes:
      - /srv/firefly-iii/upload:/var/www/html/storage/upload
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8155.
      - "127.0.0.1:8155:8080"
    depends_on:
      db:
        condition: service_healthy

  cron:
    image: alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
    restart: unless-stopped
    env_file: /srv/firefly-iii/.env
    # 03:00 daily: recurring transactions, auto-budgets, rates, bill warnings.
    # The doubled $$ is compose's escape for one $, so the token is read inside
    # the container and never appears here. TZ is UTC, so BusyBox needs no tzdata.
    command: ["sh", "-c", "echo '0 3 * * * wget -qO- http://app:8080/api/v1/cron/'$$STATIC_CRON_TOKEN | crontab - && crond -f -L /dev/stdout"]
    depends_on:
      app:
        condition: service_started
EOF
cd /srv/firefly-iii && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/firefly-iii/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/firefly-iii/compose.yml` and paste again in one go. The three services are the
application, the MariaDB it stores everything in, and a small cron container. That third one
exists because upstream states plainly that the Docker image does not run scheduled jobs, so
without it recurring transactions never fire and auto-budgets never roll over.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-firefly-iii
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Firefly III · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.firefly-iii.org/how-to/firefly-iii/installation/docker/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_URL in .env, and if the two disagree the forms post to an address
# that does not answer.

<DOMAIN> {
	# Statements and attachments travel both ways, so compression earns a place.
	encode zstd gzip

	header {
		# A ledger of every account you own is worth a downgrade attack.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "same-origin"
		-Server
	}

	# 8155 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8155
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-firefly-iii /etc/caddy/Caddyfile`,
reload, and paste again. The hostname in this block has to be the same one you put in `APP_URL`
in step 3, because Firefly III builds its own links and form actions from `APP_URL`; if the two
disagree, the login page renders and the login button posts into nothing.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8155` or `3306`.

If you do not: delete anything for `8155` or `3306` with `sudo ufw delete allow 8155`. 8155 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to answer the ACME challenge and
redirect to HTTPS, 443/tcp is the way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

Firefly III builds its schema on the way up. On an empty database that is a minute or two
during which every page answers 500, so the loop below waits it out.

```bash
cd /srv/firefly-iii
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/login | grep -c 'Sign in to start your session'
docker compose exec -T cron sh -c 'wget -qO- http://app:8080/api/v1/cron/$STATIC_CRON_TOKEN'
```

You should see, in order: the loop climbing and ending on `200`; the two letters `OK`; then
`1`; then a line of JSON containing `"recurring_transactions"` and `"job_fired":true`.

If you do not: the `1` is the first screen. It means https://<DOMAIN>/login carries the heading
`Sign in to start your session`, which is what a browser will show you. A `0` there with a
`200` from health usually means Caddy is serving a different site block, so check the hostname
you pasted in step 5. If the loop never reaches `200`, run `docker compose logs --tail 20 db`
first, because a database that never reports healthy is step 2 done wrong, and
`docker compose logs --tail 40 app` second, where a key-length complaint sends you back to step
3. The JSON line is the cron container proving it can reach the application and that its token
is accepted; without it, recurring transactions would silently never run.

Now open https://<DOMAIN>/register in a browser, create the first account with an email address
and a password you put in your password manager, and come back. There is no password reset on
this install, because it sends no mail, so that password is the only way back in.

```bash
curl -sS https://<DOMAIN>/register | grep -c 'Registration is currently not available'
```

You should see: `1`.

If you do not: a `0` means the register page is still serving a form, which means the account
was not created. Firefly III ships in single-user mode, so registration is open exactly until
the database holds one user and closes itself after that. Create the account, then run the same
command again. Do not call the install done while that number is `0`: a register form on a
public hostname is an invitation. A running container is not success either.

## 8. First backup and restore

Three artifacts, taken before you enter a single transaction. The dump holds accounts,
transactions, budgets and rules; the upload archive holds attachments; the config archive holds
the files that rebuild the service around them, `.env` among them, where `APP_KEY` lives.

```bash
cd /srv/firefly-iii
docker compose exec -T db sh -c 'exec mariadb-dump -ufirefly -p"$MARIADB_PASSWORD" --single-transaction firefly' | gzip > /srv/firefly-iii/backups/firefly-iii-db-$(date +%F).sql.gz
sudo tar -czf /srv/firefly-iii/backups/firefly-iii-upload-$(date +%F).tar.gz -C /srv/firefly-iii upload
sudo tar -czf /srv/firefly-iii/backups/firefly-iii-config-$(date +%F).tar.gz -C /srv/firefly-iii compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/firefly-iii/backups/
```

You should see: three files, the dump a few tens of kilobytes on a fresh install and the two
archives smaller. Nothing goes offline: `--single-transaction` snapshots a running InnoDB
database consistently, and the password never appears in your terminal because the container
reads it from its own environment.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump`
failed and the shell created the file anyway. Run the dump line without `| gzip` to read the
error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/firefly-iii
scp vps:/srv/firefly-iii/backups/* ~/backups/firefly-iii/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/firefly-iii/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty ledger:

```bash
cd /srv/firefly-iii
docker compose down
sudo rm -rf /srv/firefly-iii/mariadb
sudo install -d -m 700 /srv/firefly-iii/mariadb
docker compose up -d db
sleep 40
gunzip -c /srv/firefly-iii/backups/firefly-iii-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -ufirefly -p"$MARIADB_PASSWORD" firefly'
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/health
```

You should see: no output from the restore itself, then `OK` from the last command, which means
the schema came back into a database that had been deleted and rebuilt.

If you do not: `Access denied for user 'firefly'` means the new empty data directory did not
get the password, which means `.env` was missing when the container first started. That is why
the config archive is restored before anything else on a real restore, and why a dump without
`.env` is not a restore. Understand the stakes before you skip this step: this database is
every account balance and every transaction you will ever put in, and a bank will not export
you a second copy of a category you invented.

## 9. Updating later

New versions are listed at https://github.com/firefly-iii/firefly-iii/releases, and the image
tag for a release is `version-` followed by its number. Take all three backup artifacts first,
then edit the `image:` line in /srv/firefly-iii/compose.yml to the new tag and its digest.

```bash
cd /srv/firefly-iii
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one account page as well,
because a service that answers `OK` on health can still be failing a page if a migration
stopped halfway.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a failed install for about two minutes. I opened
https://<DOMAIN> the second the command returned, got a blank Laravel error page, reloaded
twice, and started reading the compose file for a typo that was not there. Firefly III was
building its schema: dozens of migrations run on the first boot, and until the last one lands
every request answers 500. The loop in step 7 exists so nobody guesses. If it still fails
after forty attempts, check the `APP_KEY` length line from step 3.

## 11. Out of scope

- Do not install the Firefly III Data Importer. It is a separate application with its own
  container, hostname and access token; this install gives you the ledger it would feed.
- Do not configure SMTP. `MAIL_MAILER` is `log` here, upstream's own default.
- Do not set `FIREFLY_III_LAYOUT=v2`. Upstream calls that layout very experimental and warns
  about data loss in the same breath.
- Do not regenerate `APP_KEY` or run `php artisan key:generate` here. The key that encrypted
  the data is the only key that reads it back.
