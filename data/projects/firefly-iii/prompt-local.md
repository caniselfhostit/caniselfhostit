You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Firefly III 6.6.6, with the MariaDB it keeps the ledger in, under
~/selfhost/firefly-iii, answering at http://localhost:8155.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install. Firefly III has
no bank connection: transactions arrive as CSV exports from the bank, or typed in. The ledger
answers at http://localhost:8155, this computer only, so a phone cannot record a purchase. And
the daily 03:00 job behind recurring transactions, auto-budgets and bill warnings fires only
while this computer is awake with Docker running.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. This install needs 2048 MB of RAM
available and 10 GB free on the home disk; all three images publish amd64 and arm64. On macOS
and Windows that figure is the host's, and Docker Desktop takes a share. Under either floor,
print both and stop.

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
mkdir -p ~/selfhost/firefly-iii/backups
ls -la ~/selfhost/firefly-iii
```

Assert: `backups` exists, owned by the user. Nothing else belongs here: the database and the
attachment store are Docker volumes, because MariaDB and the application image each claim their
own directory at a uid a home-folder bind cannot grant on Windows.

## 4. Secrets

Three secrets: the application key, the database password, and the cron token. Print none of
them, in your summary or any log line. Hex, because upstream documents `APP_KEY` and
`STATIC_CRON_TOKEN` as exactly 32 characters with special characters avoided, and
`openssl rand -hex 16` gives 32 of `0-9a-f`.

```bash
umask 077
cat > ~/selfhost/firefly-iii/.env <<EOF
APP_URL=http://localhost:8155
TZ=UTC
APP_KEY=$(openssl rand -hex 16)
DB_PASSWORD=$(openssl rand -hex 32)
STATIC_CRON_TOKEN=$(openssl rand -hex 16)
EOF
chmod 600 ~/selfhost/firefly-iii/.env
umask 022
ls -l ~/selfhost/firefly-iii/.env
awk -F= '/^APP_KEY=/{print "APP_KEY length: " length($2)}' ~/selfhost/firefly-iii/.env
```

Assert: mode `-rw-------`, and the length line prints `APP_KEY length: 32`; anything else and
Firefly III refuses to boot. Git Bash ships openssl; on Windows the mode bits are advisory. Tell
the user `APP_KEY` is the value they cannot lose: a database restored without it is unreadable.

## 5. compose.yml

```bash
cat > ~/selfhost/firefly-iii/compose.yml <<'EOF'
# Firefly III · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.firefly-iii.org/how-to/firefly-iii/installation/docker/
#   variable reference . https://github.com/firefly-iii/firefly-iii/blob/v6.6.6/.env.example
#   cron jobs .......... https://docs.firefly-iii.org/how-to/firefly-iii/advanced/cron/
#
# Three services on the computer you are sitting at, .env read from
# ~/selfhost/firefly-iii/ so one file works on macOS, Linux and Windows. Both
# data directories are named volumes, not home-folder binds: MariaDB and the
# app image each claim their own directory at a uid Docker Desktop cannot grant
# on a Windows home folder. `cron` is BusyBox crond calling the app's cron
# endpoint daily; upstream states the image runs no scheduler. Digests read
# 2026-08-07, all three multi-arch.
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
      # Upstream's database.env invents a root password rather than store one.
      MARIADB_RANDOM_ROOT_PASSWORD: "true"
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - firefly-iii-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other containers.

  app:
    image: fireflyiii/core:version-6.6.6@sha256:ae69fdd95cdef9038cd7a460a5aec731f14813973e4f096511d5a4ea9ff0e972
    restart: unless-stopped
    env_file: ./.env
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
      - firefly-iii-upload:/var/www/html/storage/upload
    ports:
      # Loopback only: no other device on the wifi can reach 8155.
      - "127.0.0.1:8155:8080"
    depends_on:
      db:
        condition: service_healthy

  cron:
    image: alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
    restart: unless-stopped
    env_file: ./.env
    # 03:00 daily: recurring transactions, auto-budgets, rates, bill warnings.
    # The doubled $$ is compose's escape for one $, so the token is read inside
    # the container. TZ is UTC here, so BusyBox needs no tzdata.
    command: ["sh", "-c", "echo '0 3 * * * wget -qO- http://app:8080/api/v1/cron/'$$STATIC_CRON_TOKEN | crontab - && crond -f -L /dev/stdout"]
    depends_on:
      app:
        condition: service_started

volumes:
  firefly-iii-db:
  firefly-iii-upload:
EOF
cd ~/selfhost/firefly-iii && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Three services, one port, two named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. No hostname means
no DNS to wait for. No certificate, because one attests a public name and nothing here has one;
browsers treat http://localhost as a secure context anyway. No firewall rule, because nothing
leaves loopback: 8155 is on 127.0.0.1, not the phone, not the wifi, not the internet.

```bash
grep -c '"127.0.0.1:' ~/selfhost/firefly-iii/compose.yml
```

Assert: `1`, the single published port. MariaDB never publishes one.

## 7. Start and verify

Firefly III builds its schema on the way up: on an empty database, a minute or two of
answering 500. The loop waits it out.

```bash
cd ~/selfhost/firefly-iii
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8155/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8155/health
curl -sS http://localhost:8155/login | grep -c 'Sign in to start your session'
docker compose exec -T cron sh -c 'wget -qO- http://app:8080/api/v1/cron/$STATIC_CRON_TOKEN'
```

Assert all four, printing what you got: the loop ends on `200`; health answers with the two
letters `OK`; the grep prints `1`, meaning the first screen at http://localhost:8155/login
carries the heading `Sign in to start your session`; the last command prints JSON containing
`"job_fired":true`, proving the cron container reaches the app with an accepted token. If any
of the four misses, stop, run `docker compose logs --tail 40 app`, and name the cause: a
database that never reports healthy means step 4 wrote no `DB_PASSWORD`; a `500` that never
clears means a wrong-length `APP_KEY`; `port is already allocated` means something else holds
8155 (`lsof -nP -iTCP:8155 -sTCP:LISTEN`). A running container is not success.

STOP: tell the user to open http://localhost:8155/register, create the first account with an
email and a password they put in their password manager, and wait.
Do not continue until they confirm. No mail is sent here, so that password is the only way
back in.

Once they confirm, prove registration closed behind them.

```bash
curl -sS http://localhost:8155/register | grep -c 'Registration is currently not available'
```

Assert: that prints `1`. Firefly III ships in single-user mode: the register page serves a form
while the database holds no users, and refuses everyone after the first.

## 8. First backup and restore

Three artifacts: the dump with accounts, transactions, budgets and rules; the attachments read
inside the container that owns them; and the two config files.

```bash
cd ~/selfhost/firefly-iii
docker compose exec -T db sh -c 'exec mariadb-dump -ufirefly -p"$MARIADB_PASSWORD" --single-transaction firefly' | gzip > ~/selfhost/firefly-iii/backups/firefly-iii-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html/storage -czf - upload > ~/selfhost/firefly-iii/backups/firefly-iii-upload-$(date +%F).tar.gz
tar -C ~/selfhost/firefly-iii -czf ~/selfhost/firefly-iii/backups/firefly-iii-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/firefly-iii/backups/
```

Assert: all three exist, none is empty, print all three sizes. Nothing is stopped:
`--single-transaction` snapshots a running InnoDB database consistently, and the password stays
inside the container.

All three sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a synced folder or a USB
stick, copy all three there with `cp`, and assert they confirm all three are listed. In Git Bash
a Windows drive is `/d/Backups`, not `D:\Backups`.

To restore: untar the config archive into ~/selfhost/firefly-iii first, because MariaDB reads
its password from .env the moment it initialises an empty volume and Firefly III reads
`APP_KEY` from the same file. Then `docker compose down -v`, the one place `-v` belongs because
it drops the old volume on purpose; `docker compose up -d db`; 30 seconds for healthy;
`gunzip -c` the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -ufirefly -p"$MARIADB_PASSWORD" firefly'`;
`docker compose up -d`; then the upload archive through
`docker compose exec -T app sh -c 'tar -C /var/www/html/storage -xzf -'`. A dump without .env
is not a restore.

## 9. Updating later

New versions are at https://github.com/firefly-iii/firefly-iii/releases; a release's image tag
is `version-` plus its number. Back up first, then edit the image line in
~/selfhost/firefly-iii/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/firefly-iii
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

Watch that log until it settles, then re-run step 7's health check.

## 10. What will probably go wrong

I rebooted this machine, opened the ledger to log a coffee, and got a connection refused that
reads like a lost database. It was not: Docker Desktop had not started with the session, so
nothing was listening on 8155 and the 03:00 job had not run either, the quieter half of the
same problem. `restart: unless-stopped` acts only once the Docker daemon is up. Turn on
start-at-login, and after a reboot run `docker compose up -d` in that folder first.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8155 to 0.0.0.0 for a phone on the wifi. That puts a ledger of every account
  the user owns on every network they join.
- Do not install the Firefly III Data Importer. It is a separate application with its own
  container and token; this prompt installs the ledger it would feed.
- Do not regenerate `APP_KEY`. The key that encrypted the data is the only one that reads it.
