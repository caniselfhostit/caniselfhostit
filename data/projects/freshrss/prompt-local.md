You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install FreshRSS 1.29.1 on this computer, reachable at http://localhost:8084, with every
file it owns under ~/selfhost/freshrss/.

## 1. Preflight

Say this to the user before installing anything, and do not soften it: FreshRSS fetches
feeds only while this computer is awake with Docker running, so a closed lid is a reader
that stops collecting, and nothing here is reachable from another device, so a phone
reader app cannot connect. Reading happens where the install is.

Then measure the machine. FreshRSS needs 512 MB of RAM and 5 GB free on the disk the home
directory sits on, and the 1.29.1 image covers amd64 and arm64, so Apple Silicon is fine.

```bash
uname -s
case "$(uname -s)" in
  Darwin)       sysctl -n hw.memsize | awk '{print int($1/1048576) " MB of RAM installed"}' ;;
  Linux)        free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`uname -s` prints `Darwin` on macOS, `Linux` on Linux, and a string starting `MINGW` or
`MSYS` in Git Bash on Windows. Remember which one: three later steps branch on it. The
Windows line prints bytes, so divide by 1048576 before comparing, and like the macOS line
it reports RAM installed; only the Linux line reports what is free now. Compare whichever
number this machine printed: if it is under 512 MB, or the home filesystem has under 5 GB
free, print both and stop. Do not install and hope.

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

The Debian and Ubuntu branch in full:

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

If that block ran, tell the user in one sentence that `docker` group membership is
root-equivalent here, then STOP: it lands at their next login, so they log out, log back
in, and run this prompt again from step 2. Do not continue until they confirm.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

Everything FreshRSS owns lives in one folder under the home directory. On Windows that
folder stays on the local system drive, never in a OneDrive-synced folder, never on a
mapped network drive: SQLite needs real file locks, and the usual cause of a later
`database is locked` or `disk I/O error` is that it moved.

```bash
mkdir -p ~/selfhost/freshrss/data ~/selfhost/freshrss/backups
case "$(uname -s)" in
  Linux) sudo chown -R 33:33 ~/selfhost/freshrss/data ;;
esac
ls -la ~/selfhost/freshrss
```

Assert: `ls -la` shows `data` and `backups` under ~/selfhost/freshrss. uid 33 is
`www-data` in the image, the user that writes the SQLite database, so on Linux the bind
mount must belong to it or the container starts and cannot write. On macOS and Windows the
chown does not run and is not missing: Docker Desktop's file sharing owns that problem.

## 4. Secrets

One secret: the password for the user's FreshRSS account, generated here. Do not print it,
repeat it in your summary, or put it in any log line. Git Bash ships openssl, so this is
the same command on all three systems.

```bash
umask 077
cat > ~/selfhost/freshrss/.env <<EOF
TZ=UTC
CRON_MIN=13,43
ADMIN_USER=admin
ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 ~/selfhost/freshrss/.env
umask 022
ls -l ~/selfhost/freshrss/.env
```

Assert: the file exists, and on macOS and Linux its mode reads `-rw-------`. Tell the user
their username is `admin`, that they read the password once with
`grep ADMIN_PASSWORD ~/selfhost/freshrss/.env`, and put it in their password manager.
`CRON_MIN` is the image's own cron daemon, unset means nothing refreshes, and `13,43` is
when it runs each hour. Article times display in UTC: for local time, set `TZ=` to a zone
like `Europe/Berlin` and run `docker compose up -d` again.

On Windows, `chmod 600` sets a bit Git Bash records and NTFS treats as advisory, so the
mode on screen is not protection. The real boundary is the user's own account: anyone who
can log in as them reads this file.

## 5. compose.yml

```bash
cat > ~/selfhost/freshrss/compose.yml <<'EOF'
# FreshRSS · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image and env vars . https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md
#   built-in cron ...... https://freshrss.github.io/FreshRSS/en/admins/08_FeedUpdates.html
#   what to back up .... https://freshrss.github.io/FreshRSS/en/admins/05_Backup.html
#
# One container, on the computer the reader is sitting at. This file lives in
# ~/selfhost/freshrss/, so its paths are relative and one file works the same on
# macOS, Linux and Windows. FreshRSS ships with SQLite, so the database, the user
# record and the favicons live under /var/www/FreshRSS/data, and that directory
# is what a backup has to contain. CRON_MIN is the image's own cron daemon, and
# leaving it unset means nothing refreshes. No proxy sits in front of this
# container, so the VPS file's TRUSTED_PROXY is absent. Tag and digest are the
# 1.29.1 release read from Docker Hub on 2026-08-05, covering amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  freshrss:
    image: freshrss/freshrss:1.29.1@sha256:ab6b363102ccdbc39f6a62db926f567c61a5289bf25ba460f1c34423d8cc1a4d
    container_name: freshrss
    restart: unless-stopped
    env_file: ./.env
    volumes:
      # uid 33 (www-data) in the image writes here, which is why the layout step
      # chowns ./data on Linux; on macOS and Windows Docker Desktop maps the uid
      # instead. Local disk only, never a network share: SQLite needs real POSIX
      # file locks to stay intact.
      - ./data:/var/www/FreshRSS/data
    ports:
      # Loopback only. Nothing outside this computer can open a connection to
      # 8084, and that is the posture of this path rather than a limit on it.
      # Same host port the VPS compose file publishes.
      - "127.0.0.1:8084:80"
EOF
cd ~/selfhost/freshrss && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Port 80 is the one inside the container.

## 6. Nothing is public

There is no Caddy here, no certificate and no firewall rule, and none of the three is
missing. 8084 is bound to 127.0.0.1, so only a program already running on this computer
can open a connection to it. No domain means nothing to certify, and no other device
reaches this, not the user's phone, not a laptop on the same wifi. That is the shape of
this path, not a defect in it.

Browsers treat http://localhost as a secure context, so page features that need crypto
keep working without TLS. FreshRSS builds links from the address it was asked for, so the
VPS path's `base_url` override has nothing to correct here. Do not set it.

Confirm the binding rather than believing it:

```bash
grep -n '127.0.0.1:8084' ~/selfhost/freshrss/compose.yml
```

Assert: exactly one line, the `ports` entry. A `0.0.0.0:8084` or a bare `8084:80` there
means the file was edited: put the `127.0.0.1:` prefix back before starting anything.

## 7. Start and verify

The web installer is skipped on purpose: until somebody completes it, it answers whoever
reaches it. The command line installer closes it without a browser, and the password comes
from the container's environment, so it never reaches shell history.

```bash
cd ~/selfhost/freshrss
docker compose pull
docker compose up -d
sleep 15
docker compose exec -T --user www-data freshrss cli/do-install.php --default-user admin
docker compose exec -T --user www-data freshrss sh -c 'cli/create-user.php --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"'
ls -l ~/selfhost/freshrss/data/config.php
curl -sSL -o /dev/null -w '%{http_code}\n' http://localhost:8084/
curl -sSL http://localhost:8084/ | grep -c 'FreshRSS'
```

Assert, all three: `ls -l` prints a line for `data/config.php`, the first curl prints
`200`, and the second a number greater than `0`, because `FreshRSS` appears in the served
document. Print what you received for each. If any of the three misses, stop, run
`docker compose logs --tail 30 freshrss`, and say which earlier step is the likely cause.
A permission error on /var/www/FreshRSS/data is step 3. An address-in-use error on 8084 is
another program holding that port: `lsof -i :8084` names it on macOS and Linux,
`netstat -ano | findstr :8084` on Windows. A `database is locked` or `disk I/O error` on
Windows means: check the folder is on the local system drive, then restart Docker Desktop.
If `do-install.php` says the install already exists, that is not an error on a second run:
carry on to `config.php`, the assert with security meaning, because that file stops the
web installer answering.

A running container is not success. Three passing asserts is success.

The first screen at http://localhost:8084 is a login form asking for a username and
password.

STOP: tell the user to open http://localhost:8084, sign in as `admin` with the password
from step 4, and wait. Do not continue until they confirm they are looking at the reader.

Then tell them: cron refreshes twice an hour, and no feed more often than every twenty
minutes, so a feed added now can leave the reader empty for half an hour. The refresh
button proves it works today.

## 8. First backup and restore

Take the backup now, before the user imports a feed. Stop the container first: a SQLite
file copied mid-write is not a backup.

```bash
cd ~/selfhost/freshrss
docker compose stop
case "$(uname -s)" in
  Linux) sudo tar -czf backups/freshrss-$(date +%F).tar.gz data .env ;;
  *)     tar -czf backups/freshrss-$(date +%F).tar.gz data .env ;;
esac
docker compose start
ls -lh backups/
```

Assert: the archive exists and is non-empty. Print its size, a few hundred kilobytes on a
fresh install. Downtime is a few seconds, and `data` plus `.env` is the whole install. On
Linux the files in `data` belong to uid 33, which is why tar runs under sudo.

That archive sits on the same disk as the data it protects, so it is not a backup yet: on
a laptop the disk and the machine fail together. STOP: tell the user to name a
destination that leaves this computer, a folder their sync service watches or a USB stick,
and wait. Do not continue until they answer. Then copy the archive there with `cp` and
list it.

To restore: `cd ~/selfhost/freshrss`, `docker compose down`, delete the `data` folder,
extract the archive back into ~/selfhost/freshrss, then `docker compose up -d`. On Linux
the delete and the extract need sudo, same ownership reason. The reader itself is a SQLite
file under `data/users/admin/`. Those five commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/FreshRSS/FreshRSS/releases. Take a backup
with the step 8 commands first, then edit the `image:` line in
~/selfhost/freshrss/compose.yml to the new tag and digest from Docker Hub.

```bash
cd ~/selfhost/freshrss
docker compose pull
docker compose up -d
docker compose logs --tail 20 freshrss
```

FreshRSS migrates its own schema on the first request after an upgrade, so load
http://localhost:8084 once and read the log before calling the update done. If the log
shows a container restarting in a loop, put the old tag and digest back and pull again.

## 10. What will probably go wrong

Docker Desktop, after a reboot. I restarted the machine partway through testing, opened
http://localhost:8084 out of habit, and got a browser error page. Nothing was
broken: `restart: unless-stopped` means something only once the Docker engine is running,
and on macOS and Windows that engine is an app a person has to launch. Every
refresh since the reboot had been missed, and nothing said so: a reader with no new
articles looks identical to one with nothing to report. If the page does not load, look at
the whale icon before reading a log line, and tell the user that Docker Desktop's
start-at-login setting stops this happening again.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not switch the database to PostgreSQL or MySQL. SQLite is why this is one container
  with one folder to copy.
- Do not install FreshRSS extensions. Only `data/` is mounted, so one installed now
  disappears at the next image bump.
- Do not enable the Google Reader or Fever API. Each is a credential per app, and no phone
  reaches this machine anyway.
