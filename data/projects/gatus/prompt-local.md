You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Gatus 5.36.0 under ~/selfhost/gatus, answering at http://localhost:8132.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. A status page exists so that other people can read it, and this one answers at
http://localhost:8132, which means this computer and nothing else. Worse for a monitor: checks
run only while this machine is awake, and a closed laptop does not record an outage, it records
nothing. What they get is a private watchtower over their own sites that works while they are at
this desk.

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
distribution ID and codename print next, for step 2. Gatus needs 512 MB of RAM available and 5 GB
free on the home disk, and the image publishes amd64, arm64 and arm/v7. Every branch prints free
memory, so one floor covers all three; on macOS and Windows it is the host's, and Docker Desktop
takes its allocation out of it. If available RAM is under 512 MB or free disk is under 5 GB,
print both numbers and stop. Do not install and hope.

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

## 3. Layout and configuration

The configuration file is the product. It carries the monitors, their pass conditions and the
alerting, it is the only thing the user edits after today, and Gatus will not start without it,
so it is written before the container ever runs.

```bash
mkdir -p ~/selfhost/gatus/config ~/selfhost/gatus/data ~/selfhost/gatus/backups
cat > ~/selfhost/gatus/config/config.yaml <<'EOF'
# Gatus · the configuration is the product. Authored by caniselfhostit from
# https://github.com/TwiN/gatus/blob/v5.36.0/README.md#configuration
#
# example.org is a placeholder. Replace it with a site you actually care about.

storage:
  type: sqlite
  path: /data/data.db

endpoints:
  - name: gatus
    group: internal
    url: "http://127.0.0.1:8080/health"
    interval: 60s
    conditions:
      - "[STATUS] == 200"
      - "[BODY].status == UP"

  - name: example-site
    group: watched
    url: "https://example.org/"
    interval: 5m
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 2000"
      - "[CERTIFICATE_EXPIRATION] > 240h"

# Alerting is off. Every provider wants a webhook URL or a key from a service
# you sign up for. To turn Slack on: uncomment, paste your own webhook URL, and
# add an `alerts:` list with `- type: slack` under an endpoint.
#alerting:
#  slack:
#    webhook-url: "PASTE_YOUR_OWN_SLACK_WEBHOOK_URL_HERE"
EOF
chmod 600 ~/selfhost/gatus/config/config.yaml
ls -la ~/selfhost/gatus ~/selfhost/gatus/config
```

Assert: `ls -la` shows `config`, `data` and `backups`, and `config.yaml` at mode `-rw-------`.
No ownership fix is needed on any of the three systems: the image declares no user, so the
process runs as root and creates `data.db` in the mounted folder itself. The mode is 600 because
the alerting stanza is where a secret first lands. On Windows mode bits are advisory, and the
real boundary is the user's own Windows account.

## 4. Secrets

No secret is generated for this install and there is no `.env` file. Gatus ships no account, no
registration form and no administration screen, so there is nothing to name, rotate or close.
Exactly one route writes anything, the push endpoint for externally reported checks, and it
answers `401` to any call with no bearer token declared in the configuration first. Step 3
declared none, so that route has nothing to accept, and step 7 asserts it.

## 5. compose.yml

```bash
cat > ~/selfhost/gatus/compose.yml <<'EOF'
# Gatus · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   configuration ...... https://github.com/TwiN/gatus/blob/v5.36.0/README.md#configuration
#   image build ........ https://github.com/TwiN/gatus/blob/v5.36.0/Dockerfile
#
# One service on the computer you are sitting at. Both paths are relative to
# ~/selfhost/gatus/, so one file works on macOS, Linux and Windows, and both
# stay bind mounts rather than named volumes, so you can open config.yaml in
# Finder or Explorer. Storage is SQLite in ./data, because upstream's default is
# memory and upstream
# says memory does not survive a restart. The config directory is mounted rather
# than the single file, since Gatus polls the loaded path for changes and
# upstream reports that binding the file hides them. No healthcheck and no
# `user:` line, because the image is built FROM scratch: no shell to run a check
# with, no user database to name a user from. No .env: no secret. Digest read
# from ghcr.io on 2026-08-06; the list covers amd64, arm64 and arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  gatus:
    image: ghcr.io/twin/gatus:v5.36.0@sha256:c5f210d095fa78e6efaa20ffeb14803f2ba4f10615e16a6d12087697149617f0
    container_name: gatus
    restart: unless-stopped
    environment:
      # DEBUG here while a check fails for a reason the dashboard will not say.
      GATUS_LOG_LEVEL: INFO
    volumes:
      # config.yaml is the product. Read only: Gatus never writes here.
      - ./config:/config:ro
      # data.db, the SQLite file holding every result and every uptime figure.
      - ./data:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8132.
      - "127.0.0.1:8132:8080"
EOF
cd ~/selfhost/gatus && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, two bind mounts.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers
treat http://localhost as a secure context anyway. Nothing is published beyond loopback, so no
port needs closing.

8132 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop on
the same wifi, nor anyone on the internet. For most apps that is a fair trade; for a status page
it is the trade, because being readable by somebody else is the one thing this software exists to
do. Confirm the binding:

```bash
grep -n '127.0.0.1' ~/selfhost/gatus/compose.yml
```

Assert: one line, `- "127.0.0.1:8132:8080"`. The checks still reach the internet normally: a
loopback binding governs what can arrive, not what the container can call.

## 7. Start and verify

Gatus runs every endpoint once at start-up rather than waiting out the first interval, so results
exist seconds after it comes up.

```bash
cd ~/selfhost/gatus
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8132/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8132/health; echo
curl -sSL http://localhost:8132/ | grep -c 'Health Dashboard'
curl -sS http://localhost:8132/api/v1/endpoints/statuses | grep -o '"key":"[^"]*"'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST 'http://localhost:8132/api/v1/endpoints/watched_example-site/external?success=true'
```

Assert all five, and print what you received for each. The loop ends printing `200`. The health
endpoint answers `{"status":"UP"}`. The grep prints a number greater than `0`, because
`Health Dashboard` is the heading the page renders. The statuses call prints two lines,
`"key":"internal_gatus"` and `"key":"watched_example-site"`, which is step 3's configuration
loaded and checked once. The last command prints `401`: that push route is the only thing here
that writes, and it refuses a call carrying no bearer token. If any of the five misses, stop, run
`docker compose logs --tail 40 gatus`, and name the likely cause: a container that exits on its
own is step 3, because a configuration Gatus cannot parse makes it refuse to start. If
`port is already allocated` came back, find what holds 8132
(`lsof -nP -iTCP:8132 -sTCP:LISTEN`, `ss -ltnp | grep 8132` on Linux,
`netstat -ano | findstr :8132` on Windows) and stop until the user frees it. A running container
is not success.

STOP: tell the user to open http://localhost:8132, confirm they see two rows under the headings
`internal` and `watched`, and then replace `example.org` in ~/selfhost/gatus/config/config.yaml
with a site they actually care about. Do not continue until they confirm the two rows.

## 8. First backup and restore

One archive: the configuration, the results database and the compose file.

```bash
cd ~/selfhost/gatus
docker compose stop
tar -C ~/selfhost/gatus -czf ~/selfhost/gatus/backups/gatus-$(date +%F).tar.gz config data compose.yml
docker compose start
ls -lh ~/selfhost/gatus/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds; the
container is stopped on purpose, because a SQLite file copied mid-write is not a backup.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`; confirm it exists before copying. Assert: the
user confirms the filename is listed there. If they have nowhere, say plainly that this install
has no backup.

To restore: `cd ~/selfhost/gatus`, `docker compose down`, `rm -rf config data`, untar the archive
there, then `docker compose up -d`. Tell the user which half matters: `config/config.yaml` is
every monitor they ever wrote, and `data/data.db` is only the history behind them. Losing the
second costs the uptime figures. Losing the first costs the product.

## 9. Updating later

New versions are listed at https://github.com/TwiN/gatus/releases. The release tag and the image
tag are the same string. Take a backup first, then edit the image line in
~/selfhost/gatus/compose.yml to the new tag and its digest:

```bash
cd ~/selfhost/gatus
docker compose pull
docker compose up -d
docker compose logs --tail 30 gatus
```

Gatus migrates the SQLite schema on the way up. Watch that log until it settles, then re-run
step 7's `/health` and statuses checks before calling the update done.

## 10. What will probably go wrong

I closed the lid on a Friday, opened the dashboard on Monday, and it told me everything had been
up all weekend. It had told me nothing. The machine was asleep, so no check ran, and a check that
never ran leaves no failed result behind: uptime is worked out from the results that exist, so a
weekend-shaped hole reads as a clean weekend rather than as a gap. That is the honest shape of a
monitor on a laptop. Turn on Docker Desktop's start-at-login setting, and after any reboot run
`cd ~/selfhost/gatus && docker compose up -d` before believing a green figure.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8132 to 0.0.0.0 so a phone on the wifi can load the page. That puts a page
  listing every URL in config.yaml on every network this machine joins, with no login on it.
- Do not configure an alerting provider. Each one needs a webhook URL or a key from a service the
  user signs up for, and the commented block in config.yaml is where theirs goes.
- Do not switch `storage.type` to postgres. SQLite is why this is one container and one folder to
  copy.
