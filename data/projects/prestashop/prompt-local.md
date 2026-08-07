You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install PrestaShop 9.1.4, with the MariaDB it keeps the catalogue in, under
~/selfhost/prestashop, answering at http://localhost:8138.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this at all. Every page
this shop builds begins with http://localhost:8138, which means "this computer" wherever it is
read, so nobody else can reach it: not a customer, not the user's own phone. It is a catalogue and
back office to build in, not a store that can take an order.

Detect the OS and measure:

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
distribution ID and codename print next, for step 2. PrestaShop plus MariaDB needs 2048 MB of RAM
available and 10 GB free on the home disk, and both images publish amd64 and arm64. On macOS and
Windows that figure is the host's, minus Docker Desktop's share. Under either floor, print both
numbers and stop.

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
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they confirm.
  Either way, then STOP: tell the user to open Docker Desktop once, accept its terms, and wait
  for the whale icon to say it is running. Do not continue until they confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and install
  it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may ask for a
  reboot; if it does, STOP and tell the user to reboot and come back, this prompt resumes at
  this step. Then STOP: have the user open Docker Desktop, accept its terms, and confirm it
  says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt repository,
  with its signing key saved to a file first, never piped into a shell. The fence is guarded, a
  no-op on anything but a Linux with apt:

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

  Adding the user to the docker group is root-equivalent on this machine; say that to the user
  in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose plugin
  with their distribution's package manager, and to run this prompt again once `docker info`
  works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not continue
without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/prestashop/backups
ls -la ~/selfhost/prestashop
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: step 5 keeps the
database and the shop's 300 MB of files in Docker volumes, for the reason its header gives.

## 4. Secrets

Four values, all generated here: the database password, the MariaDB root password, the
administrator's password, and the name of the back-office directory. Print none, and keep them out
of your summary and every log line.

```bash
umask 077
cat > ~/selfhost/prestashop/.env <<EOF
PS_DOMAIN=localhost:8138
ADMIN_EMAIL=admin@example.invalid
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
PS_FOLDER_ADMIN=admin-$(openssl rand -hex 4)
EOF
chmod 600 ~/selfhost/prestashop/.env
umask 022
ls -l ~/selfhost/prestashop/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run the same on all three.
`ADMIN_EMAIL` is the username of the one back-office account; `admin@example.invalid` is
deliberate, since no mail is configured. The fourth value is a secret because the image renames
the back-office directory to it, and a name written into a prompt that ships to strangers is the
same on every shop that ran it. On Windows those bits are advisory; the real boundary is the
user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/prestashop/compose.yml <<'EOF'
# PrestaShop · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker guide ..... https://devdocs.prestashop-project.org/9/basics/installation/environments/docker/
#   image entrypoint . https://github.com/PrestaShop/docker/blob/master/base/config_files/docker_run.sh
#   mariadb image .... https://hub.docker.com/_/mariadb
#
# Two services on this computer. Every ${...} comes from
# ~/selfhost/prestashop/.env, mode 600. Both mounts are named volumes, not home
# binds: MariaDB and the PrestaShop image each chown their own mount, which
# Docker Desktop on Windows cannot grant. PS_DOMAIN is localhost:8138, so every
# URL resolves here alone. Digests read 2026-08-06, amd64 and arm64.
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
      - prestashop-dbdata:/var/lib/mysql
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
      PS_DOMAIN: ${PS_DOMAIN}
      PS_ENABLE_SSL: "0"
      PS_COUNTRY: GB
      ADMIN_MAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWD: ${ADMIN_PASSWORD}
    volumes:
      - prestashop-html:/var/www/html
    ports:
      # Loopback only: no other device on the wifi can reach 8138.
      - "127.0.0.1:8138:80"
    depends_on:
      db:
        condition: service_healthy

volumes:
  prestashop-dbdata:
  prestashop-html:
EOF
cd ~/selfhost/prestashop && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, two named volumes, and no
default credential: step 4 overrode the image's demo address and default string.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. No hostname, so
nothing to resolve. A certificate attests a public name and nothing here has one; browsers
treat http://localhost as a secure context anyway. Nothing is published beyond loopback, so no
port needs closing.

8138 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the wifi,
not anyone on the internet. Confirm:

```bash
grep -n '127.0.0.1' ~/selfhost/prestashop/compose.yml
```

Assert: one line, `- "127.0.0.1:8138:80"`. MariaDB publishes no host port.

## 7. Start and verify

On first start the entrypoint waits for MariaDB, renames the back-office directory, runs the
console installer, then deletes install/. Apache answers when that finishes, minutes later.

```bash
cd ~/selfhost/prestashop
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8138/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose logs app | grep -c -- '-- Installation successful! --'
docker compose exec -T app sh -c 'for d in install admin; do [ -d "/var/www/html/$d" ] && echo "$d PRESENT" || echo "$d GONE"; done'
docker compose exec -T app test -f /var/www/html/app/config/parameters.php && echo "parameters OK"
curl -sS -o /dev/null -w '%{http_code}\n' "http://localhost:8138/$(grep -m1 '^PS_FOLDER_ADMIN=' ~/selfhost/prestashop/.env | cut -d= -f2)/"
```

Assert all five, printing what you received: the loop ends on `200`, the storefront; the second
prints `1`, the installer's success line; the third prints `install GONE` and `admin GONE`, so the
setup wizard is deleted and the back office is off its default path; the fourth prints
`parameters OK`; the last `200` for the login page, without putting that path in your output. If
any misses, stop, run `docker compose logs --tail 80 app` and name the likely cause: a database
that never reports healthy points at step 4, and `port is already allocated` means something else
holds 8138 (`lsof -nP -iTCP:8138 -sTCP:LISTEN`). A running container is not success.

The first screen at the back-office URL shows the PrestaShop logo above a card with
`Email address`, `Password` and a `Log in` button.

STOP: tell the user to read the three values they need with
`grep -E 'PS_FOLDER_ADMIN|ADMIN_EMAIL|ADMIN_PASSWORD' ~/selfhost/prestashop/.env`, save them,
then open http://localhost:8138/ followed by that directory name and sign in. Wait until they
confirm they are on the dashboard.

## 8. First backup and restore

Three artifacts: the dump holds the catalogue, customers and orders; the shop archive holds
product images, modules, themes and `app/config/parameters.php` with the installer's cookie keys;
the config archive rebuilds the service.

```bash
cd ~/selfhost/prestashop
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/prestashop/backups/prestashop-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - app/config/parameters.php img modules themes translations upload download > ~/selfhost/prestashop/backups/prestashop-shop-$(date +%F).tar.gz
tar -C ~/selfhost/prestashop -czf ~/selfhost/prestashop/backups/prestashop-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/prestashop/backups/
```

Assert: all three exist and are non-empty, with sizes printed. The shop archive runs to a few
hundred megabytes.

All three sit on the same disk as the data, which is not a backup, and on a laptop the disk and
the machine fail together. Ask the user for a destination off this computer, a sync folder or a
USB stick, and copy all three there with `cp`; in Git Bash a Windows drive is `/d/Backups`.
Assert: the user confirms all three filenames are listed there.

To restore: `docker compose down -v`, untar the config archive into ~/selfhost/prestashop so
`.env` is back first, `docker compose up -d db`, wait 30 seconds, then pipe `gunzip -c` on the
`.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Then put the shop files back before the app container runs its start-up script:
`docker compose run --rm --no-deps -T app tar -C /var/www/html -xzf - < backups/prestashop-shop-<date>.tar.gz`.
That swaps the script for `tar`, so files land on a volume the image has filled. Finally
`docker compose up -d`. Order matters: the entrypoint installs from scratch unless
`parameters.php` is there.

## 9. Updating later

A newer image tag changes PHP, Apache and the image's copy of PrestaShop, but the shop's files
live in the `prestashop-html` volume, so this moves the runtime and not the shop:

```bash
cd ~/selfhost/prestashop
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

Image tags are at https://hub.docker.com/r/prestashop/prestashop/tags, releases at
https://github.com/PrestaShop/PrestaShop/releases. Back up first, then edit the image line. Moving
PrestaShop itself is upstream's Update Assistant, in the back office under Advanced Parameters:
https://devdocs.prestashop-project.org/9/basics/keeping-up-to-date/update/.

## 10. What will probably go wrong

I rebooted this machine, opened the shop and got a connection error that read like a lost
database. It was not: Docker Desktop had not started with the session, so nothing was listening on
8138. `restart: unless-stopped` acts only once the daemon is up. Turn on its start-at-login
setting, and after a reboot run `cd ~/selfhost/prestashop && docker compose up -d` before
concluding anything is broken. The other surprise is first boot: the installer builds 234 tables
and loads a demo catalogue before Apache starts, so the shop opens selling t-shirts and mugs.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `PS_DOMAIN` to this machine's LAN address and do not rebind 8138 to 0.0.0.0.
  That puts an unauthenticated shop on every network the user joins.
- Do not configure SMTP, and do not install a payment module or connect a processor.
- Do not enable PS_DEV_MODE or PS_DEMO_MODE.
