You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Syncthing 2.1.3 under ~/selfhost/syncthing, with its interface at
http://localhost:8139.

## 1. Preflight

Say this before step 2 runs, because it decides whether the user wants this at all. Syncthing is
peer to peer: this computer becomes one device in a group that syncs directly, nothing in the
middle keeping a copy. Two devices exchange changes only while both are awake, so a laptop that
spends the night closed is one whose files reach the phone in the morning.

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
distribution ID and codename print next, for step 2. Syncthing needs 512 MB of RAM available and
5 GB free on the home disk, plus room for the synced files, and publishes amd64 and arm64. Under
either floor, print both and stop.

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
mkdir -p ~/selfhost/syncthing/data/config ~/selfhost/syncthing/data/sync ~/selfhost/syncthing/backups
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 1000:1000 ~/selfhost/syncthing/data
fi
ls -la ~/selfhost/syncthing ~/selfhost/syncthing/data
```

Assert: `ls -la` shows `data` and `backups`, with `config` and `sync` inside `data`. The
container runs as uid 1000, so on Linux `data` is chowned to match; on macOS and Windows Docker
Desktop handles that and the fence is a no-op. `data/config` holds config.xml, the device key
and the database; `data/sync` is what syncs.

## 4. Secrets

One secret: the web GUI password. Generate it here, print it nowhere, keep it out of your
summary and any log. Hex, because it goes through a pipe into a container in step 7.

```bash
umask 077
cat > ~/selfhost/syncthing/.env <<EOF
GUI_USER=admin
GUI_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/syncthing/.env
umask 022
ls -l ~/selfhost/syncthing/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. Tell the user the login is `admin`, the password is in
~/selfhost/syncthing/.env, they read it with `grep -F GUI_PASSWORD ~/selfhost/syncthing/.env`,
and it goes in their password manager now. On Windows those mode bits are advisory: NTFS does
not enforce them, and the boundary is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/syncthing/compose.yml <<'EOF'
# Syncthing · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker image ....... https://github.com/syncthing/syncthing/blob/v2.1.3/README-Docker.md
#   image build ........ https://github.com/syncthing/syncthing/blob/v2.1.3/Dockerfile
#   configuration ...... https://docs.syncthing.net/users/config.html
#
# One service on the computer you are sitting at, with relative paths so that
# one file works on macOS, Linux and Windows and you can open the synced folder
# in Finder or Explorer. Only the GUI port is published, and only on loopback:
# 22000 is not published at all, so nothing dials in and this instance dials
# out instead. No env_file: the only secret is the web GUI password, and step 7
# leaves it in config.xml as a bcrypt hash. Digest read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  syncthing:
    image: syncthing/syncthing:2.1.3@sha256:8c8ff37ab6aa8be23b700648a90fa9412e214852e9fd6ea8477c8334792daec0
    container_name: syncthing
    hostname: syncthing-local
    restart: unless-stopped
    environment:
      # Image defaults; on Linux step 3 chowns ./data to match.
      PUID: "1000"
      PGID: "1000"
      # config.xml, the device certificate and the database all live here.
      STHOMEDIR: /var/syncthing/config
      # Container-internal; published on loopback below. The image also ships
      # a HEALTHCHECK on /rest/noauth/health.
      STGUIADDRESS: 0.0.0.0:8384
    volumes:
      - ./data:/var/syncthing
    ports:
      # Loopback only: no other device on the wifi reaches 8139.
      - "127.0.0.1:8139:8384"
EOF
cd ~/selfhost/syncthing && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. One service, one published port, no database.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. There is no hostname to resolve and no
public name to certify; browsers treat http://localhost as a secure context anyway, so pages
needing crypto still work, and nothing goes beyond loopback for a firewall to close.

8139 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. 22000, the sync protocol port, is not published at all, and
that is the part worth understanding. Nothing dials in here, so Syncthing syncs by dialling out,
directly to a reachable peer and otherwise through the community relay pool upstream runs, which
is why discovery and relaying stay on, unlike on the server. Confirm it:

```bash
grep -c '127.0.0.1:8139:8384' ~/selfhost/syncthing/compose.yml
```

Assert: `1`, and no other published port anywhere in the file.

## 7. Start and verify

Write the configuration before the server listens, so the interface never answers without a
password. It reaches the container over a pipe, out of the process list and the history.

```bash
cd ~/selfhost/syncthing
docker compose pull
grep -F GUI_PASSWORD ~/selfhost/syncthing/.env | cut -d= -f2- | docker compose run --rm -T syncthing generate --gui-user admin --gui-password - --no-port-probing
docker compose run --rm -T --entrypoint /bin/entrypoint.sh syncthing /bin/sh -c 'sed -i -e "s|<crashReportingEnabled>true<|<crashReportingEnabled>false<|" -e "s|<urAccepted>0<|<urAccepted>-1<|" /var/syncthing/config/config.xml && grep -cE ">false</crashReportingEnabled>|<urAccepted>-1<" /var/syncthing/config/config.xml'
```

Assert: that prints `2`, the two reports Syncthing would otherwise send to infrastructure the
user does not run. The edit runs inside the container, as the uid that owns the file, so it
needs no sudo and works the same on all three systems. Under 2, stop.

```bash
cd ~/selfhost/syncthing
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8139/rest/noauth/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8139/rest/noauth/health
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8139/rest/system/status
curl -sS http://localhost:8139/ | grep -o 'Authentication Required'
curl -sSI http://localhost:8139/ | grep -iE 'x-syncthing-(version|id)'
```

Assert all five and print what you received. The loop ends on `200`. The health body contains
`"status": "OK"`. The unauthenticated API call prints `403`, the security assert here: the
interface had a password before its first request. The page contains `Authentication Required`,
the heading over the `User` and `Password` boxes. The last command prints two headers, possibly
lowercased: a Syncthing version that must read `v2.1.3`, proving the pinned image is running,
and a long hyphenated Device ID to keep for the next step. If any miss, stop, run
`docker compose logs --tail 40 syncthing` and name the step: a container that exits at once is
step 3, a config directory the uid cannot write. `port is already allocated` means something
else holds 8139; find it with `lsof -nP -iTCP:8139 -sTCP:LISTEN`.

STOP: tell the user to pair a second device, and wait. Do not continue until they confirm. They
install Syncthing on the other computer or phone from https://syncthing.net/downloads/ and use
`Add Remote Device` there with the Device ID printed above. Then they log in at
http://localhost:8139 as `admin` and accept the `New Device` panel. Both sides add the other
before anything connects.

STOP: tell the user to share the folder, and wait. Do not continue until they confirm. At
http://localhost:8139 they click `Add Folder`, set `Folder Path` to `/var/syncthing/sync`, give
it a label, tick the other device under `Sharing`, and save; on the other device they accept the
`New Folder` panel. Have them drop a file called `selfhost-check.txt` into
~/selfhost/syncthing/data/sync.

Once both sides read `Up to Date`:

```bash
ls -la ~/selfhost/syncthing/data/sync
docker compose exec -T syncthing grep -c 'type="sendreceive"' /var/syncthing/config/config.xml
```

Assert: the listing shows `selfhost-check.txt` and a `.stfolder` marker directory, and the grep
prints at least `1`. The marker is how Syncthing tells an empty folder from an unmounted disk.
A running container is not success; these two are. A missing `.stfolder` means the folder was
never added, so go back to the second STOP.

## 8. First backup and restore

One archive: the device identity, the configuration and the database. It is small: the synced
files are on the other device already.

```bash
cd ~/selfhost/syncthing
docker compose stop
tar -C ~/selfhost/syncthing -czf ~/selfhost/syncthing/backups/syncthing-$(date +%F).tar.gz data/config compose.yml .env
docker compose start
ls -lh ~/selfhost/syncthing/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds, and
the container is stopped on purpose, because the database is SQLite and a file copied mid-write
is not a backup. The irreplaceable thing inside is `data/config/key.pem`, this machine's Device
ID; restoring it lets paired devices reconnect without a new one.

That archive is on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a
Windows drive is `/d/Backups`, not `D:\Backups`. Assert: the user confirms the file is there.
If they have nowhere, say this install has no backup.

To restore: `docker compose down`, `rm -rf ~/selfhost/syncthing/data/config`, untar the archive
into ~/selfhost/syncthing, chown `data` back to 1000 on Linux, then `docker compose up -d`.
Files under data/sync return from the other device.

## 9. Updating later

New versions are listed at https://github.com/syncthing/syncthing/releases. The Docker Hub tag
drops the leading `v`, so `v2.1.4` is tag `2.1.4`. Back up first, then put the new tag and its
digest in compose.yml:

```bash
cd ~/selfhost/syncthing
docker compose pull
docker compose up -d
docker compose logs --tail 30 syncthing
```

Syncthing migrates its own database on the way up. Watch the log until it settles, then re-run
step 7's checks before calling the update done.

## 10. What will probably go wrong

I edited a document on my laptop, closed the lid, and expected it on the other machine by the
time I got there. It was not, and I spent a while hunting the interface for an error. There was
none: with no inbound port on either side, both devices have to be awake at the same moment for
anything to move, and mine had not overlapped in two days. Docker Desktop also does not always
start with the session, so after a reboot run `docker compose up -d` in ~/selfhost/syncthing
before concluding anything broke.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not publish 22000 or rebind 8139 to 0.0.0.0 so another device can dial in. Dialling out is
  what this path uses instead.
- Do not add a folder outside ~/selfhost/syncthing until the first has synced cleanly for a
  day. A misconfigured one deletes files on the other device.
