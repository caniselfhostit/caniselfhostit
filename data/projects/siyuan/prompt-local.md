You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install SiYuan 3.7.3 under ~/selfhost/siyuan, answering at http://localhost:8141.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
SiYuan is the outliner shape, blocks and block references and daily notes, and this install
puts it at http://localhost:8141, which means this computer and nowhere else. The phone they
would reach for at the moment worth writing down cannot open it, and neither can the SiYuan app
in the app stores: upstream states that the Docker deployment does not accept desktop or mobile
application connections and supports browsers only. What they get is a private notebook in one
browser, on one desk.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
id -u
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2, and `id -u` prints this account's user id,
which step 5 needs. SiYuan needs 1024 MB of RAM available and 5 GB free on the home disk, and the
image publishes amd64 and arm64. On macOS and Windows that memory figure is the host's, and
Docker Desktop's VM takes its allocation out of it. If available RAM is under 1024 MB or free
disk is under 5 GB, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/siyuan/workspace ~/selfhost/siyuan/backups
ls -la ~/selfhost/siyuan
```

Assert: `ls -la` shows `workspace` and `backups`, both owned by the user. Everything SiYuan keeps
goes under `workspace`, in folders openable in Finder or Explorer: `conf`, `temp`, and `data`
with one directory per notebook plus the `assets` folder pasted images land in. No ownership fix
runs here; step 5 handles the one case that needs it.

## 4. Secrets

One secret: the lock screen code, the only thing between this workspace and anyone else who
reaches this keyboard. Generate it here, print it nowhere, and keep it out of your summary and
out of any log line.

```bash
umask 077
cat > ~/selfhost/siyuan/.env <<EOF
SIYUAN_ACCESS_AUTH_CODE=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/siyuan/.env
umask 022
ls -l ~/selfhost/siyuan/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same on
all three systems. Upstream documents this value as an `--accessAuthCode` flag and as this
environment variable; the file is used because a command line is readable in every process
listing inside the container.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is the
user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/siyuan/compose.yml <<'EOF'
# SiYuan · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker deployment .. https://github.com/siyuan-note/siyuan/blob/v3.7.3/README.md
#   image entrypoint ... https://github.com/siyuan-note/siyuan/blob/v3.7.3/kernel/entrypoint.sh
#   kernel http api .... https://github.com/siyuan-note/siyuan/blob/v3.7.3/docs/API.md
#   access gate ........ https://github.com/siyuan-note/siyuan/blob/v3.7.3/kernel/model/session.go
#
# One service, paths relative to ~/selfhost/siyuan/ so one file works on macOS,
# Linux and Windows. `command:` is not optional: from v3.7.0 the kernel is a
# subcommand tree and the entrypoint rewrites the argument list around
# --workspace. PUID and PGID are the ids it re-execs as, and it chowns the
# mounted workspace to them at every start, which on Linux reaches real files
# in your home directory: step 5 rewrites them when this account is not uid
# 1000. Tag and digest read from Docker Hub on 2026-08-06; the image publishes
# amd64, arm64, armv7 and armv8.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  siyuan:
    image: b3log/siyuan:v3.7.3@sha256:908faf8ec55d391d95244982c081edabbaec118552d01fc3dc189d098cc0ffc8
    container_name: siyuan
    restart: unless-stopped
    command: ["serve", "--workspace=/siyuan/workspace"]
    env_file: ./.env
    environment:
      PUID: "1000"
      PGID: "1000"
      TZ: "UTC"
      SIYUAN_LANG: "en"
    volumes:
      # conf/, data/ and temp/ appear here on the first start. Notebooks are
      # folders of .sy JSON files under data/, pasted images in data/assets.
      - ./workspace:/siyuan/workspace
    ports:
      # Loopback only: no other device on the wifi can reach 8141.
      - "127.0.0.1:8141:6806"
    healthcheck:
      # No auth middleware on this route, so it answers before the unlock.
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:6806/api/system/version"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s
EOF
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "1000" ]; then
  sed -i "s/^      PUID: \"1000\"$/      PUID: \"$(id -u)\"/;s/^      PGID: \"1000\"$/      PGID: \"$(id -g)\"/" ~/selfhost/siyuan/compose.yml
fi
grep -E '^      P(U|G)ID:' ~/selfhost/siyuan/compose.yml
cd ~/selfhost/siyuan && docker compose config >/dev/null && echo "compose OK"
```

Assert: the grep prints two lines that, on Linux, match `id -u` and `id -g`; then `compose OK`.
The container chowns the workspace to `PUID:PGID` at every start, and on Linux that lands on the
user's own files, so an account that is not uid 1000 would lose them. It does nothing on macOS
or Windows.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the editor's crypto and clipboard work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8141 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the
wifi, not anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/siyuan/compose.yml
```

Assert: two lines, `- "127.0.0.1:8141:6806"` and the health check, which runs inside the
container.

## 7. Start and verify

The kernel builds its index on the first start, so the loop below is doing real work.

```bash
cd ~/selfhost/siyuan
docker compose pull
docker compose up -d
for i in $(seq 1 30); do body=$(curl -sS http://localhost:8141/api/system/bootProgress || true); echo "$i $body"; echo "$body" | grep -q '"progress":100' && break; sleep 10; done
curl -sS http://localhost:8141/api/system/version; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8141/
curl -sS -A 'Mozilla/5.0' -o /dev/null -w '%{http_code}\n' http://localhost:8141/
curl -sS http://localhost:8141/check-auth | grep -o 'Unlock access'
```

Assert all five, and print what you received for each. The loop ends on a body containing
`"progress":100`. The version call prints `{"code":0,"msg":"","data":"3.7.3"}`, the pin confirming
itself. The plain request to the root prints `401`, the kernel's answer to anything that is not a
browser, and the security assert in this block. The same request with a browser user agent prints
`302` to the unlock screen, and the last command prints `Unlock access`, the button on it. If any
of the five misses, stop, run `docker compose logs --tail 40 siyuan`, and name the likely cause:
a container that exits within seconds is step 4, because the kernel refuses to boot in a
container with no access code. If `port is already allocated` came back, find what holds 8141
with `lsof -nP -iTCP:8141 -sTCP:LISTEN` (`netstat -ano | findstr :8141` on Windows) and stop
until the user frees it. A running container is not success.

The first screen at http://localhost:8141 is that unlock page: a heading reading `workspace`, one
password box whose placeholder reads `Please enter the lock screen password`, and the
`Unlock access` button.

STOP: tell the user to read their code with
`grep SIYUAN_ACCESS_AUTH_CODE ~/selfhost/siyuan/.env`, put it in their password manager, open
http://localhost:8141, paste it into that box, press `Unlock access`, and wait. Do not continue
until they confirm the editor has loaded. Tell them a few wrong answers add a captcha to it.

## 8. First backup and restore

One archive: the whole workspace, the compose file and the env file.

```bash
cd ~/selfhost/siyuan
docker compose stop
tar -C ~/selfhost/siyuan -czf ~/selfhost/siyuan/backups/siyuan-$(date +%F).tar.gz workspace compose.yml .env
docker compose start
ls -lh ~/selfhost/siyuan/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds. The
container is stopped on purpose: the kernel holds a SQLite index open, and a database copied
mid-write is not a backup.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`; confirm the destination exists before copying.
Assert: the user confirms the filename is listed there. If they have nowhere to put it, say
plainly that this install has no backup.

To restore: `docker compose down`, `rm -rf ~/selfhost/siyuan/workspace`, untar the archive back
into ~/selfhost/siyuan, then `docker compose up -d` and unlock with the same code, which came out
of the archive in `.env`. Every notebook is a folder of `.sy` JSON files under `workspace/data`,
with pasted images in `workspace/data/assets`, so one lost document comes back with `tar -xzf`
and a copy. That is the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/siyuan-note/siyuan/releases. Take a backup first,
then edit the image line in ~/selfhost/siyuan/compose.yml to the new tag and its digest. The
Docker Hub tag keeps the leading `v`: release `v3.7.4` is image tag `v3.7.4`.

```bash
cd ~/selfhost/siyuan
docker compose pull
docker compose up -d
docker compose logs --tail 30 siyuan
```

SiYuan migrates its own workspace on the way up. Watch that log until it settles, then re-run
step 7's checks before calling the update done.

## 10. What will probably go wrong

I rebooted this machine, the browser restored the tab I had left open on http://localhost:8141,
and it came back a connection error. For a minute I believed a notebook was gone. It was
not: Docker Desktop had not started with the session, so nothing was listening on 8141, while
every note sat where it had been in ~/selfhost/siyuan/workspace/data. `restart: unless-stopped`
only acts once the Docker daemon is up. Turn on Docker Desktop's start-at-login setting, and
after a reboot run `cd ~/selfhost/siyuan && docker compose up -d` before concluding anything is
broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8141 to 0.0.0.0 so a phone on the wifi can reach it, and do not set
  `SIYUAN_ACCESS_AUTH_CODE_BYPASS`. The lock screen code is the only gate here: one exposes it to
  every network the user joins, the other removes it.
- Do not configure sync in the Settings screen. Every provider the kernel offers, S3, WebDAV and
  a plain local folder alike, checks for a paid SiYuan account first.
- Do not install the desktop or mobile app and point it at this address. Upstream lists
  application connections as unsupported for the Docker deployment.
