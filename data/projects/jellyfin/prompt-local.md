You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Jellyfin 10.10.7 under ~/selfhost/jellyfin, answering at http://localhost:8204.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Jellyfin streams files they already own. There is no catalogue and nothing appears that
they did not put on disk. This path answers only at http://localhost:8204, so a phone on the
same wifi and a friend on another network get nothing. What they get is a player and a library
on this desk, which is the home-box shape without the remote front door.

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
distribution ID and codename print next, for step 2. Jellyfin needs 2048 MB of RAM available
and 20 GB free on the home disk before a large library, and the image publishes amd64 and
arm64. Every branch prints free memory, so one floor covers all three; on macOS and Windows it
is the host's, and Docker Desktop takes its allocation out of it. If available RAM is under
2048 MB or free disk is under 20 GB, print both numbers and stop. Do not install and hope.

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

Config and cache live under ~/selfhost/jellyfin. Media is a folder the user already has,
mounted read only, not an empty tree this install invents.

```bash
mkdir -p ~/selfhost/jellyfin/config ~/selfhost/jellyfin/cache ~/selfhost/jellyfin/backups
ls -la ~/selfhost/jellyfin
```

STOP: ask the user for the absolute path to a media library on this computer (for example
`$HOME/Videos` or `$HOME/Movies`). Do not continue until they confirm. If they have no library
yet, they may give `$HOME/selfhost/jellyfin/media` and you create that empty directory.

```bash
# Create only if they chose the empty staging path:
# mkdir -p ~/selfhost/jellyfin/media
test -d "<MEDIA_PATH>" && ls -ld "<MEDIA_PATH>"
umask 077
printf 'JELLYFIN_MEDIA_PATH=%s\n' '<MEDIA_PATH>' > ~/selfhost/jellyfin/.env
chmod 600 ~/selfhost/jellyfin/.env
umask 022
cat ~/selfhost/jellyfin/.env
```

Replace `<MEDIA_PATH>` with the path they gave (expand `$HOME` yourself so `.env` holds a real
absolute path Docker can bind). Assert: the directory exists and `.env` prints one
`JELLYFIN_MEDIA_PATH=` line. On Windows under Git Bash, write a path Docker Desktop can see,
for example `/c/Users/them/Videos`, not `C:\Users\...`.

## 4. Secrets

No secret is generated for this install. The first credential is the administrator account the
user creates in the setup wizard in step 7. On localhost the claim-race is limited to other
software on this machine that can open http://localhost:8204, which is still enough reason to
finish the wizard in the same session.

## 5. compose.yml

```bash
cat > ~/selfhost/jellyfin/compose.yml <<'EOF'
# Jellyfin · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   container install ... https://jellyfin.org/docs/general/installation/container
#   setup wizard ........ https://jellyfin.org/docs/general/post-install/setup-wizard/
#   backup .............. https://jellyfin.org/docs/general/administration/backup-and-restore
#
# One container on the computer you are sitting at. Paths are relative to
# ~/selfhost/jellyfin/. Media is a bind of a folder the user already has, via
# JELLYFIN_MEDIA_PATH in .env. This file never downloads content. Tag and digest
# are the 10.10.7 release read from Docker Hub on 2026-08-07; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  jellyfin:
    image: jellyfin/jellyfin:10.10.7@sha256:7ae36aab93ef9b6aaff02b37f8bb23df84bb2d7a3f6054ec8fc466072a648ce2
    container_name: jellyfin
    restart: unless-stopped
    volumes:
      - ./config:/config
      - ./cache:/cache
      # User library path from .env. Read only.
      - ${JELLYFIN_MEDIA_PATH}:/media:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8204.
      - "127.0.0.1:8204:8096"
EOF
cd ~/selfhost/jellyfin && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one loopback port.

## 6. Firewall

Nothing to open. This install binds only to loopback. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/jellyfin/compose.yml
```

Assert: that prints `1`. Do not rebind to `0.0.0.0`. A media server on every network this
laptop joins is not what the local path is for.

## 7. Start and verify

```bash
cd ~/selfhost/jellyfin
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8204/System/Info/Public); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8204/System/Info/Public
curl -sS http://localhost:8204/System/Info/Public | grep -o '"StartupWizardCompleted":[^,]*'
curl -sSL http://localhost:8204/web/ | grep -ci 'jellyfin'
```

Assert all four, and print what you received for each. The loop ends printing `200`. The public
info is JSON. Before the wizard finishes, `StartupWizardCompleted` is `false`. The web shell
mentions jellyfin. If any miss, stop, run `docker compose logs --tail 40 jellyfin`, and name
the cause: a missing media path is step 3; a port conflict means something else holds 8204.

STOP: tell the user to open http://localhost:8204, complete the setup wizard, create the
administrator account, optionally add a library at `/media`, and confirm they can sign in.
Do not continue until they confirm.

```bash
curl -sS http://localhost:8204/System/Info/Public | grep -o '"StartupWizardCompleted":[^,]*'
```

Assert: `"StartupWizardCompleted":true`. If it is still `false`, the wizard was not finished.

## 8. First backup and restore

One archive: config, cache, compose and the media path pointer. Media files stay outside.

```bash
cd ~/selfhost/jellyfin
docker compose stop
tar -C ~/selfhost/jellyfin -czf ~/selfhost/jellyfin/backups/jellyfin-$(date +%F).tar.gz config cache compose.yml .env
docker compose start
ls -lh ~/selfhost/jellyfin/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds;
the container is stopped so config is not copied mid-write.

That archive sits on the same disk as the data. Ask the user for a destination that leaves this
computer, a folder their sync service watches or a USB stick, and copy it there with `cp`. In
Git Bash a Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms
the filename is listed there.

To restore: `cd ~/selfhost/jellyfin`, `docker compose down`, `rm -rf config cache`, untar the
archive there, then `docker compose up -d`. Tell the user `config/` is accounts and watch
state, `.env` is which host path mounts as `/media`, and the media files themselves are not in
the archive.

## 9. Updating later

New versions are listed at https://github.com/jellyfin/jellyfin/releases. This install pins
10.10.7, the settled end of the 10.10 line, on purpose: the newer 10.11 series migrates the
library database, and a first install is the wrong moment for a one-way migration. Move to
10.11 deliberately, after a backup, once its release notes read as settled to you. Take a
backup first, then edit the image line in ~/selfhost/jellyfin/compose.yml to the new tag and
digest:

```bash
cd ~/selfhost/jellyfin
docker compose pull
docker compose up -d
docker compose logs --tail 30 jellyfin
```

Watch the log until it settles, then re-run step 7's public info check before calling the
update done.

## 10. What will probably go wrong

I closed the laptop mid-transcode and came back to a stalled client and a warm machine. Docker
Desktop and the lid are a pair: when the host sleeps, playback stops, and nothing here pages
you about it. Direct-play of files this computer can decode without a software transcode is the
reliable path. If the library is large, keep it on a disk that stays mounted; a missing bind at
start-up is a container that restarts into the same volume error until you fix `.env`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8204 to 0.0.0.0 so a phone on the wifi can load the library. Use the VPS path
  on this page when remote access is the goal.
- Do not download copyrighted media. This install only mounts a path the user supplies.
