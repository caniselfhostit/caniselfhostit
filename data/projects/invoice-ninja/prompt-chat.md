This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Invoice Ninja 5.13.30 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box and `<ADMIN_EMAIL>` with the address you want to sign in as.

Read this before step 1. `<DOMAIN>` becomes `APP_URL`, and the first boot writes it into the
company record as your client-portal domain, so it is the address on every invoice link a client
opens. Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `3072` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that
does not resolve and failed attempts count against a rate limit you cannot see. If the memory
number is short, this is not a stack to squeeze: MySQL 8.4, php-fpm, two queue workers and a
headless Chrome that appears whenever a PDF renders all want their share. On `arm64` everything
runs, with one gap, the Saxon extension that validates e-invoice XML is built for amd64 only.

## 2. Layout

Paste the whole block at once, including the last line.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/invoice-ninja /srv/invoice-ninja/backups /srv/invoice-ninja/nginx
sudo install -d -m 700 /srv/invoice-ninja/mysql /srv/invoice-ninja/redis
cat > /srv/invoice-ninja/nginx/invoice-ninja.conf <<'EOF'
# Invoice Ninja · nginx for php-fpm, from https://laravel.com/docs/12.x/deployment#nginx

server {
	listen 80 default_server;
	root /var/www/html/public;
	index index.php;
	client_max_body_size 20M;

	location / {
		try_files $uri $uri/ /index.php?$query_string;
	}

	location ~ \.php$ {
		fastcgi_pass app:9000;
		fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
		include fastcgi_params;
	}
}
EOF
ls -la /srv/invoice-ninja
```

You should see: `backups` and `nginx` owned by you, and `mysql` and `redis` at mode `drwx------`
owned by root.

If you do not: leave `mysql` and `redis` owned by root on purpose. Both images chown their own
data directory the first time they start, and one you have already chowned to yourself makes
MySQL refuse to initialise. There is no `data` directory here: the application's `public` and
`storage` trees live in named volumes the image fills itself, because it rewrites `public` on
every start.

## 3. Secrets

Four secrets, all generated here on the server, all into one file only you can read: the Laravel
application key, the MySQL password for the `ninja` user, the MySQL root password the image
demands before it will initialise, and the password for the one account the first boot creates.
`APP_KEY` has a shape, `base64:` followed by 32 random bytes in base64, which is exactly what
`php artisan key:generate --show` prints inside the container. The line below makes the same
thing without needing a container yet.

Replace `<DOMAIN>` and `<ADMIN_EMAIL>` on their two lines before you paste.

```bash
umask 077
cat > /srv/invoice-ninja/.env <<EOF
APP_URL=https://<DOMAIN>
APP_ENV=production
APP_DEBUG=false
REQUIRE_HTTPS=false
TRUSTED_PROXIES=*
IS_DOCKER=true
FILESYSTEM_DISK=debian_docker
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_HOST=redis
DB_CONNECTION=mysql
DB_HOST=mysql
DB_DATABASE=ninja
DB_USERNAME=ninja
MAIL_MAILER=log
IN_USER_EMAIL=<ADMIN_EMAIL>
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
IN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/invoice-ninja/.env
umask 022
ls -l /srv/invoice-ninja/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/invoice-ninja/.env` and carry
on. If the file already existed from an earlier attempt this block has now replaced all four
values, which is fine before the database exists and a problem afterwards: MySQL keeps the
password it was created with, so a changed `DB_PASSWORD` on an existing data directory shows up
as an access-denied loop in the app log rather than as anything about passwords.

Do not paste that file, any of those four values, or any command output containing them into this
chat window. Read your account password once, after step 7, with
`grep IN_PASSWORD /srv/invoice-ninja/.env`, and put it straight into your password manager.
`APP_KEY` is the one to understand: upstream documents it as the key that encrypts and decrypts
datapoints inside the application, so a database restored beside a different key comes back with
columns nobody can read.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/invoice-ninja/compose.yml <<'EOF'
# Invoice Ninja · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   install .. https://invoiceninja.github.io/docs/self-host/self-host-installation
#   env vars . https://invoiceninja.github.io/docs/self-host/env-variables
#   docker ... https://github.com/invoiceninja/dockerfiles/blob/debian/README.md
#
# Four services. The app image is php-fpm under supervisord, which also runs the
# two queue workers and the scheduler, so there is no worker or cron container.
# nginx hands PHP to app:9000; Redis holds sessions, cache and the queue.
# public/ and storage/ are named volumes, not binds: the image ships its own
# public tree and chowns both to www-data. Digests read 2026-08-06, multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mysql:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: ninja
      MYSQL_USER: ninja
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - /srv/invoice-ninja/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", 'mysqladmin ping -h 127.0.0.1 -u ninja -p"$$MYSQL_PASSWORD" --silent']
      interval: 10s
      retries: 30

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    volumes:
      - /srv/invoice-ninja/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 30

  app:
    image: invoiceninja/invoiceninja-debian:5.13.30@sha256:3e8649be15e9fb7d76626d6ab06cd46dabc8dcba5910d77f7f7f8c885e367cac
    restart: unless-stopped
    env_file: /srv/invoice-ninja/.env
    volumes:
      - app_public:/var/www/html/public
      - app_storage:/var/www/html/storage
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    # No `ports:` on these three: 3306, 6379 and 9000 stay inside the network.

  nginx:
    image: nginx:1.30.4-alpine@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46
    restart: unless-stopped
    volumes:
      - /srv/invoice-ninja/nginx:/etc/nginx/conf.d:ro
      - app_public:/var/www/html/public:ro
      - app_storage:/var/www/html/storage:ro
    depends_on:
      app:
        condition: service_started
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8127.
      - "127.0.0.1:8127:80"

volumes:
  app_public:
  app_storage:
EOF
cd /srv/invoice-ninja && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/invoice-ninja/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal, so
run `rm /srv/invoice-ninja/compose.yml` and paste again in one go. None of these four services is
optional. The app reads its cache, its sessions and its job queue out of Redis and will not start
without one, nginx is the only thing here that speaks HTTP, and upstream's own compose for this
image runs the same four.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-invoice-ninja
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Invoice Ninja · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://invoiceninja.github.io/docs/self-host/self-host-installation and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. It is also APP_URL in .env, which the first boot writes
# into the company record as the client-portal domain, so it is on every
# invoice link a client opens.

<DOMAIN> {
	# A JavaScript admin bundle and a JSON API compress well; the PDFs are
	# already compressed, and Caddy leaves those alone.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8127 is the loopback port compose publishes, not open in the firewall.
	# Caddy sets X-Forwarded-Proto, which TRUSTED_PROXIES lets the app read,
	# so its links say https.
	reverse_proxy 127.0.0.1:8127
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-invoice-ninja /etc/caddy/Caddyfile`,
reload, and paste again. `REQUIRE_HTTPS` stays false in .env on purpose: Caddy already redirects
80 to 443, and a second redirect inside the application is how a proxied Laravel install ends up
in a loop that looks like a broken certificate.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8127`, `3306`, `6379` or `9000`.

If you do not: delete anything for those four with `sudo ufw delete allow 8127`. 8127 is bound to
127.0.0.1 by the compose file and the other three are never published at all, so none of them has
a host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and answer the
ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The first boot pulls about 3 GB of images, runs the Laravel migrations, seeds the reference data
and then creates your account from `IN_USER_EMAIL` and `IN_PASSWORD`. Until that finishes nginx
answers 502.

```bash
cd /srv/invoice-ninja
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/ | grep -oE '<title>[^<]*</title>|Version: [0-9.]+'
docker compose exec -T -u www-data app php artisan tinker --execute='echo App\Models\User::where("email","admin@example.com")->count();'
```

You should see, in order: the loop reaching `200`, then
`{"status":"ok","message":"API is healthy"}`, then `<title>Invoice Ninja</title>` and
`Version: 5.13.30` on two lines, then `0`.

If you do not: that `0` is the one worth understanding. Upstream's account-creation command falls
back to the published address `admin@example.com` with a published password whenever it is called
without both options, and this install passes both, so that account should not exist. A `1` there
means a credential printed in public documentation can sign in to your books: stop, do not carry
on, and check that `IN_USER_EMAIL` and `IN_PASSWORD` were both set in .env before the first
start. If the loop never reaches `200`, run `docker compose logs --tail 20 mysql` first, because
a database that never reports healthy holds everything else back, then
`docker compose logs --tail 40 app`. A `Version:` line that does not say `5.13.30` means the
running container is not the digest you pinned in step 4.

The first screen at https://<DOMAIN> is the sign-in form: the heading `Login`, an `Email address`
box, a `Password` box, a `Secret` box that only self-hosted installs show, and a
`Forgot your password?` link. Read your password now with
`grep IN_PASSWORD /srv/invoice-ninja/.env`, put it in your password manager, and sign in as the
address you put in `IN_USER_EMAIL`. There is no password-reset mail on this install, so that
password-manager entry is the whole recovery story.

## 8. First backup and restore

Three artifacts. The database holds your clients, invoices and payments; the storage archive
holds uploaded logos and generated PDFs; the config archive holds what rebuilds the service
around them, `APP_KEY` included.

```bash
cd /srv/invoice-ninja
docker compose exec -T mysql sh -c 'exec mysqldump -u ninja -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces ninja' | gzip > backups/invoice-ninja-db-$(date +%F).sql.gz
docker compose exec -T app tar -czf - -C /var/www/html storage > backups/invoice-ninja-storage-$(date +%F).tar.gz
sudo tar -czf backups/invoice-ninja-config-$(date +%F).tar.gz -C /srv/invoice-ninja compose.yml .env nginx -C /etc/caddy Caddyfile
ls -lh /srv/invoice-ninja/backups/
```

You should see: three files, the database dump and the config archive a few kilobytes each on a
fresh install and the storage archive rather larger. Nothing goes offline, because
`mysqldump --single-transaction` snapshots InnoDB consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mysqldump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.
`Access denied` there means the password in the container's environment, set from .env when the
container was created, is not the one the database was initialised with: step 3 run twice. The
`--no-tablespaces` flag is not optional: without it `mysqldump` asks for a privilege the
`ninja` user does not have and stops.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/invoice-ninja
scp vps:/srv/invoice-ninja/backups/* ~/backups/invoice-ninja/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/invoice-ninja/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty company:

```bash
cd /srv/invoice-ninja
docker compose down
sudo rm -rf /srv/invoice-ninja/mysql
sudo install -d -m 700 /srv/invoice-ninja/mysql
docker compose up -d mysql
sleep 60
gunzip -c /srv/invoice-ninja/backups/invoice-ninja-db-$(date +%F).sql.gz | docker compose exec -T mysql sh -c 'exec mysql -u ninja -p"$MYSQL_PASSWORD" ninja'
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/health
```

You should see: no output from the restore line, then
`{"status":"ok","message":"API is healthy"}`, then your own account still signing in.

If you do not: `Unknown database 'ninja'` or `Access denied` means MySQL had not finished
initialising, so wait another minute and run the `gunzip` line again. Understand the stakes
before you skip this. Your invoices are rows in that database and the key that decrypts the
encrypted columns is `APP_KEY` in .env, so the dump and the config archive are one backup in two
files and have to travel together.

## 9. Updating later

New versions are listed at https://github.com/invoiceninja/invoiceninja/releases, and the image
tag is the release tag without its leading `v`. Take all three backup artifacts first, then edit
the `image:` line for the app in /srv/invoice-ninja/compose.yml to the new tag and its digest.

```bash
cd /srv/invoice-ninja
docker compose pull
docker compose up -d --force-recreate
docker compose logs --tail 40 app
```

You should see: migration output, then supervisord starting php-fpm and the workers, and no
repeating restart.

If you do not: put the old tag and digest back and run the same three commands. `--force-recreate`
is there because nginx resolves the `app` name once at start-up and keeps that address, so an app
container replaced underneath it produces a 502 that looks like a failed upgrade. Then re-run the
health and version checks from step 7 before you call the update done.

## 10. What will probably go wrong

Mail. This install sets `MAIL_MAILER=log`, upstream's own default for the container, and that
mailer never fails: it writes the message into the application log and reports success. I sent
myself a test invoice, watched a green confirmation appear, and spent twenty minutes hunting a
delivery problem that did not exist. Emailing invoices and payment reminders does nothing until
you add a mail provider under Settings, Email Settings, and until then an invoice reaches a client
as a PDF or a portal link you send yourself.

## 11. Out of scope

- Do not configure SMTP or set any `MAIL_` variable beyond step 3's `MAIL_MAILER=log`. Mail
  belongs in the application's settings screen, where a wrong password is one form field rather
  than a container restart.
- Do not set `LICENSE_KEY` or buy the white-label licence. Removing the Invoice Ninja branding
  from client-facing pages and PDFs is a paid annual licence this install ships without.
- Do not switch the database to PostgreSQL and do not add a queue-worker or cron container.
  Upstream supports MySQL and MariaDB only, and supervisord already runs both inside the app.
- Do not set `NORDIGEN_SECRET_ID` or any payment-gateway credential. Bank feeds and card
  processing are separate accounts with separate signups.
