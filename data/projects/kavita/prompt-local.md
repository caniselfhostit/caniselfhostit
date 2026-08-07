You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Kavita 0.9.0.2 under ~/selfhost/kavita, answering at http://localhost:8146.

## 1. Preflight

Say both of these to the user before step 2 runs; they decide whether they want this install at
all. Kavita serves reading files that are already on this computer: epub, pdf, cbz and
cbr they copy in themselves. There is no catalog and no unlock, and books bought inside a store
that wraps them in DRM, the Kindle and Kobo purchases most people have the most of, stay locked
to that store's own apps and will not open here. And it answers only at http://localhost:8146, so
the phone and the tablet cannot reach it and the OPDS reader apps that are the best part of a
reading server stay unused. The browser on this computer is the whole reader.

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
distribution ID and codename print next, for step 2. Kavita needs 1024 MB of RAM available and
5 GB free on the home disk before any books, and the image publishes amd64 and arm64. Every
branch prints free memory, so one floor covers all three; on macOS and Windows that is the
host's, and Docker Desktop takes its share out of it. If available RAM is under 1024 MB or free
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
mkdir -p ~/selfhost/kavita/config ~/selfhost/kavita/books ~/selfhost/kavita/backups
ls -la ~/selfhost/kavita
```

Assert: `ls -la` shows three folders. No ownership fix runs on any of the three systems: upstream
took the PUID and PGID handling out of its container entrypoint, so Kavita runs as root and
writes into a folder whoever owns it.

Now the library. This prompt copies books in rather than pointing at the folder they live in: a
relative path inside ~/selfhost/kavita behaves the same on all three systems. That is a second
copy on the same disk, so size it first, with the user's own path in place of ~/Books:

```bash
du -sh ~/Books
```

STOP: tell the user that size and the free space step 1 printed, and if it fits, tell them to
copy the library in with the command below and wait. Do not continue until they confirm. One
series is enough to go on. Upstream requires one folder per series and no files loose at the top
of the library:

```bash
rsync -a --info=progress2 ~/Books/ ~/selfhost/kavita/books/
```

Assert: `ls ~/selfhost/kavita/books` is not empty.

## 4. Secrets

No secret is generated for this install, and there is no `.env` file. On first start Kavita draws
256 random bytes for the key that signs user sessions and writes it into `config/appsettings.json`
itself, so there is nothing for `openssl` to make and step 8's backup already carries it.

The only credential this install has is the admin account, created in a browser in step 7. Tell
the user that a real password still matters on a computer other people use, and that until the
account exists Kavita answers with its `Register` form.

## 5. compose.yml

```bash
cat > ~/selfhost/kavita/compose.yml <<'EOF'
# Kavita · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ...... https://wiki.kavitareader.com/installation/docker/
#   dockerhub image ..... https://wiki.kavitareader.com/installation/docker/dockerhub/
#   server settings ..... https://wiki.kavitareader.com/guides/admin-settings/general/
#   libraries ........... https://wiki.kavitareader.com/guides/admin-settings/libraries/
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/kavita/, so one file works on macOS, Linux and Windows and you can
# open config/ and books/ in Finder or Explorer. No named volume is needed: the
# container runs as root, because upstream took the PUID and PGID handling out
# of its entrypoint, and nothing here chowns its own data directory. The image
# already exposes 5000 and carries its own HEALTHCHECK against /api/health.
# /kavita/config is the one mount path upstream marks as unchangeable. The
# library is mounted read-only: Kavita reads filenames and in-file metadata and
# writes nothing back into it. Tag and digest read from Docker Hub on
# 2026-08-06; the image publishes linux/amd64, linux/arm64 and linux/arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  kavita:
    image: jvmilazz0/kavita:0.9.0.2@sha256:ca6af7a18d7124d014702983c2364e485294f808c1552e9555f2595b7cda7982
    container_name: kavita
    restart: unless-stopped
    environment:
      # The nightly library scan and the database backup task both run at
      # midnight in this zone, so it is the one setting worth being deliberate
      # about before the first scan.
      TZ: UTC
    volumes:
      - ./config:/kavita/config
      # Read-only: nothing here writes to the library, and the mount keeps a
      # mis-click in the web UI from writing to it either.
      - ./books:/books:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8146.
      - "127.0.0.1:8146:5000"
EOF
cd ~/selfhost/kavita && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, three folders you can open.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the login page works without one.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8146 is bound to 127.0.0.1, this computer only. For a reading server that is the sharp edge of
this path: the phone and the e-reader cannot reach it, and neither can the OPDS apps that would
otherwise sync your place. That is the trade, not a fault. Confirm it:

```bash
grep -n '"127.0.0.1:' ~/selfhost/kavita/compose.yml
```

Assert: exactly one line, `- "127.0.0.1:8146:5000"`. Nothing else in this install publishes a
port.

## 7. Start and verify

```bash
cd ~/selfhost/kavita
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8146/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8146/api/health
curl -sS http://localhost:8146/api/admin/exists
```

Assert all three, printing what you received for each: the loop ends on `200`, the health
endpoint prints `Ok`, and the admin check prints `false`, upstream's way of saying no
administrator exists yet. If the loop never reaches 200, stop, run
`docker compose logs --tail 40 kavita`, and name the likely cause: a container that exits at once
usually cannot write `config/`. If `port is already allocated` came back, find what holds 8146
(`lsof -nP -iTCP:8146 -sTCP:LISTEN`, or `netstat -ano | findstr :8146` on Windows) and stop until
it is free. A running container is not success.

STOP: tell the user to open http://localhost:8146 and create their account, and wait.
Do not continue until they confirm. The first screen reads `Register` above the line
`Complete the form to register an admin account`, with Username, Email and Password boxes.
Upstream documents that the email does not have to be a real address, it is only how a forgotten
password is recovered and it is never sent anywhere, and that the password has to be at least 6
characters.

Then tell them the last step is theirs: Kavita scans no folder it was not told about. In the web
UI, `Libraries`, `Add Library`, type `Book`, then pick `/books` in the folder picker. Then read
both results:

```bash
curl -sS http://localhost:8146/api/admin/exists
sleep 45
docker compose logs kavita | grep -F '[ScannerService] Found' | tail -1
```

Assert both, and print both. `true` is the registration form closed for good, the security check
here rather than a formality. The scanner line contains `Found N Series that need processing`,
with N greater than 0. `Found 0 Series` means the files went in loose rather than one folder per
series. No line at all means the scan is still running, so wait and run it again.

## 8. First backup and restore

One archive: the database, the settings file holding the session key, and the compose file. The
books are deliberately not in it: they are a copy of a library the user already had, and they
belong in whatever backup already protects this computer. The cache and temp folders are skipped
because Kavita rebuilds both.

```bash
cd ~/selfhost/kavita
docker compose stop
tar --exclude='config/cache' --exclude='config/cache-long' --exclude='config/temp' -C ~/selfhost/kavita -czf ~/selfhost/kavita/backups/kavita-config-$(date +%F).tar.gz config compose.yml
docker compose start
ls -lh ~/selfhost/kavita/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container stops for about five
seconds on purpose: a SQLite database copied mid-write is not a backup.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder a sync service
watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is `/d/Backups`,
not `D:\Backups`. Assert: the user confirms the filename is listed there. If they have nowhere,
say plainly that this install has no backup.

To restore: `cd ~/selfhost/kavita`, `docker compose down`, `rm -rf config`, untar the archive back
in, then `docker compose up -d`. The accounts, the libraries, every bookmark and every page
position live in `config/kavita.db`, and the key that signs sessions is in
`config/appsettings.json` beside it. Those two files are the whole product: the books can be
copied again; the page they stopped on cannot.

## 9. Updating later

New versions are listed at https://github.com/Kareadita/Kavita/releases. Back up first, then edit
the image line in ~/selfhost/kavita/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/kavita
docker compose pull
docker compose up -d
docker compose logs --tail 30 kavita
```

Kavita migrates its own database on the way up. Watch that log until it settles, then re-run the
two checks from step 7.

## 10. What will probably go wrong

I closed the lid partway through the first scan. When I came back the library showed eleven books
out of two hundred, and nothing in the interface said the scan had been interrupted rather than
finished. Docker Desktop had suspended with the machine, which is what a laptop does and a server
does not. Leave the computer awake until step 7's scanner line prints, and if the count looks
short, rescan from `Libraries` rather than concluding the mount is wrong. Docker Desktop stopping
with the machine is also why a reboot looks like a lost library until you start it again.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8146 to 0.0.0.0 so a tablet on the same wifi can reach it. That puts a server
  with a login form on every network this computer joins.
- Do not enter a Kavita+ licence key and do not configure OpenID Connect. Kavita+ is a paid
  upstream subscription, and one admin account is enough for one computer.
- Do not change `Base URL` or `Port` in `Admin`, `General`. The compose file sets both, and
  changing them in the UI leaves the container listening where nothing is looking.
