You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Trilium 0.104.1 under ~/selfhost/trilium, answering at http://localhost:8103.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Everything lands at http://localhost:8103, which means this computer wherever it is
read. Their phone cannot open these notes and neither can a second laptop. What they get is a
personal knowledge base on one machine, with no note limit and no upload limit.

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
distribution ID and codename print next, for step 2. Trilium needs 1024 MB of RAM available
and 5 GB free on the home disk, and the image publishes amd64 and arm64. Every branch prints
free memory, so one floor covers all three; on macOS and Windows it is the host's, and Docker
Desktop's virtual machine takes its allocation out of it. If available RAM is under 1024 MB or
free disk is under 5 GB, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/trilium/data ~/selfhost/trilium/backups
id -u
ls -la ~/selfhost/trilium
```

Assert: `data` and `backups` exist and belong to the user. On macOS and Windows, Docker
Desktop's file sharing decides what the container sees and there is no ownership to fix. On
Linux the mount is real: the container starts as root, chowns `data` to uid 1000 and drops to
that user, and 1000 is the number the first account on a desktop Linux install already has,
so `id -u` printed it and nothing changes.

Everything Trilium keeps goes in `data`: `document.db` with the notes in it, the `config.ini`
it writes on first start, its rolling backup copies, and the logs.

## 4. Secrets

One secret: the password the user will type into Trilium's set-password screen in step 7.
Generate it here, print it nowhere, and keep it out of your summary and out of any log line.

```bash
umask 077
openssl rand -base64 24 > ~/selfhost/trilium/login-password
chmod 600 ~/selfhost/trilium/login-password
umask 022
ls -l ~/selfhost/trilium/login-password
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. This value never reaches the container: Trilium takes its
password from a form a human fills in, so the credential stays out of the application's
environment. Tell the user to read it with `cat ~/selfhost/trilium/login-password`, and that
changing it later happens inside Trilium under Options, which does not update this file.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/trilium/compose.yml <<'EOF'
# Trilium · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.triliumnotes.org/user-guide/setup/server/installation/docker
#   configuration ...... https://docs.triliumnotes.org/user-guide/advanced-usage/configuration
#   data directory ..... https://docs.triliumnotes.org/user-guide/setup/data-directory
#   image definition ... https://github.com/TriliumNext/Trilium/blob/v0.104.1/apps/server/Dockerfile
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/trilium/, which lets one file work on macOS, Linux and Windows.
# ./data stays a bind mount rather than a named volume: upstream's own compose
# file mounts a home directory at this path on all three systems, and a reader
# should be able to see document.db in Finder or Explorer. The container starts
# as root, chowns that directory to the node user inside it and then drops to
# that user. No trusted-proxy setting, because nothing proxies this. Tag and
# digest were read from Docker Hub on 2026-08-06; the image publishes amd64 and
# arm64, plus armv7 and armv8 on a best-effort basis.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  trilium:
    image: triliumnext/trilium:v0.104.1@sha256:3332fa03198f0b3ecddf11fcf37f3aace352a664728d669a1ffa7a5594a6f2d6
    container_name: trilium
    restart: unless-stopped
    environment:
      # The single directory this service writes to, inside the container.
      TRILIUM_DATA_DIR: /home/node/trilium-data
      # Day notes roll over at midnight in this zone, and the daily automatic
      # backup follows it. UTC is the choice here; another tz database name is
      # a one-line edit.
      TZ: UTC
    volumes:
      - ./data:/home/node/trilium-data
    ports:
      # Loopback only: no other device on the wifi can reach 8103.
      - "127.0.0.1:8103:8080"
EOF
cd ~/selfhost/trilium && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount, and no
database container: Trilium writes a SQLite file into the folder step 3 created.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8103 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a
laptop on the same wifi, nor anyone on the internet. For a notebook holding everything they
think about, that is the trade. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/trilium/compose.yml
```

Assert: one line, `- "127.0.0.1:8103:8080"`. Nothing else publishes a port.

## 7. Start and verify

Read this whole block first. A brand new Trilium has no account and serves every request
without authentication until one exists. Step 6 keeps that window off the network, but the
password is still what stops anyone else who sits down at this keyboard.

```bash
cd ~/selfhost/trilium
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8103/api/health-check); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8103/api/health-check
curl -sS http://localhost:8103/bootstrap | grep -o '"triliumVersion":"[^"]*"'
```

Assert, all three, and print what you received for each: the loop ends on `200`; the health
call prints `{"status":"ok"}`; the last line prints `"triliumVersion":"0.104.1"`, which is how
you know the pinned digest is the code that is running. If any of the three misses, stop, run
`docker compose logs --tail 40 trilium`, and name the likely cause. If `port is already
allocated` came back, find what holds 8103 (`lsof -nP -iTCP:8103 -sTCP:LISTEN`,
`ss -ltnp | grep 8103` on Linux, `netstat -ano | findstr :8103` on Windows) and stop until the
user frees it.

The first screen at http://localhost:8103 is the setup wizard. It is headed `Language` with a
`Continue` button; the screen after that is headed `Get started with Trilium` and offers
`New knowledge base`. Once the knowledge base exists, Trilium shows a screen headed
`Set password`.

STOP: tell the user to open http://localhost:8103 now, pick a language, choose
`New knowledge base` and then `Empty`, and when the `Set password` screen appears to read
their password with `cat ~/selfhost/trilium/login-password` and paste it into both fields.
Wait. Do not continue until they confirm they are signed in.

Once they confirm, prove the instance now asks for that password:

```bash
curl -sS http://localhost:8103/bootstrap | grep -o '"loggedIn":false'
```

Assert: that prints `"loggedIn":false`. The same request answered without it a few minutes
ago, so this line is the difference between a notebook with a lock on it and one without. If
it prints nothing, the password was not set and the fix is to finish the wizard rather than to
carry on. A running container is not success.

## 8. First backup and restore

One artifact: the notes, the settings, the password file and the compose file that rebuilds
the service.

```bash
cd ~/selfhost/trilium
docker compose stop
tar -C ~/selfhost/trilium -czf ~/selfhost/trilium/backups/trilium-$(date +%F).tar.gz data login-password compose.yml
docker compose start
ls -lh ~/selfhost/trilium/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped for the
few seconds this takes, because Trilium writes its SQLite database continuously and a copy
taken mid-write is not a copy. Trilium keeps its own rolling copies inside `data/backup`, one
daily, one weekly, one monthly and one per version migration, all on this disk, so they cover
a bad edit and not a dead laptop.

That archive is on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder their sync
service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is
written `/d/Backups`, not `D:\Backups`. Assert: the user confirms the filename is listed
there. Say plainly that the archive holds their password in clear text, so that destination is
as sensitive as the notes.

To restore: `docker compose down`, `rm -rf ~/selfhost/trilium/data`, then
`tar -xzf` the archive back into ~/selfhost/trilium, then `docker compose up -d`. If `rm`
reports permission denied, that is the Linux ownership case from step 3 and `sudo rm -rf` is
the answer. The notes are in `data/document.db` and the password is in `login-password`. Tell
the user that is the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/TriliumNext/Trilium/releases. Take a backup
first, then edit the image line in ~/selfhost/trilium/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/trilium
docker compose pull
docker compose up -d
docker compose logs --tail 30 trilium
```

Trilium migrates its own database on the way up and writes a copy of the old one into
`data/backup` first. Watch that log until it settles, then re-run step 7's health check and
confirm `"triliumVersion"` reports the new number.

## 10. What will probably go wrong

I closed the laptop lid, opened it the next morning, went to http://localhost:8103 and got a
connection refused that read like a lost notebook. Nothing was lost: Docker Desktop had not
come back with the session, so nothing was listening on 8103, and `restart: unless-stopped`
only acts once the Docker daemon is running. Turn on Docker Desktop's start-at-login setting,
and after a reboot run `cd ~/selfhost/trilium && docker compose up -d` before concluding
anything is broken. Nothing in Trilium runs while this computer is asleep either, so its
daily backup happens when the lid is open and not before.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8103 to 0.0.0.0 so a phone can reach it. Until step 7 finishes, that puts an
  unauthenticated notebook on every network this machine joins.
- Do not set up sync or a second instance. Trilium's sync is one server and one desktop app
  holding the same single-user document, not a way to give a second person an account.
- Do not turn on batch OCR. Tesseract runs on this computer's own CPU, and processing an
  existing note tree is an hour of fan noise nobody asked for tonight.
