You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Super Productivity v18.19.0 under ~/selfhost/super-productivity, answering at
http://localhost:8199.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at all.
Super Productivity is local-first, and on this path that is literal twice over. The container is
nginx handing a built web app to the browser; upstream states that data is stored in the browser
and the container provides no persistent storage. So everything they type lives in this computer's
browser profile at http://localhost:8199, clearing site data for that address deletes their tasks,
and no phone or second laptop can open the list at all. What they get is a task list with
timeboxing, a Pomodoro timer and time tracking that never leaves this machine, and a backup that is
a file they export and keep.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. Super
Productivity needs 256 MB of RAM available and 2 GB free on the home disk; the image is about
320 MB and publishes linux/amd64 and linux/arm64. If available RAM is under 256 MB or free disk is
under 2 GB, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/super-productivity/backups
ls -la ~/selfhost/super-productivity
```

Assert: `backups` exists. There is no `data/` directory and no ownership fix to run on any of the
three systems, because step 5 mounts nothing: the container writes nothing you would want back.

## 4. Secrets

No secret is generated and there is no `.env` file. This build ships no account, no registration
form and no administration screen, so there is nothing to name, rotate or close, and no default
credential to worry about. Do not invent a first-run setup step for software with none.

One thing is worth saying anyway. The image's entrypoint can write
`assets/sync-config-default-override.json` from `WEBDAV_BASE_URL`, `WEBDAV_USERNAME`,
`WEBDAV_SYNC_FOLDER_PATH`, `SYNC_INTERVAL`, `IS_COMPRESSION_ENABLED` and `IS_ENCRYPTION_ENABLED`,
and step 5 sets none of them. Upstream provides no variable for a password in any case: a sync
password is typed into the browser and stored by the browser, never by this container.

## 5. compose.yml

```bash
cat > ~/selfhost/super-productivity/compose.yml <<'EOF'
# Super Productivity · the deterministic fallback for the local path. Authored
# by caniselfhostit from the upstream documentation, not copied from a
# repository:
#   run with docker .... https://github.com/super-productivity/super-productivity/blob/v18.19.0/docs/wiki/2.13-Run-with-Docker.md
#   image build ........ https://github.com/super-productivity/super-productivity/blob/v18.19.0/Dockerfile
#   entrypoint ......... https://github.com/super-productivity/super-productivity/blob/v18.19.0/docker-entrypoint.sh
#
# One service on the computer you are sitting at. No volumes and no bind mounts,
# because there is nothing to mount: the image is nginx serving the built web
# app as static files, and every task you type is stored by the browser under
# http://localhost:8199, not by this container. That is also why there is no
# .env and no environment block. Browsers treat http://localhost as a secure
# context, so the parts of the app that need WebCrypto keep working without a
# certificate.
#
# Tag v18.19.0 was released 2026-08-07; digest read from registry-1.docker.io on
# 2026-08-14, an OCI index covering linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  super-productivity:
    image: johannesjo/super-productivity:v18.19.0@sha256:ae91fe9ac19561e0f3669d15a2c4c71d7a75c43a29eb44ddc010ae50d1f63c82
    container_name: super-productivity
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    ports:
      # Loopback only: no other device on the wifi can reach 8199.
      - "127.0.0.1:8199:80"
EOF
cd ~/selfhost/super-productivity && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no volumes, no env file.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname to
resolve, and a certificate attests a public name that nothing here has. Browsers treat
http://localhost as a secure context anyway, which matters more for this app than for most: it
registers a service worker and uses WebCrypto, and both need that secure context. Nothing is
published beyond loopback, so no port needs closing. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/super-productivity/compose.yml
```

Assert: that count is exactly `1`. The user's phone cannot reach 8199, nor can a laptop on the same
wifi. For most apps that is a fair trade. For a task list it is the trade, because being open on a
second device is what a subscription was buying.

## 7. Start and verify

```bash
cd ~/selfhost/super-productivity
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8199/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sSL http://localhost:8199/ | grep -c '<title>Super Productivity</title>'
curl -sS http://localhost:8199/assets/sync-config-default-override.json; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8199/webdav/
docker compose ps
```

Assert all four and print what you received. The loop ends printing `200`. The title grep prints
`1`. The third command prints the served sync defaults, a single `_comment` key and nothing else,
which is the evidence that no server, account or credential was baked into the page. The fourth
prints `404`, the image's own proxy route answering with `WEBDAV_BACKEND` unset. If
`port is already allocated` came back, find what holds 8199 (`lsof -nP -iTCP:8199 -sTCP:LISTEN`,
`ss -ltnp | grep 8199` on Linux, `netstat -ano | findstr :8199` on Windows) and stop until the user
frees it. There is no sign-in step and no wizard. A running container is not success.

STOP: tell the user to open http://localhost:8199, add one throwaway task, and confirm the app loads with no login and the task appears. Do not continue until they confirm.

## 8. First backup and restore

Two backups, and they are not the same thing. Do both.

The first is this folder, and it is one file, because nothing else here is yours:

```bash
cd ~/selfhost/super-productivity
tar -C ~/selfhost/super-productivity -czf ~/selfhost/super-productivity/backups/super-productivity-$(date +%F).tar.gz compose.yml
ls -lh ~/selfhost/super-productivity/backups/
```

Assert: the archive exists and is non-empty. Print its size. To restore it: untar `compose.yml`
back into ~/selfhost/super-productivity and run `docker compose up -d`. That returns the same app
at the same address, and no tasks, because none were ever in this folder.

The second backup is the user's, and it is the one that matters. In the app: Settings, the
Sync & Backup tab, then Export data. That downloads one plaintext JSON file of tasks, projects,
tags, time tracking, notes, metrics and archives, which upstream describes as a restorable snapshot
of the application model. Import in the same place replaces current data with it, and that is the
restore. On the web build there is no automatic file backup to schedule, so this export is the
mechanism, and on a laptop the disk and the machine fail together.

STOP: tell the user to export that file now, then copy it somewhere that leaves this computer, a folder their sync service watches or a USB stick, and confirm the filename is listed there. Do not continue until they confirm.

## 9. Updating later

New versions are listed at https://github.com/super-productivity/super-productivity/releases. The
release tag and the image tag are the same string, and the image lives at
`johannesjo/super-productivity` even though the repository is now
`super-productivity/super-productivity`. Export first, then edit the image line in
~/selfhost/super-productivity/compose.yml to the new tag and its digest:

```bash
cd ~/selfhost/super-productivity
docker compose pull
docker compose up -d
docker compose logs --tail 20 super-productivity
```

Re-run step 7's checks. The app also updates itself through its service worker and asks the browser
to reload, so the user may be prompted minutes later. Their data is in that browser: reload, do not
clear.

## 10. What will probably go wrong

I rebooted, opened the bookmark out of habit, and got a connection error, which read like lost data
for about a minute. Docker Desktop had not started, so nothing was serving 8199; the tasks were
still in the browser, untouched, because they were never in the container. Turn on Docker Desktop's
start-at-login setting, and after any reboot run
`cd ~/selfhost/super-productivity && docker compose up -d` before believing anything is wrong. Two
more, both local-specific. The app refuses to run in two tabs at once and shows a blocker asking
you to close one, which reads like a crash until you notice the other tab. And a browser profile is
a fragile place to keep a working week: a cleaning extension, a privacy setting, or a denied
persistent-storage request can take the lot, which is why step 8 asks for a file off this machine.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8199 to 0.0.0.0 so a phone on the wifi can load it. It would not help: the phone
  would get its own empty list, because the data is in this browser and not in the container.
- Do not set `WEBDAV_BACKEND` or any `WEBDAV_` variable, and do not install SuperSync. Both are
  sync work, and sync on this build is a decision to make after reading the project page, not a
  variable to add here.
