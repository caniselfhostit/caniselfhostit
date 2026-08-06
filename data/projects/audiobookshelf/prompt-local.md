You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Audiobookshelf 2.36.0 under ~/selfhost/audiobookshelf, answering at
http://localhost:8125.

## 1. Preflight

Say both of these to the user before step 2 runs; they decide whether they want this install at
all. Audiobookshelf plays audio files already on this computer: no store, no credit, nothing
they have not copied in themselves, and the `.aax` and `.aaxc` files Audible's own apps download
are locked to Audible and will not play here. And it answers only at http://localhost:8125, so
the phone in their pocket cannot reach it and the Audiobookshelf apps that make a listening
server worth having stay unused. The browser here is the whole player.

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
distribution ID and codename print next, for step 2. Audiobookshelf needs 1024 MB of RAM
available and 5 GB free on the home disk before any audio, and the image publishes amd64 and
arm64. Every branch prints free memory, so one floor covers all three; on macOS and Windows that
is the host's, and Docker Desktop takes its share out of it. If available RAM is under 1024 MB or
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
mkdir -p ~/selfhost/audiobookshelf/config ~/selfhost/audiobookshelf/metadata ~/selfhost/audiobookshelf/backups ~/selfhost/audiobookshelf/audiobooks ~/selfhost/audiobookshelf/podcasts
ls -la ~/selfhost/audiobookshelf
```

Assert: `ls -la` shows five folders. No ownership fix runs on any of the three systems: upstream
states that Audiobookshelf does not read PUID or PGID, so the container runs as root and writes
into a folder whoever owns it.

Now the library. This prompt copies audio in rather than pointing at the folder it lives in: a
relative path inside ~/selfhost/audiobookshelf behaves the same on all three systems. That is a second copy on the same disk, so size it first, with the user's own path in
place of ~/Audiobooks:

```bash
du -sh ~/Audiobooks
```

STOP: tell the user that size and the free space step 1 printed, and if it fits, tell them to
copy the library in with the command below and wait. Do not continue until they confirm. One
book is enough to go on. Upstream expects one folder per book, `{Author}/{Book}` or
`{Author}/{Series}/{Book}`.

```bash
rsync -a --info=progress2 ~/Audiobooks/ ~/selfhost/audiobookshelf/audiobooks/
```

Assert: `ls ~/selfhost/audiobookshelf/audiobooks` is not empty.

## 4. Secrets

No secret is generated for this install, and there is no `.env` file. Upstream generates the key
that signs sessions on first start and stores it in the database under `config/`, so there is
nothing for `openssl` to make and step 8's backup already carries it.

The only credential this install has is the root account, created in a browser in step 7. Tell
the user that a password still matters on a machine other people use.

## 5. compose.yml

```bash
cat > ~/selfhost/audiobookshelf/compose.yml <<'EOF'
# Audiobookshelf · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ...... https://www.audiobookshelf.org/docs/documentation/install/docker
#   configuration ....... https://www.audiobookshelf.org/docs/documentation/install/configuration
#   backups ............. https://www.audiobookshelf.org/docs/documentation/server-management/backups
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/audiobookshelf/, so one file works on macOS, Linux and Windows and
# you can open config/, audiobooks/ and backups/ in Finder or Explorer. No
# named volume is needed: upstream states that Audiobookshelf does not read
# PUID or PGID, the container runs as root, and nothing chowns its own data
# directory. The image already sets PORT=80, CONFIG_PATH=/config and
# METADATA_PATH=/metadata. The library is read-only: no media file is ever
# written. Digest read from ghcr.io on 2026-08-06; amd64 and arm64 published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:2.36.0@sha256:180acad33d69c99ed208676465d8edcb268fa46967735579a7810859885b1a8e
    container_name: audiobookshelf
    restart: unless-stopped
    environment:
      TZ: UTC
      # Backups belong in a folder you can see, not inside the metadata cache.
      # The scheduler that fills it stays off until turned on in the web UI.
      BACKUP_PATH: /backups
    volumes:
      - ./config:/config
      - ./metadata:/metadata
      - ./backups:/backups
      # Read-only: nothing here writes to the library, and the mount keeps a
      # mis-click in the UI from writing to it either.
      - ./audiobooks:/audiobooks:ro
      # Read-write, because podcast episodes are downloaded into this folder.
      - ./podcasts:/podcasts
    ports:
      # Loopback only: no other device on the wifi can reach 8125.
      - "127.0.0.1:8125:80"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd ~/selfhost/audiobookshelf && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, five folders you can open.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the login page works without one.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8125 is bound to 127.0.0.1, this computer only. For a listening server that is the sharp edge of
this path: the phone, the car and the tablet cannot reach it. That is the trade, not a fault.
Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/audiobookshelf/compose.yml
```

Assert: two lines, the health check inside the container and `- "127.0.0.1:8125:80"`.

## 7. Start and verify

```bash
cd ~/selfhost/audiobookshelf
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8125/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8125/status | grep -o '"isInit":[a-z]*'
```

Assert both, printing what you received for each: the loop ends on `200`, and the status line
prints `"isInit":false`, upstream's way of saying no root user exists yet. If the loop never
reaches 200, stop, run `docker compose logs --tail 40 audiobookshelf`, and name the likely
cause: a container that exits at once usually cannot write `config/`. If `port is already
allocated` came back, find what holds 8125 (`lsof -nP -iTCP:8125 -sTCP:LISTEN`, or
`netstat -ano | findstr :8125` on Windows) and stop until it is free. A running container is not
success.

STOP: tell the user to open http://localhost:8125 and create their account, and wait. Do not
continue until they confirm. The first screen reads `Initial Server Setup` above `Create Root
User`, with Username, Password and Confirm Password boxes and the config and metadata paths below
them. Tell them to set a real password: the form will accept an empty one behind a
confirmation dialog.

Then tell them the last step is theirs: Audiobookshelf scans no folder it was not told about.
In the web UI, `Libraries`, `Add Library`, media type `Books`, folder `/audiobooks`. Then read
both results:

```bash
curl -sS http://localhost:8125/status | grep -o '"isInit":[a-z]*'
sleep 30
docker compose logs audiobookshelf | grep -F 'Library scan' | tail -2
```

Assert both, and print both. `"isInit":true` is the setup screen closed for good, the security
check here rather than a formality. The scanner line contains `Library scan` and
`completed in`, and ends in `N Added | 0 Updated | 0 Missing`, with N greater than 0. `0 Added` means those
files are not laid out as one folder per book. A lone `Starting` line means the scan is still
running, so wait and run it again.

## 8. First backup and restore

One archive: the database and the compose file. The audio is deliberately not in it: it is a
copy of a library the user already had, and it belongs in whatever backup already protects this
computer. Upstream's backup page says the same of its own.

```bash
cd ~/selfhost/audiobookshelf
docker compose stop
tar -C ~/selfhost/audiobookshelf -czf ~/selfhost/audiobookshelf/backups/audiobookshelf-config-$(date +%F).tar.gz config compose.yml
docker compose start
ls -lh ~/selfhost/audiobookshelf/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container stops for about five
seconds on purpose: a SQLite database copied mid-write is not a backup.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder a sync service
watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is `/d/Backups`,
not `D:\Backups`. Assert: the user confirms the filename is listed there. If they have nowhere,
say plainly that this install has no backup.

To restore: `cd ~/selfhost/audiobookshelf`, `docker compose down`, `rm -rf config`, untar the
archive back in, then `docker compose up -d`. The accounts, the libraries and every listening
position live in `config/absdatabase.sqlite`. That file is the whole product: the audio can be
copied again; the place they stopped in each book cannot.

One more thing the software will not say: the built-in scheduled backup is off until the user
turns it on, in `Settings`, then `Backups`. Compose has already pointed it at
~/selfhost/audiobookshelf/backups.

## 9. Updating later

New versions are listed at https://github.com/advplyr/audiobookshelf/releases. Back up first,
then edit the image line in ~/selfhost/audiobookshelf/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/audiobookshelf
docker compose pull
docker compose up -d
docker compose logs --tail 30 audiobookshelf
```

Audiobookshelf migrates its own database on the way up. Watch that log until it settles, then
re-run step 7's checks.

## 10. What will probably go wrong

I closed the lid halfway through the first scan. When I came back the library showed four books out
of ninety, and nothing in the interface said the scan had been interrupted rather than
finished. Docker Desktop had suspended with the machine, which is what a laptop does and a
server does not. Leave the computer awake until the scanner line from step 7 prints
`completed in`, and if the count looks short, run the scan again from `Libraries` rather than
concluding the mount is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8125 to 0.0.0.0 so a phone on the same wifi can reach it. That puts a server with a
  login form on every network this computer joins.
- Do not mount the audiobooks folder read-write to make the upload button work. Uploading and
  embedding metadata both write into the library, which this install keeps read-only on purpose.
- Do not set `JWT_SECRET_KEY` and do not configure OIDC single sign-on. Upstream generates the
  session key itself, and one root account is enough for one computer.
