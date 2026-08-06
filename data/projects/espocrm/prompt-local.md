You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install EspoCRM 10.0.3, with the MariaDB it stores every record in, under ~/selfhost/espocrm,
answering at http://localhost:8128.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install. A CRM is a
shared address book, and this one answers at http://localhost:8128, which means "this computer"
wherever it is typed: no colleague and not even their own phone can open it. The background jobs
run only while this machine is awake, so a laptop closed at 6pm is a CRM doing nothing overnight.
They get a complete sales database for one person.

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
distribution ID and codename print next, for step 2. EspoCRM and MariaDB need 2048 MB of RAM
available and 10 GB free on the home disk, and both images publish amd64 and arm64. On macOS and
Windows the figure printed is the host's, out of which Docker Desktop takes its own. If RAM is
under 2048 MB or free disk under 10 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/espocrm/data ~/selfhost/espocrm/custom ~/selfhost/espocrm/client-custom ~/selfhost/espocrm/backups
ls -la ~/selfhost/espocrm
```

Assert: `ls -la` shows all four, owned by the user. The EspoCRM container chowns the first three
to its web-server user on first start, directly on Linux and through Docker Desktop's file
sharing elsewhere, so there is no ownership command here. There is no database folder: MariaDB
chowns its data directory to a uid of its own, so step 5 puts that in a volume Docker manages.

## 4. Secrets

Three: the password EspoCRM connects to its database with, MariaDB's root password, and the
administrator password EspoCRM sets on first start. Generate all three here, print none, keep
them out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/espocrm/.env <<EOF
ESPOCRM_DATABASE_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ESPOCRM_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 ~/selfhost/espocrm/.env
umask 022
ls -l ~/selfhost/espocrm/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same on all three
systems. Left unset, upstream's entrypoint falls back to a built-in default for the admin and the
database account, warns in the log and starts anyway, so this block closes that door and step 7
proves it closed. The administrator password applies once, on first start: editing this file
later changes nothing, the change is made inside the CRM.

On Windows those mode bits are advisory. NTFS does not enforce them, and the real boundary is the
user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/espocrm/compose.yml <<'EOF'
# EspoCRM · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.espocrm.com/administration/docker/installation/
#   entrypoint script .. https://github.com/espocrm/espocrm-docker/blob/master/docker-entrypoint.sh
#   jobs and the daemon  https://docs.espocrm.com/administration/jobs/
#
# Four services on the computer you are sitting at, every application path
# relative to ~/selfhost/espocrm/ so one file works on macOS, Linux and Windows.
# The database is a named volume, not a bind mount: the MariaDB image chowns
# /var/lib/mysql to a uid Docker Desktop's Windows file sharing cannot grant on
# a home-directory bind mount. Only espocrm answers a browser, and the websocket
# is dialled at 8228 direct, there being no proxy to route /ws. Digests read
# from Docker Hub on 2026-08-06; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: espocrm

# The three EspoCRM services run one image over one set of directories, which
# upstream does with volumes_from. Compose ignores x- keys, so the pin below
# covers all three.
x-espocrm: &espocrm
  image: espocrm/espocrm:10.0.3@sha256:a2664ea087c2cbe2dc4bf3306c56b985402c19c2e758b39463742fae14dca513
  restart: unless-stopped
  volumes:
    - ./data:/var/www/html/data
    - ./custom:/var/www/html/custom
    - ./client-custom:/var/www/html/client/custom

services:
  espocrm-db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: espocrm
      MARIADB_USER: espocrm
      MARIADB_PASSWORD: ${ESPOCRM_DATABASE_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    volumes:
      - espocrm-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      start_period: 30s
      timeout: 10s
      retries: 6
    # No `ports:`: 3306 is reachable only from the other containers.

  espocrm:
    <<: *espocrm
    environment:
      ESPOCRM_DATABASE_HOST: espocrm-db
      ESPOCRM_DATABASE_USER: espocrm
      ESPOCRM_DATABASE_PASSWORD: ${ESPOCRM_DATABASE_PASSWORD}
      ESPOCRM_ADMIN_USERNAME: admin
      ESPOCRM_ADMIN_PASSWORD: ${ESPOCRM_ADMIN_PASSWORD}
      ESPOCRM_SITE_URL: http://localhost:8128
    healthcheck:
      # First start installs and builds the schema: minutes, not seconds.
      test: ["CMD", "bin/command", "app-check"]
      interval: 30s
      start_period: 180s
      timeout: 20s
      retries: 5
    ports:
      # Loopback only: no other device on the wifi can reach 8128.
      - "127.0.0.1:8128:80"
    depends_on:
      espocrm-db:
        condition: service_healthy

  espocrm-daemon:
    <<: *espocrm
    entrypoint: docker-daemon.sh
    depends_on:
      espocrm:
        condition: service_healthy
    # No healthcheck, no `ports:`: app-check reads the shared config, not the
    # job loop, so container state is the honest signal here.

  espocrm-websocket:
    <<: *espocrm
    entrypoint: docker-websocket.sh
    environment:
      # Written into the config all three share, which is how the app container
      # learns where to publish notifications.
      ESPOCRM_CONFIG_USE_WEB_SOCKET: "true"
      ESPOCRM_CONFIG_WEB_SOCKET_URL: ws://localhost:8228
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBSCRIBER_DSN: "tcp://*:7777"
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBMISSION_DSN: "tcp://espocrm-websocket:7777"
    ports:
      # Loopback only: the browser on this computer opens this directly.
      - "127.0.0.1:8228:8080"
    depends_on:
      espocrm:
        condition: service_healthy

volumes:
  espocrm-db:
EOF
cd ~/selfhost/espocrm && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Every `${...}` comes from step 4's `.env`, which
`docker compose` reads from this directory on its own.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the login form and the session cookie behave
  as over TLS.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8128 and 8228 bind to 127.0.0.1, this computer only: not the user's phone, not a laptop on the
same wifi, not anyone on the internet. Confirm that:

```bash
grep -n '127.0.0.1' ~/selfhost/espocrm/compose.yml
```

Assert: two lines, `- "127.0.0.1:8128:80"` and `- "127.0.0.1:8228:8080"`. MariaDB publishes no
host port, so 3306 cannot be there.

## 7. Start and verify

The first start is slow and correct: the app container installs itself and builds the schema
while the other two wait on its health check.

```bash
cd ~/selfhost/espocrm
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8128/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8128/ | grep -o '<title>EspoCRM</title>'
curl -sS -o /dev/null -w '%{http_code}\n' -u admin:password http://localhost:8128/api/v1/App/user
docker compose exec -T espocrm bin/command config:get useWebSocket
docker compose ps
```

Assert all five and print what you received for each. The loop ends on `200`, and it deserves its
full ten minutes. The second prints `<title>EspoCRM</title>`. The third prints `401`, the security
assert here: `admin` with upstream's built-in default is the first login anyone tries, and `401`
proves step 4 replaced it. The fourth prints `true`, which happens only once the websocket
container has written to the config all three share. The fifth lists four services, `espocrm-db`
and `espocrm` healthy. If any miss, stop, run `docker compose logs --tail 40 espocrm`, then
`--tail 20 espocrm-db`, and name the cause: a database that never reports healthy points at step
4. On `port is already allocated`, find what holds 8128 or 8228
(`lsof -nP -iTCP:8128 -sTCP:LISTEN`, or `netstat -ano | findstr :8128` on Windows) and stop until
the user frees it. A running container is not success.

The first screen at http://localhost:8128 is a login panel with a `Username` field, a `Password`
field and a `Log in` button.

STOP: tell the user to read their password with
`grep ESPOCRM_ADMIN_PASSWORD ~/selfhost/espocrm/.env`, put it in their password manager, sign in
as `admin`, and confirm the CRM loads. Wait. Do not continue until they confirm.

## 8. First backup and restore

Two artifacts: the rows, and the files that rebuild the service around them.

```bash
cd ~/selfhost/espocrm
docker compose exec -T espocrm-db sh -c 'exec mariadb-dump -u espocrm -p"$MARIADB_PASSWORD" --single-transaction espocrm' | gzip > ~/selfhost/espocrm/backups/espocrm-db-$(date +%F).sql.gz
tar -C ~/selfhost/espocrm -czf ~/selfhost/espocrm/backups/espocrm-files-$(date +%F).tar.gz compose.yml .env data custom client-custom
ls -lh ~/selfhost/espocrm/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database consistently.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are there. If they have
nowhere to put them, say plainly this install has no backup yet.

To restore, in this order. `cd ~/selfhost/espocrm`, untar the file archive there first so
compose.yml and .env are back before any container starts, because MariaDB reads its password
from .env the moment it initialises an empty volume. Then `docker compose down -v`, the one place
`-v` belongs because it drops the old volume on purpose, `docker compose up -d espocrm-db`, wait
30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T espocrm-db sh -c 'exec mariadb -u espocrm -p"$MARIADB_PASSWORD" espocrm'`,
then `docker compose up -d`, sign in, check a record is back.

## 9. Updating later

New versions are listed at https://github.com/espocrm/espocrm/releases. Take both backups first,
then edit the `espocrm/espocrm` image line in ~/selfhost/espocrm/compose.yml to the new tag and
digest: one line for three services, which is what `x-espocrm` is for.

```bash
cd ~/selfhost/espocrm
docker compose pull
docker compose up -d
docker compose logs --tail 30 espocrm
```

EspoCRM migrates its own database on the way up and refuses to start if a customization is
incompatible, naming the version to go back to. Watch that log settle, then re-run step 7.

## 10. What will probably go wrong

I rebooted, opened the CRM to check a follow-up, and got a connection error that read like a lost
database. It was not: Docker Desktop had not started with the session, so nothing was listening
on 8128. `restart: unless-stopped` acts only once the Docker daemon is up. Turn on its
start-at-login setting, then after a reboot run `cd ~/selfhost/espocrm && docker compose up -d`
and wait two or three minutes. The quieter half: every scheduled job the daemon owes you is
deferred while this machine sleeps, and they all fire at once when it wakes.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8128 to 0.0.0.0 so a phone or a colleague can reach it. That puts a CRM full of
  other people's contact details on every network this computer joins.
- Do not configure SMTP or an IMAP mailbox. Both need credentials from a mail provider the user
  has not been asked for.
- Do not install Advanced Pack, Sales Pack or any other extension. Those are paid products sold
  by EspoCRM's vendor, installed through the admin panel.
