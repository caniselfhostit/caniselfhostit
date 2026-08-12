You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Netdata 2.10.4 under ~/selfhost/netdata, answering at http://localhost:8207.

## 1. Preflight

Say this to the user before anything installs. Metrics are about this machine only. On macOS
or Windows Docker Desktop the charts largely reflect the VM, not every host sensor. There is
no Netdata sign-in form on this path: loopback is the door. The agent is GPL-3.0-or-later; the
dashboard UI is closed-source under NCUL1.

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

Netdata needs 1024 MB of RAM available and 5 GB free on the home disk. The image publishes
amd64 and arm64. If available RAM is under 1024 MB or free disk is under 5 GB, print both
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
mkdir -p ~/selfhost/netdata/config ~/selfhost/netdata/lib ~/selfhost/netdata/cache ~/selfhost/netdata/backups
ls -la ~/selfhost/netdata
```

Assert: config, lib, cache and backups exist. Those three are the state mounts; there is no
empty `data/` directory in this install.

## 4. Secrets

No Caddy and no public hostname, so no basic_auth password is generated on the local path.
Loopback is the only door. Do not rebind the port to the LAN.

## 5. compose.yml

```bash
cat > ~/selfhost/netdata/compose.yml <<'EOF'
# Netdata · the single-container install for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker .............. https://learn.netdata.cloud/docs/installing/docker
#   license table ....... https://github.com/netdata/netdata/blob/v2.10.4/README.md
#
# One container on the computer you are sitting at. Paths are relative to
# ~/selfhost/netdata/. Host mounts for /proc and /sys only work usefully on
# Linux; on macOS and Windows Docker Desktop the charts reflect the VM more
# than the host. Tag and digest are v2.10.4 from Docker Hub on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  netdata:
    image: netdata/netdata:v2.10.4@sha256:689145f603fed0ca341b4d8a0fb9910cd9d8c0590b0530cd24ae1912a9c7f8f3
    container_name: netdata
    restart: unless-stopped
    hostname: netdata
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./config:/etc/netdata
      - ./lib:/var/lib/netdata
      - ./cache:/var/cache/netdata
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8207.
      - "127.0.0.1:8207:19999"
EOF
cd ~/selfhost/netdata && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. On Linux, `SYS_PTRACE`, `SYS_ADMIN` and `apparmor:unconfined`
widen host visibility the same way as the VPS path. On Docker Desktop they still apply to the
VM boundary.


On Linux this path is close to the VPS agent shape: host `/proc` and `/sys` are bind-mounted
read-only so charts track the machine you are sitting at. On macOS and Windows the same mounts
point into Docker Desktop's Linux VM, so fan sensors and bare-metal NIC names will not match
what Activity Monitor or Task Manager show. That is expected, not a broken install.

Capabilities still matter on Linux: `SYS_PTRACE` lets process charts work, `SYS_ADMIN` unlocks
host-level collectors, and `apparmor:unconfined` matches upstream docker packaging so AppArmor
does not block those reads. Do not add `privileged: true` on top. If compose refuses
apparmor options on a distribution without AppArmor, remove only the `security_opt` block and
re-try, then note that some collectors may stay dark.


## 6. Firewall

Nothing to open. Confirm loopback:

```bash
grep -c '"127.0.0.1:' ~/selfhost/netdata/compose.yml
```

Assert: that prints `1`. Do not rebind to `0.0.0.0`.

## 7. Start and verify

```bash
cd ~/selfhost/netdata
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8207/api/v1/info); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8207/api/v1/info | head -c 200; echo
curl -sSL http://localhost:8207/ | grep -ci 'netdata'
```

Assert: health loop ends on 200; info JSON returns; the dashboard HTML mentions netdata. There
is no setup wizard and no account to create.

STOP: tell the user to open http://localhost:8207 and confirm they see host charts. Do not continue until they confirm.

## 8. First backup and restore

```bash
cd ~/selfhost/netdata
docker compose stop
tar -C ~/selfhost/netdata -czf ~/selfhost/netdata/backups/netdata-$(date +%F).tar.gz config lib cache compose.yml
docker compose start
ls -lh ~/selfhost/netdata/backups/
```

Assert: the archive exists and is non-empty. Print its size. Copy it off this computer if the
user has a destination. To restore: `docker compose down`, remove config lib cache, untar,
`docker compose up -d`.


Restore detail: after untar, `config/` holds agent configuration files Netdata wrote on first
start, `lib/` holds the database of metrics, and `cache/` holds transient data that can rebuild.
Losing lib loses history; losing config loses local agent settings. Neither includes the VPS
password file, because the local path never created one.


## 9. Updating later

New versions are at https://github.com/netdata/netdata/releases. Take a backup first, then edit
the image line in ~/selfhost/netdata/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/netdata
docker compose pull
docker compose up -d
docker compose logs --tail 30 netdata
```

Re-run step 7's checks before calling the update done.

## 10. What will probably go wrong

On a Mac I opened the dashboard expecting laptop CPU charts and got a quiet Docker VM instead.
That is the local path's ceiling: Desktop virtualises the host. For real hardware sensors and
a fleet view, run the VPS path on the machine you actually care about, one agent per host.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8207 to 0.0.0.0.
- Do not set `privileged: true` in addition to the listed capabilities.
