You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Grafana OSS 13.1.2 under ~/selfhost/grafana, answering at http://localhost:8106.

## 1. Preflight

Say both of these to the user before step 2 runs; together they decide whether they want this
install at all. Grafana draws pictures of data it does not hold: it ships with no metrics and no
logs of its own, so this ends at an empty dashboard tool until something else makes numbers.
And it answers at http://localhost:8106, this computer and nowhere else: a dashboard link sent
to a colleague opens nothing, their phone cannot load it, and alert rules
evaluate only while this machine is awake. A laptop that closes at six is a monitor that stops
watching at six.

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
distribution ID and codename print next, for step 2. Upstream documents a minimum of 512 MB of
memory and one CPU core; this install wants 512 MB available and 5 GB free on the home disk, and
the image publishes amd64 and arm64. On macOS and Windows that figure is the host's, and Docker
Desktop takes its allocation out of it. If RAM is under 512 MB or disk under 5 GB, print both
numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/grafana/data ~/selfhost/grafana/backups
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "472" ]; then
  sudo chown -R 472:0 ~/selfhost/grafana/data
fi
ls -la ~/selfhost/grafana
```

Assert: `ls -la` lists `data` and `backups`, and nothing is written outside that folder. The
container runs as uid 472, so on Linux `data` has to belong to that uid; Grafana does not fix
that itself, it warns that its data path is not writable and then fails to build a database. On
macOS and Windows Docker Desktop grants access whatever the number on disk says, so the line
does nothing there. `data` holds `grafana.db`, a SQLite file: keep it on this computer's own
disk, not a sync folder or a network drive.

## 4. Secrets

Two values are generated here. Print neither, and keep both out of your summary and out of any
log line. Hex rather than base64, because both travel through an env file Compose reads.

Grafana creates its admin account on the very first start, using whatever
`GF_SECURITY_ADMIN_PASSWORD` says then, and upstream ships the literal word `admin` as that
setting's value: writing this file first is what stops a known credential from existing.
`GF_SECURITY_SECRET_KEY` encrypts data-source passwords and alerting credentials in the
database, and upstream ships a fixed string for it in `conf/defaults.ini` that anyone can read.
Set it now: upstream documents that changing it later forces every stored data-source secret to
be re-typed.

```bash
umask 077
cat > ~/selfhost/grafana/.env <<EOF
GF_SERVER_ROOT_URL=http://localhost:8106/
GF_SERVER_DOMAIN=localhost
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -hex 24)
GF_SECURITY_SECRET_KEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/grafana/.env
umask 022
ls -l ~/selfhost/grafana/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same everywhere. On Windows those mode bits are advisory: NTFS does not enforce them, and the
real boundary is the user's own account. Tell the user to read the password with
`grep GF_SECURITY_ADMIN_PASSWORD ~/selfhost/grafana/.env` and store it before step 7.

## 5. compose.yml

```bash
cat > ~/selfhost/grafana/compose.yml <<'EOF'
# Grafana OSS · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/
#   docker config ...... https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/
#   settings reference . https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
#
# One container, every path relative to ~/selfhost/grafana/, so one file works
# on macOS, Linux and Windows. The data directory is a bind mount, not a named
# volume: Grafana never chowns it at runtime, so grafana.db stays visible in
# Finder. On Linux it must belong to uid 472, which step 3 arranges. The image
# is grafana/grafana, not grafana/grafana-oss: upstream stopped updating the
# grafana-oss repository at the 12.4.0 release. Digest read 2026-08-06, for
# linux/amd64, arm64 and arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  grafana:
    image: grafana/grafana:13.1.2@sha256:d177053ab62253815f130d81504f77063baf5fd4ca93299d6048453bd31e047a
    container_name: grafana
    restart: unless-stopped
    # The address and the two generated values live here, mode 600.
    env_file: ./.env
    environment:
      # No TLS here, so the cookie cannot be marked secure: a browser would
      # refuse to send it back over plain http.
      GF_SECURITY_COOKIE_SECURE: "false"
      # Already upstream's default, written out because it decides whether
      # anyone reaching this page can enrol.
      GF_USERS_ALLOW_SIGN_UP: "false"
      # Upstream ships all three on: usage counters to stats.grafana.org and
      # version checks against grafana.com.
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
    volumes:
      # grafana.db, plugins and rendered exports land here.
      - ./data:/var/lib/grafana
    healthcheck:
      # curl is in upstream's alpine image; /api/health answers 200 while the
      # database responds.
      test: ["CMD-SHELL", "curl -fsS http://localhost:3000/api/health || exit 1"]
      interval: 15s
      retries: 10
      start_period: 30s
    ports:
      # Loopback only: no other device on the wifi can reach 8106.
      - "127.0.0.1:8106:3000"
EOF
cd ~/selfhost/grafana && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the login form still works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8106 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the wifi,
not anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/grafana/compose.yml
```

Assert: one line, `- "127.0.0.1:8106:3000"`.

## 7. Start and verify

Grafana builds its SQLite schema and creates the admin account on the first start, so give it a
moment before treating anything as broken.

```bash
cd ~/selfhost/grafana
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8106/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8106/api/health
echo
curl -sS -o /dev/null -w '%{http_code}\n' -u admin:admin http://localhost:8106/api/org
curl -sSL http://localhost:8106/login | grep -c '<title>Grafana</title>'
```

Assert all four, and print what you received for each: the loop ends on `200`; the health
response contains `"database": "ok"` and `"version": "13.1.2"`; the call using upstream's
shipped default credential prints `401`, proving the account Grafana would have made with a
known password does not exist; the last prints `1`, the served login page.

If any of the four misses, stop, run `docker compose logs --tail 40 grafana` and name the likely
earlier step. `GF_PATHS_DATA='/var/lib/grafana' is not writable` in that log is step 3 gone wrong
on Linux. A `200` from the `-u admin:admin` call means the container started before step 4 wrote
the file: `docker compose down`, delete `data`, redo step 3, redo step 7. If `port is already
allocated` came back, find what holds 8106 (`lsof -nP -iTCP:8106 -sTCP:LISTEN`, or
`netstat -ano | findstr :8106` on Windows) and stop until the user frees it. A running container
is not success.

The first screen at http://localhost:8106 is a sign-in form under the heading
`Welcome to Grafana`.

STOP: tell the user to open http://localhost:8106, sign in with the username `admin` and the
password from step 4, and confirm they reach a page offering to add a data source. Wait. Do not
continue until they confirm in words.

## 8. First backup and restore

One archive: the SQLite database, the two generated values and the compose file, the whole
install. Stop the container first: a SQLite file copied while Grafana is writing is not a
backup.

```bash
cd ~/selfhost/grafana
docker compose stop
ARC=~/selfhost/grafana/backups/grafana-$(date +%F).tar.gz
if [ "$(uname -s)" = "Linux" ]; then
  sudo tar -C ~/selfhost/grafana -czf "$ARC" compose.yml .env data
  sudo chown "$(id -u):$(id -g)" "$ARC"
else
  tar -C ~/selfhost/grafana -czf "$ARC" compose.yml .env data
fi
docker compose start
ls -lh ~/selfhost/grafana/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds. The
branch exists because on Linux `data` belongs to the container's uid; on macOS and Windows those
files already read as the user's own.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is written
`/d/Backups`, not `D:\Backups`. Assert: the user confirms the filename is listed there. If they
have nowhere to put it, say plainly that this install has no backup.

To restore: `docker compose down`, delete `data`, untar the archive back into ~/selfhost/grafana,
re-run step 3 for the ownership, then `docker compose up -d` and re-run step 7's health check.
Tell the user what is at stake: `.env` holds the key their data-source passwords are encrypted
with, so an archive without it cannot be opened.

## 9. Updating later

New versions are listed at https://github.com/grafana/grafana/releases. Take a backup first,
then edit the image line in ~/selfhost/grafana/compose.yml to the new tag and its digest:

```bash
cd ~/selfhost/grafana
docker compose pull
docker compose up -d
docker compose logs --tail 30 grafana
```

Grafana migrates its own database on the way up, so watch that log until it settles, then re-run
step 7's health check, and read the release notes for any major version step.

## 10. What will probably go wrong

I rebooted, opened the bookmark, and got a connection refused that read like a lost install. It
was not: Docker Desktop had not started with the session, so nothing was listening on 8106.
`restart: unless-stopped` acts only once the Docker daemon is up. Turn on its start-at-login
setting, and after a reboot run `cd ~/selfhost/grafana && docker compose up -d` before deciding
anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not install Prometheus, Loki, InfluxDB or any other data source. Each is its own service
  with its own storage, and this prompt installs the one that draws the pictures.
- Do not configure SMTP, and do not switch the database to PostgreSQL or MySQL. SQLite is what
  makes this one container and what step 8 is written for.
