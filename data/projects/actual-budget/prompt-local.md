You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Actual Budget 26.8.0 on this computer, reachable at http://localhost:8090 from
this machine and nowhere else, with everything it owns under ~/selfhost/actual-budget.

## 1. Preflight

Find out which computer this is. Every later step branches on this answer.

```bash
uname -s
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize ;;
  Linux) free -m ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`uname -s` prints `Darwin` for macOS, `Linux` for Linux, or a string starting `MINGW` or
`MSYS` for Windows under Git Bash.

Actual Budget needs 512 MB of RAM available and 5 GB free on the filesystem holding the
home directory. It runs on amd64 and arm64, so Apple Silicon is covered. On Linux read
the `available` column of `free -m`. On Darwin and Windows the command prints installed
memory in bytes, where 512 MB is 536870912: that is a floor, not the real ceiling, since
the container gets only what Docker Desktop's VM was given, under Settings, Resources.

If RAM is under 512 MB or free space is under 5 GB, print both numbers and stop. Do not
install and hope.

Say this to the user before anything is installed: their budget is about to live in one
folder on this computer and nowhere else, so the backup in step 8 is the whole safety net.

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
  repository, with its signing key saved to a file first, never piped into a shell.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

The Debian and Ubuntu branch in full, a no-op on any other system:

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

Tell the user in one sentence that docker group membership is root-equivalent on this
machine, and that the change lands at their next login, so they log out and back in
before continuing.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/actual-budget/data ~/selfhost/actual-budget/backups
ls -la ~/selfhost/actual-budget
```

The image creates an `actual` account with uid 1001 and runs as it, so on Linux `data` has
to belong to 1001 or the container cannot write account.sqlite. On Linux only, run:

```bash
sudo chown -R 1001:1001 ~/selfhost/actual-budget/data
```

On macOS and Windows do not run that: Docker Desktop's file sharing maps ownership between
its VM and the host, so the container writes as uid 1001 inside while the files stay the
user's own outside.

Assert: `ls -la` lists `data` and `backups`. Nothing in this install is written outside
~/selfhost/actual-budget.

## 4. Secrets

Nothing to generate here, and there is no `.env` file. Actual has exactly one credential,
the server password, and the user chooses it in a browser at step 7.

Tell the user two things before they choose it. That one password is the whole door to
every budget file this server holds. And end-to-end encryption is a separate,
per-file setting inside Actual, off by default, so until they turn it on the budget on
this disk is readable by anyone who can read the disk, which here means anyone who can
open this laptop.

## 5. compose.yml

```bash
cat > ~/selfhost/actual-budget/compose.yml <<'EOF'
# Actual Budget · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image, port, /data .. https://actualbudget.org/docs/install/docker
#   configuration ....... https://actualbudget.org/docs/config/
#   health route ........ https://github.com/actualbudget/actual/blob/master/packages/sync-server/src/scripts/health-check.js
#
# Every path here is relative to ~/selfhost/actual-budget/, which lets one file
# work on macOS, Linux and Windows. One container, no database process and no
# secret to generate: the sync server keeps account.sqlite and the budget blobs
# under /data, and the only credential is the server password you set in a
# browser at step 7. The image runs as uid 1001, which matters on Linux and
# which Docker Desktop handles elsewhere. Tag and digest are the 26.8.0 release
# read from Docker Hub on 2026-08-05, for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  actual:
    image: actualbudget/actual-server:26.8.0@sha256:0b300f370dba85a74998a953736a831bd931cc8cb76c0d8ceac3d3fd288dfd4d
    container_name: actual
    restart: unless-stopped
    environment:
      # Carried over so this file matches the server file line for line.
      # Nothing proxies to this container here and nothing sets an
      # X-Forwarded-For header, so on this path the setting does nothing.
      ACTUAL_TRUSTED_PROXIES: 172.16.0.0/12
    volumes:
      # server-files holds account.sqlite, user-files holds the budget blobs.
      # Local disk only: SQLite needs real POSIX file locks to stay intact.
      # Relative to this file, so the whole install is one folder to copy.
      - ./data:/data
    ports:
      # Loopback only. Nothing outside this computer reaches 8090, including
      # the phone on the same wifi. Step 6 says why that is the point.
      - "127.0.0.1:8090:5006"
EOF
cd ~/selfhost/actual-budget && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container listens on 5006 inside and 8090 is bound
to 127.0.0.1 out here. Upstream's own example publishes 5006 on every
interface, which would put the budget on whatever wifi this computer joins next; this file
does not.

## 6. Nothing is public

Nothing in this install is reachable from anywhere but this computer, and that is the
shape of this path, not a gap in it.

- `127.0.0.1:8090` binds the port to the loopback interface. The router, the coffee-shop
  network, and the user's own phone on the same wifi all get nothing.
- DNS, certificates and firewall rules do not apply here: no hostname to resolve, nothing
  to certify, no open port for a rule to cover.
- Browsers treat `http://localhost` as a secure context, so the Web Crypto behind Actual's
  end-to-end encryption works over plain HTTP here. Nothing is missing for want of TLS.
- Say the trade out loud: a sync server exists so a phone and a second browser see the
  same budget, and on this path the phone cannot reach it. The browser on this computer is
  the only client this install will ever have.
- The real boundary is the user's own account on this machine: anyone who can log in as
  them can read ~/selfhost/actual-budget, and on Windows its mode bits are advisory, so
  the account password is the protection that counts.

## 7. Start and verify

```bash
cd ~/selfhost/actual-budget
docker compose pull
docker compose up -d
sleep 15
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8090
curl -sS http://localhost:8090/health
echo
curl -sS http://localhost:8090/account/needs-bootstrap
echo
```

If `docker compose up -d` exits non-zero, do not run the curls: print its error. If it
names port 8090 as already allocated, something else on this computer holds it. Name that
with `lsof -nP -iTCP:8090 -sTCP:LISTEN` on macOS and Linux, or
`netstat -ano | findstr :8090` under Git Bash, tell the user, and stop rather than moving
to another port.

Assert, all three: the first prints `200`, `/health` prints JSON containing
`"status":"UP"`, and `/account/needs-bootstrap` prints JSON containing
`"bootstrapped":false`. Print exactly what you received for each. If any of the three
misses, stop, run `docker compose logs --tail 30 actual`, and name the likely earlier
step. On Linux a permission error mentioning /data is step 3 run without the chown. On
Windows a SQLite `database is locked` error means the folder is on the Windows filesystem
share, which has no real file locks: rerun this from a WSL 2 shell. A running container is
not success.

Actual has no base URL to configure: the page is served from the same origin it syncs to,
so http://localhost:8090 is the whole address, and what the user types if they later point
Actual's desktop build at this server.

The first screen at http://localhost:8090 asks the user to choose a password for this
server.

STOP: tell the user to open http://localhost:8090 now, set that password, and save it in
their password manager. Wait. Do not continue until they confirm.

```bash
curl -sS http://localhost:8090/account/needs-bootstrap
echo
```

Assert: this now prints `"bootstrapped":true`. Until it does, the password was not set,
and nothing else here matters yet.

## 8. First backup and restore

Take the backup now, before the user imports a single transaction. Stop the container
first: a SQLite file copied mid-write is not a backup. On Linux the files under `data`
belong to uid 1001 from step 3, so run both `tar` lines here, and the two restore lines
below, with `sudo`. Elsewhere they are the user's own files and plain tar reads them.

```bash
cd ~/selfhost/actual-budget
ARCHIVE=backups/actual-budget-$(date +%F).tar.gz
docker compose stop
tar -czf "$ARCHIVE" data
docker compose start
tar -tzf "$ARCHIVE" | grep server-files/account.sqlite
ls -lh "$ARCHIVE"
case "$(uname -s)" in Darwin) open . ;; Linux) xdg-open . ;; MINGW*|MSYS*) pwd -W; explorer.exe . ;; esac || true
```

Assert: the tar exited 0 and the listing printed `data/server-files/account.sqlite`. A tar
that failed part-way leaves a file too, so existence is not proof. Print its size. `data`
is the whole install: no `.env` here, that sqlite file holds the password hash,
`data/user-files` holds the budgets.

That archive sits on the same disk as the data, and on one computer the disk and the
machine fail together, so it is not yet a backup. The last command opened
~/selfhost/actual-budget in Finder or Explorer, and printed its `C:/` path under Git Bash.
Tell the user to copy the archive out of `backups` to somewhere that leaves this computer:
a folder a sync service already watches, or a USB stick. Wait for them to confirm.

To restore: `docker compose down`, then `rm -rf data`, then `tar -xzf` the newest archive
in `backups/`, then `docker compose up -d`. Those four commands are the whole disaster
plan, and this archive is what makes them work.

Tell the user: Actual exports a plain zip of any budget from inside the interface, and a
monthly one kept elsewhere is worth more than any archive here, because it opens without a
server.

## 9. Updating later

New versions are at https://github.com/actualbudget/actual/releases. Take a backup first
with the commands in step 8, then edit the `image:` line in
~/selfhost/actual-budget/compose.yml to the new tag and digest.

```bash
cd ~/selfhost/actual-budget
docker compose pull
docker compose up -d
docker compose logs --tail 20 actual
```

Actual migrates its own database on the next boot, and the browser caches the app, so load
http://localhost:8090 and hard-refresh once before calling the update done.

## 10. What will probably go wrong

The computer reboots and the budget looks deleted. `restart: unless-stopped` only means
Docker starts the container once Docker itself is up, and on macOS and Windows Docker
Desktop does not start itself unless somebody ticked that box. I rebooted, opened
http://localhost:8090 out of habit, got a page saying the site could not be reached, and
spent a minute genuinely believing a year of budget had gone. It had not: the container
was stopped, not deleted, and the folder untouched. Start Docker Desktop, run
`docker compose ps` in ~/selfhost/actual-budget, and if the container is not running, run
`docker compose up -d`. Tell the user to turn on Docker Desktop's
start-at-login setting, so this happens once.

## 11. Out of scope

- Do not expose this to the internet. The whole point of this path is one machine holding
  the money; reaching it from outside is the server path, a different prompt.
- Do not configure port forwarding on the router. A budget behind one password on a home
  router with no certificate is the worst of both paths.
- Do not add a reverse proxy or TLS. There is no hostname to certify, and
  `http://localhost` is already a secure context.
- Do not configure GoCardless, SimpleFIN or any other bank aggregator. Each is a separate
  signup with its own credentials, in the United States the usable one costs money, and
  the decision is the user's to make before moving a year of budget across.
- Do not enable OpenID login. One server password is the design here.
- Do not enable end-to-end encryption on the user's behalf. Losing that key loses the
  budget, and the choice belongs to whoever will have to remember it.
