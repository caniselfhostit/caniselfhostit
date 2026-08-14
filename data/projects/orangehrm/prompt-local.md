You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install OrangeHRM Starter 5.9 under ~/selfhost/orangehrm, answering at http://localhost:8194.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. An HR system exists so other people can file leave and look each other up, and this one
answers at http://localhost:8194: this computer, nobody else, nothing while the machine sleeps.
They get a private employee database with a leave calendar and a hiring pipeline.

Detect the OS and measure the machine:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. OrangeHRM needs
2048 MB of RAM available and 5 GB free on the home disk; if either is under, print both and stop.
Do not install and hope. `uname -m` decides whether this runs here at all, because the
`orangehrm/orangehrm:5.9` tag publishes one manifest and it is `linux/amd64`. On `x86_64`,
continue. On `arm64` under `Darwin`, say Docker Desktop runs this Intel image under emulation,
which works and is slower. On `arm64` elsewhere, print it and stop.

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
mkdir -p ~/selfhost/orangehrm/backups
ls -la ~/selfhost/orangehrm
```

Assert: `ls -la` shows `backups`, and that is the whole tree. Both mounts are Docker named
volumes rather than folders, so there is nothing to open in Finder or Explorer and no ownership
fix to run on any of the three systems.

## 4. Secrets

Two: the MariaDB root password and the password of the `orangehrm` database user. Generate both
here. Do not print either and do not repeat them in your summary. Hex not base64: Compose reads
them back out of `.env`, where a `$` interpolates and a `#` starts a comment.

```bash
umask 077
cat > ~/selfhost/orangehrm/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 24)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/orangehrm/.env
umask 022
ls -l ~/selfhost/orangehrm/.env
```

Assert: the file exists with mode `-rw-------`. On Windows those mode bits are advisory and the
real boundary is the user's own account, which on a single-user machine is the boundary that
matters. `DB_PASSWORD` is not only a compose variable: step 7 has the user read it and type it
into the installer, so give the command there, not the value here.

## 5. compose.yml

```bash
cat > ~/selfhost/orangehrm/compose.yml <<'EOF'
# OrangeHRM Starter · the deterministic fallback for the local path. Authored
# by caniselfhostit from the upstream packaging, not copied from a repository:
#   image build ....... https://github.com/orangehrm/orangehrm/blob/v5.9/Dockerfile
#   supported engines . https://github.com/orangehrm/orangehrm/blob/v5.9/installer/config/system_requirements.php
#   mariadb image ..... https://hub.docker.com/_/mariadb
#
# Two services on the computer you are sitting at, and both mounts are named
# volumes rather than relative bind mounts: the image declares /var/www/html a
# VOLUME that Docker has to fill from the image, and MariaDB chowns its own data
# directory to a uid Docker Desktop cannot grant on a Windows bind mount. So
# nothing here shows up in Finder or Explorer. Digests read on 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mariadb:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: orangehrm-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: orangehrm
      MARIADB_USER: orangehrm
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - orangehrm-db-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 15s
      interval: 10s
      retries: 30
    # No `ports:` at all: 3306 is reachable only from the other container.

  orangehrm:
    image: orangehrm/orangehrm:5.9@sha256:d692780efbb118b1ede754cfb153057baecf4c4c5f84627621ed015cf837ac28
    platform: linux/amd64
    container_name: orangehrm
    restart: unless-stopped
    volumes:
      # The application, lib/confs/Conf.php included. Losing it loses the
      # install, not the data: the data is in MariaDB.
      - orangehrm-app:/var/www/html
    ports:
      # Loopback only: no other device on the wifi can reach 8194.
      - "127.0.0.1:8194:80"
    depends_on:
      mariadb:
        condition: service_healthy

volumes:
  orangehrm-app:
  orangehrm-db-data:
EOF
cd ~/selfhost/orangehrm && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. MariaDB creates the `orangehrm` database and its user on first
start and stops there, with no tables in it: the `Existing Empty Database` step 7's wizard asks
about.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision: no hostname to
resolve, a certificate attests a public name nothing here has, nothing published past loopback.
Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/orangehrm/compose.yml
```

Assert: that prints `1`, the one published port, `- "127.0.0.1:8194:80"`. 8194 answers on this
computer only: not the user's phone, not a laptop on the wifi, nobody on the internet. That is
most of what this path costs, because the self-service half of the product has nobody to serve.
Browsers treat http://localhost as a secure context, so sign-in works without TLS.

## 7. Start and verify

OrangeHRM 5.9 has no environment variable that creates an administrator and no scriptable
installer, so only a person in a browser finishes this. Here that person is already at the
machine.

```bash
cd ~/selfhost/orangehrm
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sSL -o /dev/null -w '%{http_code}' http://localhost:8194/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL http://localhost:8194/ | grep -c 'welcome-screen'
docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SELECT 1" "$MARIADB_DATABASE"'
```

Assert all three and print what you received. The loop ends printing `200`. The grep prints `1`:
an uninstalled OrangeHRM redirects its root into the installer, and that page carries the
`welcome-screen` component. The query prints `1` under a `1` heading. On a miss run
`docker compose logs --tail 40 orangehrm`; if `port is already allocated` came back, find what
holds 8194 (`lsof -nP -iTCP:8194 -sTCP:LISTEN`, or `netstat -ano | findstr :8194`). Under
emulation the first page can take half a minute.

Give the user these two first:

- Database Configuration: pick `Existing Empty Database`, then host `mariadb`, port `3306`,
  database `orangehrm`, user `orangehrm`, password from
  `grep DB_PASSWORD ~/selfhost/orangehrm/.env`. Leave `Enable Data Encryption` unticked; it
  writes a key file every later backup has to carry.
- Admin User screen: untick the box offering to register the system with OrangeHRM. It is ticked
  by default, and ticked it posts their name, email, phone number and organisation name off this
  machine, the only thing here that leaves it. The admin password wants 8 characters or more, no
  spaces, and a lower-case letter, an upper-case letter, a digit and a symbol.

STOP: tell the user to open http://localhost:8194, complete the setup wizard, and say when they
reach the screen that reports the installation is complete.
Do not continue until they confirm.

Confirm the installer is closed:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' 'http://localhost:8194/installer/index.php/installer/database-config'
curl -sSL http://localhost:8194/ | grep -c 'auth-login'
```

Assert both and print the values. The first prints `502`: with the configuration file written
upstream refuses every installer screen, for good. The second prints `1`, the login component the
root now redirects to. Anything but `502` means the wizard did not finish.

## 8. First backup and restore

Three artifacts. Two come out of Docker, because neither mount is a folder you can open: the
dump holds every employee, leave request, timesheet and document, and the confs archive holds
`lib/confs/Conf.php`. The third holds compose.yml and `.env`.

```bash
cd ~/selfhost/orangehrm
docker compose exec -T mariadb sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" --single-transaction "$MARIADB_DATABASE"' | gzip > backups/orangehrm-db-$(date +%F).sql.gz
docker compose exec -T orangehrm tar -C /var/www/html -czf - lib/confs > backups/orangehrm-confs-$(date +%F).tar.gz
tar -C ~/selfhost/orangehrm -czf backups/orangehrm-config-$(date +%F).tar.gz compose.yml .env
ls -lh backups/
```

Assert: all three exist, all three are non-empty, all three sizes printed.

Those archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for somewhere that leaves this computer, a folder
their sync service watches or a USB stick, and copy them there with `cp`. In Git Bash a Windows
drive is `/d/Backups`, not `D:\Backups`. Assert: the user confirms the three names are there. If
they have nowhere, say plainly that this install has no backup.

To restore, in order. `docker compose down -v` drops both volumes. Untar the config archive into
~/selfhost/orangehrm so `.env` is back first, then `docker compose up -d mariadb` and wait for
healthy. Pipe `gunzip -c` on the dump into
`docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Put the configuration file back before Apache serves a request:
`docker compose run --rm --no-deps -T orangehrm tar -C /var/www/html -xzf - < backups/orangehrm-confs-<date>.tar.gz`,
which fills the fresh volume and swaps the web server for `tar`. Then `docker compose up -d`.

## 9. Updating later

Releases are at https://github.com/orangehrm/orangehrm/releases, image tags at
https://hub.docker.com/r/orangehrm/orangehrm/tags. Take step 8's backups first: this is the one
operation here that can lose data. A newer image alone changes nothing, because Docker fills a
named volume from the image only when it does not exist. Edit the image line to the new tag and
digest, then take the volume away:

```bash
cd ~/selfhost/orangehrm
docker compose down
docker volume rm orangehrm_orangehrm-app
docker compose pull
docker compose up -d
```

The new code arrives with no `lib/confs/Conf.php`, so the site is a setup wizard again. Open it,
choose `Upgrading an Existing Installation`, give it step 7's database details, and pick the
version upgraded from. Do not restore the confs archive: the new code writes its own.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8194 out of habit, got nothing at all, and for a minute
thought the install had eaten itself. Docker Desktop had not started with the machine, so neither
container existed to answer, and a browser with nothing on the other end looks exactly like a
broken install. Turn on Docker Desktop's start-at-login setting, and after any reboot run
`cd ~/selfhost/orangehrm && docker compose up -d` before believing an empty page.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8194 to 0.0.0.0 so colleagues on the wifi can reach it. That puts a database of
  personnel records on every network this machine joins.
- Do not configure SMTP, LDAP or an OpenID Connect provider. All three exist here, and each is
  another system to keep working.
