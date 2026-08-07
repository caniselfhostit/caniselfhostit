You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Backrest 1.14.1 under ~/selfhost/backrest, answering at http://localhost:8136, to copy
folders from this computer to storage the user chooses.

## 1. Preflight

Say this to the user before step 2 runs. Backrest is a web UI and a scheduler over restic, and on
this path it backs up the files on this computer, which is what a backup product is meant to do.
Two consequences. A plan set for 3am runs only if the computer is awake then, so on a laptop the
honest schedule is an interval with the clock set to last run time. And the storage is a bill
from somebody: what stops is the per-computer fee.

Detect the OS and measure the machine.

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
distribution ID and codename print next, for step 2. Backrest needs 1024 MB of RAM available and
5 GB free on the home disk, and the image publishes amd64 and arm64. If either floor is missed,
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
mkdir -p ~/selfhost/backrest
cd ~/selfhost/backrest
mkdir -p config data cache restore backups
ls -la
```

Assert: `ls -la` shows five folders owned by the user. On macOS and Windows Docker Desktop's file
sharing owns permissions inside them; on Linux the container writes as root, which is why the
step 8 archive is made by the container.

## 4. Secrets

One secret: the password for the web login. Generate it here, print it nowhere, and keep it out
of the summary and every log line. The rest of the step is the security decision: a Backrest with
no configuration file writes itself a default one with authentication disabled, and then answers
every API call from anything on this computer that reaches the port.

```bash
cd ~/selfhost/backrest
umask 077
cat > .env <<EOF
BACKREST_USERNAME=admin
BACKREST_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 .env
cat > config/config.json <<'EOF'
{
  "version": 6,
  "instance": "local-computer",
  "auth": {"disabled": false, "users": [{"name": "admin", "passwordBcrypt": "PLACEHOLDER"}]}
}
EOF
grep BACKREST_PASSWORD .env | cut -d= -f2- | docker run --rm -i caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648 caddy hash-password | base64 | tr -d '\n' > config/hash.tmp
awk 'NR==FNR{h=$0;next} {sub(/PLACEHOLDER/,h);print}' config/hash.tmp config/config.json > config/config.tmp
mv config/config.tmp config/config.json && rm config/hash.tmp
chmod 600 config/config.json
umask 022
ls -l .env config/config.json
grep -q PLACEHOLDER config/config.json && echo "substitution failed" || echo "hash in place"
```

Assert: both files exist at mode `-rw-------`, and the last line prints `hash in place`. Backrest
stores a password as a bcrypt hash that is then base64 encoded, and the pinned Caddy image runs
for a second to produce it, because no bcrypt tool ships on all three of these systems. `version`
is required: a file with content and no version number is rejected at start-up. On Windows those
mode bits are advisory, and the real boundary is the user's own account.

Tell the user their password is in ~/selfhost/backrest/.env, readable with
`grep BACKREST_PASSWORD ~/selfhost/backrest/.env`, and that it goes in their password manager
now.

## 5. compose.yml

```bash
cat > ~/selfhost/backrest/compose.yml <<'EOF'
# Backrest · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   readme and docker ... https://github.com/garethgeorge/backrest/blob/v1.14.1/README.md
#   getting started ..... https://garethgeorge.github.io/backrest/introduction/getting-started
#   entrypoint defaults . https://github.com/garethgeorge/backrest/blob/v1.14.1/cmd/docker-entrypoint/main.go
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/backrest/, which lets one file work on macOS, Linux and Windows.
# ../.. is the home directory two levels up, read-only: the files this install
# exists to copy somewhere safe. A restored file lands in ./restore.
# ./backups is mounted because the container writes its state as root, so on
# Linux step 8's archive is taken by the container. The VPS file needs no such
# mount: there, sudo does that job on the host.
#
# Tag and digest read from ghcr.io on 2026-08-06; the image publishes amd64,
# arm64, arm/v6, arm/v7 and 386.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  backrest:
    image: ghcr.io/garethgeorge/backrest:v1.14.1@sha256:b852979754281026230cc69fb11428e6d57c9a97784ab4a444ffc7934c53a215
    container_name: backrest
    restart: unless-stopped
    environment:
      BACKREST_PORT: "0.0.0.0:9898"
      BACKREST_CONFIG: /config/config.json
      BACKREST_DATA: /data
      XDG_CACHE_HOME: /cache
      BACKREST_RESTIC_COMMAND: /bin/restic
      TZ: UTC
    volumes:
      # Repository URIs, schedules and the login hash, from step 4.
      - ./config:/config
      - ./data:/data
      # restic's cache: rebuildable, and it grows with the repo index.
      - ./cache:/cache
      - ./restore:/restore
      # Where step 8 writes the archive of this configuration.
      - ./backups:/backups
      # Your home folder, read-only. The plan picks folders inside it.
      - ../..:/userdata:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8136.
      - "127.0.0.1:8136:9898"
EOF
cd ~/selfhost/backrest && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, six mounts, no database.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the login form works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8136 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the wifi,
not anyone on the internet. A backup tool loses little to that: the snapshots travel to the
repository either way. Confirm:

```bash
grep -n '127.0.0.1' ~/selfhost/backrest/compose.yml
```

Assert: one line, `- "127.0.0.1:8136:9898"`.

## 7. Start and verify

```bash
cd ~/selfhost/backrest
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8136/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8136/ | grep -o '<title>Backrest</title>'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8136/v1.Backrest/GetOperations -H 'Content-Type: application/json' -d '{}'
printf 'user = "admin:%s"\n' "$(grep BACKREST_PASSWORD ~/selfhost/backrest/.env | cut -d= -f2-)" | curl -sS -o /dev/null -w '%{http_code}\n' -K - -X POST http://localhost:8136/v1.Backrest/GetOperations -H 'Content-Type: application/json' -d '{}'
```

Assert all four, and print what you received for each: the loop ends on `200`; the second prints
`<title>Backrest</title>`; the third prints `401`, the security assert here, because an
unauthenticated call is refused and step 4 therefore took effect; the fourth prints `200`, which
proves the password matches the hash and hands it to curl through a config on standard input, so
it never reaches a command line. If any of the four misses, stop, run
`docker compose logs --tail 40 backrest`, and name the cause: a container that exits in seconds
is step 4, and `port is already allocated` means something else holds 8136
(`lsof -nP -iTCP:8136 -sTCP:LISTEN`, or `netstat -ano | findstr :8136` on Windows). A running
container is not success.

STOP: tell the user to read their password with
`grep BACKREST_PASSWORD ~/selfhost/backrest/.env`, put it in their password manager, open
http://localhost:8136, and log in as `admin`. Wait. Do not continue until they confirm. The
first screen is a box headed `Login`, with `Username` and `Password` fields and a `Log in`
button.

## 8. First backup and restore

Two backups: this install's own configuration, the archive below, and then the user's first
snapshot, which is what they installed this for.

```bash
cd ~/selfhost/backrest
docker compose stop
docker compose run --rm --no-deps -T --entrypoint tar backrest -czf /backups/backrest-config-$(date +%F).tar.gz -C / config data -C /userdata/selfhost/backrest compose.yml
docker compose start
ls -lh ~/selfhost/backrest/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container makes it because on
Linux it owns those files, and the stop is on purpose: a SQLite history copied mid-write is not a
backup. The archive will hold every repository password the user types.

It also sits on the same disk as the data, which is not a backup, and on a laptop the disk and
the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`; in Git Bash a Windows
drive is written `/d/Backups`. Assert: the user confirms the file is listed there.

STOP: tell the user to open http://localhost:8136, click `Add Repo` and set up the storage their
snapshots go to, then `Add Plan` with paths under `/userdata`, run that plan once, and restore
one file from the snapshot into `/restore`. Wait. Do not continue until they confirm. Two things
to tell them. The repository password they type is a restic encryption password: lose it and
every snapshot is unreadable, by them too, so it goes in the password manager beside the login.
And the paths box wants paths inside the container, where the home folder is `/userdata`, so
Documents is `/userdata/Documents`.

```bash
ls -lR ~/selfhost/backrest/restore
```

Assert: the restored file is there and non-empty. Print the listing. A backup nobody has restored
is a hope, and that turns it into a fact. To restore this install itself: `docker compose
down`, delete `config` and `data`, recreate them as in step 3, then run the container command
above with `-xzf` in place of `-czf`, unpacking into `/`.

## 9. Updating later

New versions are listed at https://github.com/garethgeorge/backrest/releases. Take the step 8
archive first, then edit the image line in ~/selfhost/backrest/compose.yml to the new pin:

```bash
cd ~/selfhost/backrest
docker compose pull
docker compose up -d
docker compose logs --tail 30 backrest
```

Backrest rewrites its configuration in place as it migrates, so watch that log until it settles,
then re-run step 7's four checks.

## 10. What will probably go wrong

The schedule, quietly. I set a plan for 3am, came back a week later, and the history showed two
backups instead of seven. Nothing was broken: this computer was asleep at 3am on five of those
nights, and a wall-clock schedule that comes due while the machine is off does not run late. It
does not run. The fix is in the plan: a daily interval with the clock set to last run time, which
fires when the lid opens. Check the history after the first week.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not disable authentication or add a second user. One generated password is the model.
- Do not configure command hooks or an rclone remote in the container. Hooks run as root with
  the home folder mounted, and rclone's config directory is not mounted, so a remote configured
  there dies with the next recreate.
