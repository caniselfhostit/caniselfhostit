You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Uptime Kuma 2.5.0 on this computer, reachable at http://localhost:8091 from this
computer and nowhere else, with everything it keeps under ~/selfhost/uptime-kuma/.

## 1. Preflight

Find out which operating system this is first. Steps 2, 3 and 8 branch on it.

```bash
uname -s
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize | awk '{printf "%d MB of RAM installed\n", $1/1048576}' ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, and `MINGW` or `MSYS` is Windows under Git Bash.

Uptime Kuma needs 512 MB of RAM and 5 GB free on the home disk. The 2.5.0 image covers amd64
and arm64, so Apple Silicon and Intel are both fine.

Free disk under 5 GB is a stop on any OS. For RAM, only the Linux line measures the floor:
under 512 MB available, print both numbers and stop. macOS and Windows print installed RAM
instead (bytes on Windows, divide by 1048576), which any machine running Docker Desktop clears;
there the 512 MB applies to Docker Desktop's own allocation, so have the user check Settings,
Resources and stop if it shows less. Do not install and hope.

Say this to the user before installing anything, with nothing left out. A monitor on a machine
that sleeps is a monitor that sleeps: when the lid closes the checks stop and nothing is
watching until it wakes. This computer also cannot alert them that it is itself off: a monitor
that is down produces the same silence as one with nothing to report. If they want checks that
keep running overnight, this belongs on a machine that stays on, with one free external check
pointed at it. That is not a reason to stop, it is what they are choosing.

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
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they confirm.
  Either way, then STOP: tell the user to open Docker Desktop once, accept its terms, and wait
  for the whale icon to say it is running. Do not continue until they confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and install
  it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may ask for a
  reboot; if it does, STOP and tell the user to reboot and come back, this prompt resumes at
  this step. Then STOP: have the user open Docker Desktop, accept its terms, and confirm it
  says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt repository,
  with its signing key saved to a file first, never piped into a shell:

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
  sudo usermod -aG docker $USER
fi
```

  Say one sentence to the user: membership of the `docker` group is root-equivalent on this
  machine, and the group change lands at their next login, so they may need to log out first.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose plugin
  with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not continue
without both.

## 3. Layout

Everything lives in one directory under the home directory. `db-config.json` is written before
the first boot because it picks the database: with that file present Uptime Kuma uses SQLite
and skips its database setup screen.

```bash
mkdir -p ~/selfhost/uptime-kuma/data ~/selfhost/uptime-kuma/backups
printf '{\n    "type": "sqlite"\n}\n' > ~/selfhost/uptime-kuma/data/db-config.json
ls -la ~/selfhost/uptime-kuma/data
```

On Linux only, `./data` is a real directory on the real filesystem and the image runs as uid
1000, so hand it over:

```bash
sudo chown -R 1000:1000 ~/selfhost/uptime-kuma/data
```

Do not run that on macOS or Windows. Docker Desktop runs the engine in a virtual machine and
rewrites ownership across its file share, so the container already sees itself as the owner and
a host `chown` changes nothing it can observe.

Assert: `ls -la` lists `db-config.json`, and on Linux it belongs to `1000` after the chown.
Keep this directory on the local disk and out of any folder a sync service watches: SQLite
needs real POSIX file locks, and a synced or networked folder corrupts it quietly, weeks
later. Backups are the exception, and step 8 uses one.

## 4. Secrets

Nothing is generated here and there is no `.env` file. Uptime Kuma's only credential is the
administrator account, and the user creates it in a browser at step 7, so this block runs no
commands.

Say two things to the user. First: between the container starting and that account existing,
the setup form is open to anyone with a session on this computer, which is why step 7 makes
that window short and stops there. Second, on Windows: mode bits on NTFS are advisory, so no
`chmod` protects anything here; their own account is the real boundary on a single-user
machine, and everything this install writes sits in their home directory.

## 5. compose.yml

```bash
cat > ~/selfhost/uptime-kuma/compose.yml <<'EOF'
# Uptime Kuma · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   compose shape ...... https://github.com/louislam/uptime-kuma/blob/master/compose.yaml
#   install notes ...... https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install
#   image details ...... https://github.com/louislam/uptime-kuma/blob/master/docker/dockerfile
#
# One container, on the computer the user is sitting at. No Caddy and no
# certificate: nothing outside this machine can reach 8091, so there is nothing
# to certify. This file sits in ~/selfhost/uptime-kuma/ and its paths are
# relative to it, which is what lets one file work on macOS, Linux and Windows.
# Upstream pins the floating `2` tag and publishes 3001 on every interface; this
# file pins the release and binds to loopback. The image runs as the node user
# (uid 1000), hence the Linux-only chown in step 3. Tag and digest are the 2.5.0
# release read from Docker Hub on 2026-08-05, for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  uptime-kuma:
    image: louislam/uptime-kuma:2.5.0@sha256:a8610b3b4c38077922ba51b036691e06887d7cefd91fe620fd3d6d23d03dc240
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      # kuma.db and db-config.json live here. Local disk only: SQLite needs real
      # POSIX file locks, so a network mount or a synced folder corrupts it.
      - ./data:/app/data
    ports:
      # Loopback only. No other device on this network can reach 8091, not even
      # the user's phone.
      - "127.0.0.1:8091:3001"
EOF
cd ~/selfhost/uptime-kuma && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves 3001 inside itself; 8091 is the host
port bound to 127.0.0.1, the same one the server path uses.

## 6. Nothing is public

Nothing here is reachable from outside this computer, and no step in this prompt changes that.

- The published port is `127.0.0.1:8091`, which means this machine only. Another laptop on the
  same wifi cannot reach it, and neither can the user's phone. That is this path, not a defect
  in it.
- No domain, no DNS record to wait for, no certificate to issue, no firewall rule to add: there
  is no hostname to certify and nothing listening on an address another machine could route to.
  The server path's DNS wait, TLS step and ufw block all fall away.
- Browsers treat `http://localhost` as a secure context, so the dashboard works over plain HTTP
  without the warnings a real hostname would earn.
- This install sets no base URL and the compose file carries no hostname. If the user later
  fills a base-URL field, http://localhost:8091 is the only value that resolves here, and links
  built from it are dead on every other device.
- The checks go out from this computer, over whatever network it is on. A site that is up for
  everyone else but blocked on this cafe wifi is recorded as down: a true answer to a narrower
  question than a rented server answers.

## 7. Start and verify

The image carries a health check with a three-minute start period, so the first boot takes
longer than it looks like it should. That is not a failure yet.

```bash
cd ~/selfhost/uptime-kuma
docker compose pull
docker compose up -d
sleep 60
docker inspect --format '{{.State.Health.Status}}' uptime-kuma
curl -sS http://localhost:8091/setup-database-info
echo
curl -sSL http://localhost:8091/ | grep -ci 'uptime kuma'
```

Assert, all three: `docker inspect` prints `healthy`, the JSON line contains `"needSetup":false`
because step 3 chose SQLite, and the last command prints a number greater than `0`.
Print what you received for each. If health is `starting`, wait 60 seconds and check again. If
anything still misses, stop, run `docker compose logs --tail 40 uptime-kuma`, and name the
earlier step that likely caused it. A running container is not success.

The first screen at http://localhost:8091 is a form asking for a username and password to
create the administrator account. Until it is submitted, anyone at this computer can submit it.

STOP: tell the user to open http://localhost:8091 now, create the administrator account, and
save the password in their password manager. Wait until they confirm.

Then have them prove it closed: ask them to open http://localhost:8091 in a private window and
confirm a sign-in form with no create-account fields. Assert: they confirm that in words. Do
not report success on the container being up.

## 8. First backup and restore

Take the backup now, before the user adds a monitor. Stop the container first: a SQLite file
copied mid-write is not a backup.

```bash
cd ~/selfhost/uptime-kuma
docker compose stop
tar -czf backups/uptime-kuma-$(date +%F).tar.gz data
docker compose start
ls -lh backups/
```

Assert: `ls -lh` shows the archive non-empty, and `tar -tzf` on it lists `data/kuma.db`. Print
its size. On Linux, if `tar` prints `Cannot open: Permission denied`, the login user is not uid
1000 and step 3 handed `data` to 1000: rerun the line with `sudo` and tell the user the archive
belongs to root.

`data` is the whole install: no `.env` here, and `data/kuma.db` holds the monitors, the
administrator account and every heartbeat ever recorded.

A backup on the same disk as the data is not a backup, and on one computer the disk and the
machine fail together. Get a copy off this machine now, and ask first: which folder does a sync
service already watch, iCloud Drive, OneDrive, Dropbox, Syncthing? If they sync nothing, have
them plug in a USB stick, under /Volumes on macOS, usually /media on Linux, a drive letter such
as /d in Git Bash. Confirm the answer with `ls -d` on it, then `cp` the archive there and print
the result. Do not guess a path: `~/Dropbox` is absent on most machines and the copy fails.

To restore, run `ls -lh backups/`, have the user name the archive, and put that exact filename
in both `ARCHIVE` slots. Nothing is deleted until `tar -tzf` has read the archive through, so a
wrong name costs a message, not the install:

```bash
cd ~/selfhost/uptime-kuma
tar -tzf backups/ARCHIVE >/dev/null && docker compose down && rm -rf data && tar -xzf backups/ARCHIVE && docker compose up -d
```

That one line is the whole disaster plan. On Linux, if step 3's chown ran against a login user
that is not uid 1000, the `rm -rf` and the `tar` need `sudo` too. Tell the user that heartbeat
history is kept forever by default, so this archive grows with the monitor count times the
check interval; the retention setting is the lever if the disk fills.

## 9. Updating later

New versions are listed at https://github.com/louislam/uptime-kuma/releases. Take a backup
first, then edit the image line in ~/selfhost/uptime-kuma/compose.yml to the new tag and
digest. Uptime Kuma migrates its own database on the next boot, so wait for the health check to
go green before calling this done.

```bash
cd ~/selfhost/uptime-kuma
docker compose pull
docker compose up -d
docker compose logs --tail 20 uptime-kuma
```

## 10. What will probably go wrong

Docker Desktop, after a reboot. The compose file says `restart: unless-stopped`, and I read
that as a promise the container comes back on its own. It does not on macOS or Windows: nothing
comes back until Docker Desktop itself is running, and it starts at sign-in, sometimes only
when the user opens it. I rebooted, went to lunch, and came back to a dashboard missing two
hours with no error anywhere in it, because a monitor that was not running produces the same
silence as one with nothing to report. Tell the user to turn on Docker Desktop's
start-at-login setting, and to read any flat gap in the graphs as this until ruled out.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure MariaDB. `db-config.json` picks SQLite, which is why this is one container.
- Do not configure notification channels. Each one is an account or a credential somewhere
  else, and the user picks those in the interface afterwards.
- Do not rebind 8091 to this machine's network address so a phone can reach the dashboard. That
  puts a sign-in page on every network this computer joins, in exchange for a glance.
