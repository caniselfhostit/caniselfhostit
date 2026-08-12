You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Gotify 3.0.0 under ~/selfhost/gotify, answering at http://localhost:8206.

## 1. Preflight

Say this to the user before step 2 runs. A push server exists so a phone can get a message from
a script, and this one answers at http://localhost:8206, which means this computer and nothing
else. A phone on cellular cannot reach localhost, and push only works while Docker is running
and the machine is awake. Also say: there is no first-party iOS app; Android has the official
client. Admin credentials are generated into `.env` on this machine.

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
distribution ID and codename print next, for step 2. Gotify needs 256 MB of RAM available and 2 GB
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
mkdir -p ~/selfhost/gotify/data ~/selfhost/gotify/backups
ls -la ~/selfhost/gotify
```

Assert: `ls -la` shows `data` and `backups`. `data` is where Gotify writes SQLite (apps,
clients, messages, users).

## 4. Secrets

One secret: the password for the seeded admin account. Generate it here, print neither it nor a
summary that includes it.

```bash
umask 077
pass=$(openssl rand -base64 24)
cat > ~/selfhost/gotify/.env <<EOF
GOTIFY_DEFAULTUSER_NAME=admin
GOTIFY_DEFAULTUSER_PASS=${pass}
EOF
chmod 600 ~/selfhost/gotify/.env
unset pass
umask 022
ls -l ~/selfhost/gotify/.env
```

Assert: the file exists with mode `-rw-------` (advisory on Windows). Tell the user their
username is `admin` and they read the password with
`grep GOTIFY_DEFAULTUSER_PASS ~/selfhost/gotify/.env`. A backup without `.env` is a lockout.

## 5. compose.yml

```bash
cat > ~/selfhost/gotify/compose.yml <<'EOF'
# Gotify · the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   install ............ https://gotify.net/docs/install
#   configuration ...... https://gotify.net/docs/config
#
# One container on the computer you are sitting at. Paths are relative to
# ~/selfhost/gotify/. Admin seed credentials come from .env. Digest for
# server:3.0.0 read from Docker Hub on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  gotify:
    image: gotify/server:3.0.0@sha256:d75e89e0e28389c00c2556afe01282a37ee9756b0285799aa25214243aebd5e5
    container_name: gotify
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./data:/app/data
    ports:
      # Loopback only: no other device on the wifi can reach 8206.
      - "127.0.0.1:8206:80"
EOF
cd ~/selfhost/gotify && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount. Pin is
`3.0.0`, not the older `2.9.1` line.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers
treat http://localhost as a secure context anyway. Nothing is published beyond loopback, so no
port needs closing.

8206 is bound to 127.0.0.1, this computer only. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/gotify/compose.yml
```

Assert: the count is `1`. A phone on the wifi cannot reach this install without a rebind this
path does not do.

## 7. Start and verify

```bash
cd ~/selfhost/gotify
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8206/); echo "$i $code"; case "$code" in 200|301|302) break ;; esac; sleep 5; done
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8206/application
ADMIN_PASS=$(grep -E '^GOTIFY_DEFAULTUSER_PASS=' .env | cut -d= -f2-)
ADMIN_NAME=$(grep -E '^GOTIFY_DEFAULTUSER_NAME=' .env | cut -d= -f2-)
curl -sS -u "${ADMIN_NAME}:${ADMIN_PASS}" http://localhost:8206/current/user; echo
```

Assert: the loop ends on a success code, unauthenticated `/application` prints `401`, and
`/current/user` returns JSON with the admin name. If `port is already allocated`, find what
holds 8206 and stop until the user frees it. Do not print `$ADMIN_PASS`.

Application-token handoff: tell the user to open http://localhost:8206, sign in, create an
Application, copy its token, then:

```bash
curl -sS -X POST "http://localhost:8206/message?token=CHANGE_ME" -F "title=caniselfhostit" -F "message=hello from local install"
```

Assert: the POST returns a message `id`. The message should appear in the web UI. A phone will
not see it on this path unless the user later rebinds the port.

STOP: tell the user to confirm they signed in, created an application, and saw the test message
in the web UI. Do not continue until they confirm.

## 8. First backup and restore

One archive: `data/`, compose.yml and `.env`.

```bash
cd ~/selfhost/gotify
docker compose stop
tar -C ~/selfhost/gotify -czf ~/selfhost/gotify/backups/gotify-$(date +%F).tar.gz data compose.yml .env
docker compose start
ls -lh ~/selfhost/gotify/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds; the
container is stopped on purpose so SQLite is not copied mid-write.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`; confirm it exists before copying. Assert: the
user confirms the filename is listed there. If they have nowhere, say plainly that this install
has no backup.

To restore: `cd ~/selfhost/gotify`, `docker compose down`, `rm -rf data`, untar the archive
there (restores `.env` and compose.yml), then `docker compose up -d`. Both `data/` and `.env`
must come back together or login fails.

## 9. Updating later

New versions are listed at https://github.com/gotify/server/releases. Take a backup first, then
edit the image line in ~/selfhost/gotify/compose.yml to the new tag and its digest. Stay on the
3.x track unless a release note says otherwise.

```bash
cd ~/selfhost/gotify
docker compose pull
docker compose up -d
docker compose logs --tail 30 gotify
```

Re-run step 7's `401` and `/current/user` checks before calling the update done.

## 10. What will probably go wrong

You will paste a client token into a publish script and get 401. Application tokens send;
client tokens receive. Read the UI label twice. The other miss is expecting a phone on the same
wifi to open http://localhost:8206: localhost is that phone, not this computer. Use the VPS path
when a handset needs a public hostname. iOS has no official app; do not promise one.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8206 to 0.0.0.0 without understanding that every network this laptop joins can
  reach the login form.
- Do not install a third-party iOS client for the user.
- Do not put the admin password into compose.yml as a standing default string.
