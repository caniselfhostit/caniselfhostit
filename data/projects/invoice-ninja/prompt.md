You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Invoice Ninja 5.13.30 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until they
answer. Say why the hostname matters: it becomes `APP_URL`, which the first boot writes into the
company record as the client-portal domain, so it is on every invoice link a client opens, and
its A record must already point here. `<ADMIN_EMAIL>` is the login for the account this makes.

Invoice Ninja needs 3072 MB of RAM available and 10 GB free on /srv: MySQL 8.4, php-fpm, two
queue workers and a headless Chrome that appears whenever a PDF renders. All four images publish
amd64 and arm64; only the Saxon extension, which validates e-invoice XML, is amd64 only.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 3072 MB or free disk is under 10 GB, print both and stop. Do not install
and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a name that
does not resolve, and failed attempts count against a rate limit.

## 2. Layout

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

Assert: `ls -la` shows `backups` and `nginx` owned by the login user, `mysql` and `redis` at mode
`700` owned by root. Leave those two: both images chown their own data directory on first start.
`public` and `storage` are not here; compose keeps them in named volumes.

## 3. Secrets

Four, generated here: the Laravel application key, the MySQL password for the `ninja` user, the
root password the image demands before it will initialise, and the password for the account the
first boot creates. Print none of them; keep them out of your summary and every log line.

`APP_KEY` has a shape: `base64:` followed by 32 random bytes in base64, which is what
`php artisan key:generate --show` prints. The line below makes the same thing with no container.

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

Assert: mode `-rw-------`. `APP_KEY` matters most of the four: upstream documents it as the key
that encrypts and decrypts datapoints inside the application, so a database restored beside a
different one comes back unreadable. Step 8 gets a copy off the box.

## 4. compose.yml

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

Assert: `compose OK`. Upstream's own compose runs these same four and none is optional: the app
will not start without a Redis it can put sessions and jobs in.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy first: one syntax
error takes down every other site on the box.

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

Assert: both exit 0. On failure restore /etc/caddy/Caddyfile.before-invoice-ninja, reload, and
report what it said. Caddy gets the certificate on the first request and renews it itself.
`REQUIRE_HTTPS` stays false on purpose: Caddy already redirects 80 to 443, and a second redirect
inside the app is how a proxied Laravel ends in a loop.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the only way in, 443/udp is HTTP/3.
8127 is bound to loopback and 3306, 6379 and 9000 are never published, so none of them belongs
here. Assert: `Status: active`, rules for 80, 443/tcp and 443/udp, none for those four.

## 7. Start and verify

The first boot pulls about 3 GB of images, migrates, seeds reference data, then creates the
account from `IN_USER_EMAIL` and `IN_PASSWORD`. Until it finishes nginx answers 502, which is the
wait working, not a fault.

```bash
cd /srv/invoice-ninja
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/ | grep -oE '<title>[^<]*</title>|Version: [0-9.]+'
docker compose exec -T -u www-data app php artisan tinker --execute='echo App\Models\User::where("email","admin@example.com")->count();'
```

Assert all four, printing what you got for each: the loop ends on `200`; the health body is
`{"status":"ok","message":"API is healthy"}`; the grep prints `<title>Invoice Ninja</title>` and
`Version: 5.13.30`, the running container agreeing with the pinned digest; the last command
prints `0`.

That `0` is the security assert. Upstream's account-creation command falls back to the published
address `admin@example.com` and a published password whenever it runs without both options; this
install passes both, so that account must not exist. If it prints `1`, stop and say so: a known
credential is answering on a public hostname. If any of the four misses, stop, run
`docker compose logs --tail 40 app`, and name the likely step: a 502 that never clears is the app
still migrating, a restart loop with a database error is step 3. A running container is not
success.

The first screen at https://<DOMAIN> is the sign-in form: the heading `Login`, an `Email address`
box, a `Password` box, a `Secret` box only self-hosted installs show, and
`Forgot your password?`.

STOP: tell the user to read their password with `grep IN_PASSWORD /srv/invoice-ninja/.env`, put it
in their password manager, sign in at https://<DOMAIN> as `<ADMIN_EMAIL>`, and confirm the
dashboard loads. Wait. Do not continue until they confirm. No mail leaves this install, so that
password-manager entry is the whole recovery story.

## 8. First backup and restore

Three artifacts: the database holds clients, invoices and payments, the storage archive holds
logos and PDFs, and the config archive rebuilds the service around them, `APP_KEY` included.

```bash
cd /srv/invoice-ninja
docker compose exec -T mysql sh -c 'exec mysqldump -u ninja -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces ninja' | gzip > backups/invoice-ninja-db-$(date +%F).sql.gz
docker compose exec -T app tar -czf - -C /var/www/html storage > backups/invoice-ninja-storage-$(date +%F).tar.gz
sudo tar -czf backups/invoice-ninja-config-$(date +%F).tar.gz -C /srv/invoice-ninja compose.yml .env nginx -C /etc/caddy Caddyfile
ls -lh /srv/invoice-ninja/backups/
```

Assert: all three exist and are non-empty. Print all three sizes. Nothing stops:
`--single-transaction` snapshots InnoDB consistently, and `--no-tablespaces` keeps the dump inside
the `ninja` user's privileges. A backup on the same disk is not a backup, so run this from the
user's machine:

```bash
mkdir -p ~/backups/invoice-ninja
scp vps:/srv/invoice-ninja/backups/* ~/backups/invoice-ninja/
```

To restore: `docker compose down` with no `-v`, because the volumes hold the uploads,
`sudo rm -rf /srv/invoice-ninja/mysql`, recreate it as in step 2, untar the config archive so
.env is back first, `docker compose up -d mysql`, wait for healthy, then pipe `gunzip -c` on the
`.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u ninja -p"$MYSQL_PASSWORD" ninja'`,
`docker compose up -d`, and feed the storage archive into
`docker compose exec -T app tar -xzf - -C /var/www/html`. The dump and the .env travel together,
because `APP_KEY` decrypts the columns.

## 9. Updating later

New versions are at https://github.com/invoiceninja/invoiceninja/releases, and the image tag is
that tag without its leading `v`. Back up first, then edit the image line in compose.yml to the
new tag and digest:

```bash
cd /srv/invoice-ninja
docker compose pull
docker compose up -d --force-recreate
docker compose logs --tail 40 app
```

The container runs `artisan migrate --force` on the way up, so watch that log until it settles.
`--force-recreate` is there because nginx resolves `app` once at start-up and keeps the address.
Then re-run step 7's checks and confirm the version moved with the tag.

## 10. What will probably go wrong

Mail. This install sets `MAIL_MAILER=log`, upstream's own default for the container, and that
mailer never fails: it writes the message into the application log and reports success. I sent
myself a test invoice, watched a green confirmation appear, and spent twenty minutes hunting a
delivery problem that did not exist. Tell the user that emailing invoices and payment reminders
does nothing until they add a mail provider under Settings, Email Settings, and that until then
an invoice reaches a client as a PDF or a portal link they send themselves.

## 11. Out of scope

- Do not configure SMTP or set any `MAIL_` variable beyond step 3's `MAIL_MAILER=log`. Mail
  belongs in the application's settings screen, not in a container restart.
- Do not set `LICENSE_KEY` or buy the white-label licence. Removing the Invoice Ninja branding
  from client-facing pages and PDFs is a paid annual licence this install ships without.
- Do not switch the database to PostgreSQL and do not add a queue-worker or cron container.
  Upstream supports MySQL and MariaDB only, and supervisord already runs both inside the app.
- Do not set `NORDIGEN_SECRET_ID` or any payment-gateway credential. Bank feeds and card
  processing are separate accounts with separate signups.
