You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Invoice Ninja 5.13.30, with the MySQL and Redis it needs, under ~/selfhost/invoice-ninja,
answering at http://localhost:8127.

## 1. Preflight

Say this first; it decides whether the user wants this install at all. Every invoice link this
creates begins with http://localhost:8127, which means "this computer" wherever it is read, so a
client sent one gets a connection error. They get a private ledger and PDFs they hand over, not a
portal a client opens. Now detect the OS and measure:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. This stack wants 3072 MB of RAM available
and 10 GB free on the home disk: MySQL 8.4, php-fpm, two queue workers and the headless Chrome
that renders PDFs. All four images are multi-arch. If either number is short, print both and
stop. Do not install and hope.

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
mkdir -p ~/selfhost/invoice-ninja/backups ~/selfhost/invoice-ninja/nginx
cat > ~/selfhost/invoice-ninja/nginx/invoice-ninja.conf <<'EOF'
# Invoice Ninja · nginx for php-fpm, by caniselfhostit, authored from
# https://laravel.com/docs/12.x/deployment#nginx

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
ls -la ~/selfhost/invoice-ninja
```

Assert: `ls -la` shows `backups` and `nginx`, owned by the user. There is no `data` folder:
invoices are rows in MySQL, and `public` and `storage` are volumes.

## 4. Secrets

Four, generated here: the Laravel application key, the MySQL password for `ninja`, the root
password the image demands before it will initialise, and the password for the account the first
boot creates. Print none of them, in chat, in your summary or in a log line. `APP_KEY` has a
shape: `base64:` and 32 random bytes in base64, what `php artisan key:generate --show` prints.

```bash
umask 077
cat > ~/selfhost/invoice-ninja/.env <<EOF
APP_URL=http://localhost:8127
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
IN_USER_EMAIL=owner@invoice-ninja.test
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
IN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/invoice-ninja/.env
umask 022
ls -l ~/selfhost/invoice-ninja/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run the same on all three.
`owner@invoice-ninja.test` is the username the user signs in with, and nothing is sent to it. On
Windows the mode bits are advisory; the real boundary is the Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/invoice-ninja/compose.yml <<'EOF'
# Invoice Ninja · the deterministic fallback for the local path, authored by
# caniselfhostit from the upstream docs, not copied from a repository:
#   https://invoiceninja.github.io/docs/self-host/self-host-installation
#   https://github.com/invoiceninja/dockerfiles/blob/debian/README.md
#
# php-fpm under supervisord (which also runs the two queue workers and the
# scheduler), nginx in front, MySQL, Redis. Named volumes rather than binds:
# all three chown the directory they are given, which a home-directory bind
# cannot grant on Windows. Digests read 2026-08-06.
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
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", 'mysqladmin ping -h 127.0.0.1 -u ninja -p"$$MYSQL_PASSWORD" --silent']
      interval: 10s
      retries: 30

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 30

  app:
    image: invoiceninja/invoiceninja-debian:5.13.30@sha256:3e8649be15e9fb7d76626d6ab06cd46dabc8dcba5910d77f7f7f8c885e367cac
    restart: unless-stopped
    env_file: ./.env
    volumes:
      - app_public:/var/www/html/public
      - app_storage:/var/www/html/storage
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    # No `ports:` here, on mysql or on redis: 3306, 6379 and 9000 stay inside.

  nginx:
    image: nginx:1.30.4-alpine@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46
    restart: unless-stopped
    volumes:
      - ./nginx:/etc/nginx/conf.d:ro
      - app_public:/var/www/html/public:ro
      - app_storage:/var/www/html/storage:ro
    depends_on:
      app:
        condition: service_started
    ports:
      # Loopback only: no other device can reach 8127.
      - "127.0.0.1:8127:80"

volumes:
  mysql_data:
  redis_data:
  app_public:
  app_storage:
EOF
cd ~/selfhost/invoice-ninja && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision: no hostname to
resolve, no public name for a certificate to attest, nothing beyond loopback for a firewall to
close. Browsers treat http://localhost as a secure context, so pages needing crypto still work.
8127 answers on this computer only, not the user's phone, not a laptop on the same wifi, not
anyone on the internet. Confirm it:

```bash
grep -n '"127.0.0.1:' ~/selfhost/invoice-ninja/compose.yml
```

Assert: one line, `- "127.0.0.1:8127:80"`. Nothing else publishes a host port.

## 7. Start and verify

The first boot pulls about 3 GB of images, migrates, seeds reference data, then makes the account
from `IN_USER_EMAIL` and `IN_PASSWORD`. Until it finishes nginx answers 502.

```bash
cd ~/selfhost/invoice-ninja
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8127/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8127/health
curl -sS http://localhost:8127/ | grep -oE '<title>[^<]*</title>|Version: [0-9.]+'
docker compose exec -T -u www-data app php artisan tinker --execute='echo App\Models\User::where("email","admin@example.com")->count();'
```

Assert all four, printing what you got: the loop ends on `200`; the health body is
`{"status":"ok","message":"API is healthy"}`; the grep prints `<title>Invoice Ninja</title>` and
`Version: 5.13.30`, the container agreeing with the pinned digest; the last prints `0`. That `0`
is the security assert: upstream's account-creation command falls back to the published
`admin@example.com` and a published password when called without both options, so with both
passed that account must not exist.

If any of the four misses, stop and name the cause: connection refused means Docker Desktop is
not running, `port is already allocated` means something else holds 8127 (find it with
`lsof -nP -iTCP:8127 -sTCP:LISTEN` and stop until it is free), and otherwise
`docker compose logs --tail 40 app` shows a migration still running or a restart loop pointing at
step 4. A running container is not success.

The first screen at http://localhost:8127 is the sign-in form: the heading `Login`, an
`Email address` box, a `Password` box, a `Secret` box only self-hosted installs show, and a
`Forgot your password?` link.

STOP: tell the user to read their password with `grep IN_PASSWORD ~/selfhost/invoice-ninja/.env`,
put it in their password manager, sign in at http://localhost:8127 as `owner@invoice-ninja.test`,
and confirm the dashboard loads. Wait. Do not continue until they confirm. No mail leaves here,
so that entry is the whole recovery story.

## 8. First backup and restore

Three artifacts: the database has clients, invoices and payments, the storage archive logos and
PDFs, and the config archive what rebuilds the rest, `APP_KEY` included.

```bash
cd ~/selfhost/invoice-ninja
docker compose exec -T mysql sh -c 'exec mysqldump -u ninja -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces ninja' | gzip > backups/invoice-ninja-db-$(date +%F).sql.gz
docker compose exec -T app tar -czf - -C /var/www/html storage > backups/invoice-ninja-storage-$(date +%F).tar.gz
tar -czf backups/invoice-ninja-config-$(date +%F).tar.gz -C ~/selfhost/invoice-ninja compose.yml .env nginx
ls -lh ~/selfhost/invoice-ninja/backups/
```

Assert: all three exist and are non-empty, and print all three sizes. Nothing stops:
`--single-transaction` snapshots InnoDB consistently.

All three sit on the same disk as the data, which is not a backup: on a laptop the disk and the
machine fail together. Ask for a destination that leaves this computer, a synced folder or a USB
stick, and copy all three there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert:
the user confirms all three are there, or say there is no backup.

To restore, in this order: `cd ~/selfhost/invoice-ninja`, untar the config archive there first so
.env is back before any container starts, `docker compose down -v` (the one place `-v` belongs,
because it drops the old volumes on purpose), `docker compose up -d mysql`, wait a minute, pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u ninja -p"$MYSQL_PASSWORD" ninja'`,
`docker compose up -d`, then the storage archive into
`docker compose exec -T app tar -xzf - -C /var/www/html`. The dump and the .env travel together:
`APP_KEY` decrypts the columns.

## 9. Updating later

New versions are at https://github.com/invoiceninja/invoiceninja/releases; the tag is that tag
without its `v`. Back up first, then edit the image line.

```bash
cd ~/selfhost/invoice-ninja
docker compose pull
docker compose up -d --force-recreate
docker compose logs --tail 40 app
```

The container runs `artisan migrate --force` on the way up, so watch that log until it settles.
`--force-recreate` is there because nginx resolves `app` once at start-up. Re-run step 7.

## 10. What will probably go wrong

The logo. I uploaded one, it looked right on screen, and every PDF came out with a gap where it
should have been. The reason is structural: PDFs are rendered by a headless Chrome inside the app
container, the logo is fetched by absolute URL, and that URL is http://localhost:8127, which
inside the container is the container itself. Tell the user to leave the logo off, or accept that
their PDFs will not carry it.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8127 to 0.0.0.0 or point `APP_URL` at a LAN address, which puts a billing system
  with one password on every network the user joins.
- Do not configure SMTP, set a `MAIL_` variable beyond step 4's `MAIL_MAILER=log`, or set
  `LICENSE_KEY`, the paid annual licence that strips Invoice Ninja branding from PDFs.
