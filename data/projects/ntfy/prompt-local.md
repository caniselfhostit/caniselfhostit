You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install ntfy 2.27.0 under ~/selfhost/ntfy, answering at http://localhost:8200.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. A push broker exists so a phone can get a message from a script, and this one answers at
http://localhost:8200, which means this computer and nothing else. A phone on cellular cannot
reach localhost, and notifications only leave this box while Docker is running and the machine
is awake. What they get is a private broker for scripts on this desk and for apps that can
reach this host on the LAN if they later rebind the port (this install does not).

Also say: this install is closed. Auth default is deny-all. Users are created with
`ntfy user add` on the CLI, not in a browser wizard. There is no open topic for strangers.

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
distribution ID and codename print next, for step 2. ntfy needs 256 MB of RAM available and 2 GB
free on the home disk, and the image publishes amd64 and arm64. Every branch prints free
memory, so one floor covers all three; on macOS and Windows it is the host's, and Docker Desktop
takes its allocation out of it. If available RAM is under 256 MB or free disk is under 2 GB,
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

## 3. Layout

```bash
mkdir -p ~/selfhost/ntfy/cache ~/selfhost/ntfy/auth ~/selfhost/ntfy/backups
ls -la ~/selfhost/ntfy
```

Assert: `ls -la` shows `cache`, `auth` and `backups`. `cache` is the message cache and
attachments. `auth` is the user database. There is no empty `data/` directory.

## 4. Secrets

One secret: the password for the admin account you will create in step 7. Generate it here,
print neither it nor a summary that includes it, and keep it out of any log line.

```bash
umask 077
cat > ~/selfhost/ntfy/.env <<'EOF'
NTFY_BASE_URL=http://localhost:8200
NTFY_USERNAME=admin
NTFY_PASSWORD=PLACEHOLDER
EOF
# Replace PLACEHOLDER with a real secret without printing it:
pass=$(openssl rand -base64 24)
# portable in-place replace for the password line only
tmp=$(mktemp)
awk -v p="$pass" 'BEGIN{FS=OFS="="} $1=="NTFY_PASSWORD"{$2=p} {print}' ~/selfhost/ntfy/.env > "$tmp" && mv "$tmp" ~/selfhost/ntfy/.env
chmod 600 ~/selfhost/ntfy/.env
umask 022
unset pass
ls -l ~/selfhost/ntfy/.env
```

Assert: the file exists with mode `-rw-------` (on Windows mode bits are advisory). Tell the
user their username is `admin` and they read the password with
`grep NTFY_PASSWORD ~/selfhost/ntfy/.env`. NTFY_BASE_URL is the loopback URL for this path.

## 5. compose.yml

```bash
cat > ~/selfhost/ntfy/compose.yml <<'EOF'
# ntfy · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.ntfy.sh/install/#docker
#   configuration ...... https://docs.ntfy.sh/config/
#   access control ..... https://docs.ntfy.sh/config/#access-control
#
# One container on the computer you are sitting at. Paths are relative to
# ~/selfhost/ntfy/. Auth is closed by default (deny-all). NTFY_BASE_URL is the
# loopback URL on this machine. behind-proxy is off: nothing sits in front.
# Digest read from Docker Hub on 2026-08-07; the list covers amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  ntfy:
    image: binwiederhier/ntfy:v2.27.0@sha256:f2419f405127afa868f10985c1a41449e673477cee1eb19994339a5ae8b592e7
    container_name: ntfy
    restart: unless-stopped
    command: ["serve"]
    env_file: .env
    environment:
      NTFY_BASE_URL: ${NTFY_BASE_URL}
      NTFY_CACHE_FILE: /var/cache/ntfy/cache.db
      NTFY_ATTACHMENT_CACHE_DIR: /var/cache/ntfy/attachments
      NTFY_AUTH_FILE: /var/lib/ntfy/user.db
      NTFY_AUTH_DEFAULT_ACCESS: deny-all
      NTFY_ENABLE_LOGIN: "true"
    volumes:
      - ./cache:/var/cache/ntfy
      - ./auth:/var/lib/ntfy
    ports:
      # Loopback only: no other device on the wifi can reach 8200.
      - "127.0.0.1:8200:80"
EOF
cd ~/selfhost/ntfy && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, two bind mounts.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers
treat http://localhost as a secure context anyway. Nothing is published beyond loopback, so no
port needs closing.

8200 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop on
the same wifi, nor anyone on the internet. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/ntfy/compose.yml
```

Assert: the count is `1`. A phone test of this install requires a later rebind or a tunnel,
which this path does not do.

## 7. Start and verify

```bash
cd ~/selfhost/ntfy
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8200/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8200/v1/health; echo
```

Assert: the loop ends printing `200`. If `port is already allocated` came back, find what holds
8200 (`lsof -nP -iTCP:8200 -sTCP:LISTEN`, `ss -ltnp | grep 8200` on Linux,
`netstat -ano | findstr :8200` on Windows) and stop until the user frees it.

Create the admin user, then prove deny-all:

```bash
cd ~/selfhost/ntfy
NTFY_PASS=$(grep -E '^NTFY_PASSWORD=' .env | cut -d= -f2-)
NTFY_USER=$(grep -E '^NTFY_USERNAME=' .env | cut -d= -f2-)
docker compose exec -T -e NTFY_PASSWORD="$NTFY_PASS" ntfy ntfy user add --role=admin "$NTFY_USER"
docker compose exec -T ntfy ntfy user list
unauth=$(curl -sS -o /dev/null -w '%{http_code}' -d 'probe' http://localhost:8200/caniselfhostit-probe)
echo "anonymous publish: $unauth"
auth=$(curl -sS -o /dev/null -w '%{http_code}' -u "${NTFY_USER}:${NTFY_PASS}" -d 'install ok' http://localhost:8200/caniselfhostit-probe)
echo "authenticated publish: $auth"
```

Assert: `user list` shows admin, anonymous prints `403`, authenticated prints `200`. Do not
print `$NTFY_PASS`. A running container is not success.

STOP: tell the user to open http://localhost:8200, log in with admin and the password from `.env`, and confirm that an unauthenticated curl publish still returns 403. Do not continue until they confirm.

## 8. First backup and restore

One archive: the cache, the auth database, the compose file and `.env`.

```bash
cd ~/selfhost/ntfy
docker compose stop
tar -C ~/selfhost/ntfy -czf ~/selfhost/ntfy/backups/ntfy-$(date +%F).tar.gz cache auth compose.yml .env
docker compose start
ls -lh ~/selfhost/ntfy/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds; the
container is stopped on purpose so SQLite files are not copied mid-write.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`; confirm it exists before copying. Assert: the
user confirms the filename is listed there. If they have nowhere, say plainly that this install
has no backup.

To restore: `cd ~/selfhost/ntfy`, `docker compose down`, `rm -rf cache auth`, untar the archive
there (which restores `.env` and compose.yml), then `docker compose up -d`. Tell the user:
`auth/` is every account and `.env` holds the generated password. Losing either is a lockout.

## 9. Updating later

New versions are listed at https://github.com/binwiederhier/ntfy/releases. The release tag and
the image tag are the same string. Take a backup first, then edit the image line in
~/selfhost/ntfy/compose.yml to the new tag and its digest:

```bash
cd ~/selfhost/ntfy
docker compose pull
docker compose up -d
docker compose logs --tail 30 ntfy
```

Watch that log until it settles, then re-run step 7's health check and the anonymous `403`
assert before calling the update done.

## 10. What will probably go wrong

You will try to subscribe from a phone on the same wifi, and nothing will connect. This install
binds 8200 to 127.0.0.1 on purpose, so the phone never sees the port. That is not a bug in ntfy;
it is the local path's boundary. Use curl on this machine for the publish handoff, or move to
the VPS path when a phone needs a public hostname. The other miss is assuming iOS instant push
works without an upstream APNS bridge: on a pure localhost install it will not, and this path
does not set `NTFY_UPSTREAM_BASE_URL`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8200 to 0.0.0.0 so a phone on the wifi can publish without auth context you
  understand. deny-all still applies, but the attack surface grows.
- Do not enable signup. New accounts are `ntfy user add` only.
- Do not set Firebase credentials or an upstream base URL on this laptop path.
