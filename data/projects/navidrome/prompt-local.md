You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Navidrome 0.63.2 under ~/selfhost/navidrome, answering at http://localhost:8108.

## 1. Preflight

Say both of these to the user before step 2 runs; they decide whether they want this install
at all. Navidrome streams audio files already on this computer: no catalog, no store,
nothing in it they have not copied in themselves. And on this path it answers only at
http://localhost:8108, this computer and nothing else, so the phone in their pocket cannot
reach it and the Subsonic apps that make a music server worth having stay unused.

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
distribution ID and codename print next, for step 2. Navidrome needs 512 MB of RAM available
and 5 GB free on the home disk before any music, and the image publishes amd64 and arm64. Every
branch prints free memory, so one floor covers all three; on macOS and Windows that is the
host's, and Docker Desktop takes its share out of it. If available RAM is under 512 MB or free
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
mkdir -p ~/selfhost/navidrome/data ~/selfhost/navidrome/music ~/selfhost/navidrome/backups
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 1000:1000 ~/selfhost/navidrome/data ~/selfhost/navidrome/backups
fi
ls -la ~/selfhost/navidrome
```

Assert: `ls -la` shows `data`, `music` and `backups`. The container runs as uid 1000, not root,
so on Linux those two folders are chowned to match; on macOS and Windows Docker Desktop maps
ownership itself and the fence is a no-op.

Now the library. This prompt copies music in rather than pointing at the folder it lives in,
because a relative path inside ~/selfhost/navidrome behaves the same on all three systems. That
is a second copy on the same disk, so size it first, with the user's own music path in place of
~/Music:

```bash
du -sh ~/Music
```

STOP: tell the user that size and the free space step 1 printed, and if it fits, tell them to
copy the library in with the command below and wait. Do not continue until they confirm. One
album is enough to go on; the rest can follow later.

```bash
rsync -a --info=progress2 ~/Music/ ~/selfhost/navidrome/music/
```

Assert: `ls ~/selfhost/navidrome/music` is not empty.

## 4. Secrets

One secret: the passphrase Navidrome uses to encrypt stored passwords. Generate it here, print
it nowhere, and keep it out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/navidrome/.env <<EOF
ND_PASSWORDENCRYPTIONKEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/navidrome/.env
umask 022
ls -l ~/selfhost/navidrome/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same
on all three. Hex rather than base64 because Docker Compose reads this file for interpolation
too and a `$` in the value would expand. Upstream is explicit that this key is written once:
setting it re-encrypts every stored password, and changing it later locks every account out for
good. Tell the user to read it with `grep ND_PASSWORDENCRYPTIONKEY ~/selfhost/navidrome/.env`
and put it in their password manager. On Windows those mode bits are advisory: NTFS does not
enforce them and the user's own account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/navidrome/compose.yml <<'EOF'
# Navidrome · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ...... https://www.navidrome.org/docs/installation/docker/
#   config options ...... https://www.navidrome.org/docs/usage/configuration/options/
#   security ............ https://www.navidrome.org/docs/usage/admin/security/
#   automated backup .... https://www.navidrome.org/docs/usage/admin/backup/
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/navidrome/, so one file works on macOS, Linux and Windows and you
# can open data/, music/ and backups/ in Finder or Explorer. No named volume is
# needed: nothing here chowns its own data dir, so the uid is pinned below. The
# library is read-only, as upstream asks. Digest read 2026-08-06, amd64+arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  navidrome:
    image: deluan/navidrome:0.63.2@sha256:9012939114fbb1bb641b81cf96dec5ded15f0aafefe8d47a511d7cb919658e40
    container_name: navidrome
    restart: unless-stopped
    # The uid owning ./data and ./backups; step 3 chowns them on Linux.
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp
    env_file: ./.env
    environment:
      ND_MUSICFOLDER: /music
      ND_DATAFOLDER: /data
      ND_PORT: "4533"
      # Refuse to start as root on a Unix host.
      ND_ENFORCENONROOTUSER: "true"
      # Upstream disables this screen: it edits a command line the host runs.
      ND_ENABLETRANSCODINGCONFIG: "false"
      # No anonymous usage reports leave this computer.
      ND_ENABLEINSIGHTSCOLLECTOR: "false"
      # Nightly database snapshot at 04:00, seven kept. No music in it.
      ND_BACKUP_PATH: /backups
      ND_BACKUP_SCHEDULE: "0 4 * * *"
      ND_BACKUP_COUNT: "7"
    volumes:
      - ./data:/data
      - ./backups:/backups
      # Read-only. Nothing Navidrome does needs write access to your library.
      - ./music:/music:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8108.
      - "127.0.0.1:8108:4533"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:4533/ping"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd ~/selfhost/navidrome && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, three folders you can
open.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the login page works without one.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8108 is bound to 127.0.0.1, this computer only. For a music server that is the sharp edge of
this path: the phone, the car stereo and the tablet cannot reach it, and that is the trade,
not a fault. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/navidrome/compose.yml
```

Assert: one line, `- "127.0.0.1:8108:4533"`.

## 7. Start and verify

```bash
cd ~/selfhost/navidrome
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8108/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8108/ping; echo
curl -sS http://localhost:8108/app/ | tr -d '\\' | grep -o '"firstTime":[a-z]*'
```

Assert all three, printing what you received for each: the loop ends on `200`; the health
endpoint answers with a single `.`; the last line prints `"firstTime":true`, meaning no account
exists yet. If the loop never reaches 200, stop, run
`docker compose logs --tail 40 navidrome`, and name the likely cause: a container that exits at
once is usually step 3 on Linux, where `data` ended up owned by somebody other than uid 1000.
If `port is already allocated` came back, find what holds 8108 with
`lsof -nP -iTCP:8108 -sTCP:LISTEN`, or `netstat -ano | findstr :8108` on Windows, and stop
until it is free. A running container is not success.

STOP: tell the user to open http://localhost:8108 and create their account, and wait. Do not
continue until they confirm. The first screen reads `Thanks for installing Navidrome!` above
`To start, create an admin user`, with a `Create Admin` button.

```bash
curl -sS http://localhost:8108/app/ | tr -d '\\' | grep -o '"firstTime":[a-z]*'
docker compose exec -T navidrome sqlite3 /data/navidrome.db "select count(*) from media_file"
```

Assert both, and print both: `"firstTime":false`, the registration screen closed for good, and
a song count greater than 0. If the count is 0 the scan is probably still going: upstream's
timing table puts 10,000 songs at one to five minutes, so wait and count again before changing
anything.

## 8. First backup and restore

One archive: the database, the encryption key and the compose file. The music is deliberately
not in it, because it is a copy of a library the user already had and it belongs in whatever
backup already protects this computer.

```bash
cd ~/selfhost/navidrome
docker compose stop
tar -C ~/selfhost/navidrome -czf ~/selfhost/navidrome/backups/navidrome-config-$(date +%F).tar.gz data .env compose.yml
docker compose start
ls -lh ~/selfhost/navidrome/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container stops on purpose for
about five seconds, because a SQLite database copied mid-write is not a backup. The nightly job
compose configured drops a database-only snapshot in the same folder at 04:00 and keeps seven,
which covers a bad delete, nothing more.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder a sync service
watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is `/d/Backups`,
not `D:\Backups`. Assert: the user confirms the filename is listed there. If they have nowhere,
say plainly that this install has no backup.

To restore: `cd ~/selfhost/navidrome`, `docker compose down`, `rm -rf data`, untar the archive
back in, then `docker compose up -d`. Accounts, play counts, playlists and ratings live in
`data/navidrome.db`; the key that decrypts the passwords is in `.env`, and restoring one
without the other locks everyone out. That is the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/navidrome/navidrome/releases. Back up first, then
edit the image line in ~/selfhost/navidrome/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/navidrome
docker compose pull
docker compose up -d
docker compose logs --tail 30 navidrome
```

Navidrome migrates its own database on the way up. Watch that log until it settles, then re-run
step 7's checks before calling this done.

## 10. What will probably go wrong

I copied in about 8,000 songs, opened http://localhost:8108, saw an empty Albums page, and
spent ten minutes convinced the read-only mount was wrong. It was not. The scan runs in the
background, and mine took longer than upstream's timing table promises because I closed the lid
halfway through and the machine slept, which stops a scan mid-file. Leave the computer awake
until the album count stops climbing, and read `docker compose logs --tail 20 navidrome` before
changing anything.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8108 to 0.0.0.0 so a phone on the same wifi can reach it. That puts an audio
  server with a login page on every network this computer joins.
- Do not set `ND_ENABLETRANSCODINGCONFIG` to true. It opens a UI screen that edits the
  transcoding command line, which is command execution wearing a settings page.
- Do not enable Jukebox mode, and do not configure Last.fm or ListenBrainz credentials. Both
  are things the user can add from the UI later.
