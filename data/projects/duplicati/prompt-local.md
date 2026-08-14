You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Duplicati 2.3.0.4 under ~/selfhost/duplicati, answering at http://localhost:8188.

## 1. Preflight

Say this to the user before step 2 runs. Duplicati is a backup client, not a place to put
backups: it encrypts the files on this computer and uploads them to a destination the user
supplies, so what stops is a subscription and what starts is a storage bill. A schedule set for
3am runs only if this computer is awake then, so on a laptop the honest setting is a daily run
that fires when the lid opens.

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
distribution ID and codename print next, for step 2. Duplicati needs 1024 MB of RAM available and
5 GB free on the home disk; the image publishes amd64, arm64 and arm/v7. If either floor is
missed, print both and stop.

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
mkdir -p ~/selfhost/duplicati/data ~/selfhost/duplicati/restore ~/selfhost/duplicati/backups
ls -la ~/selfhost/duplicati
```

Assert: `ls -la` shows three folders owned by the user. On macOS and Windows, Docker Desktop's
file sharing owns permissions inside them; on Linux the container writes `data` as root, which is
why step 8 needs sudo there.

## 4. Secrets

Two secrets, generated on this machine, in hex because a human types one of them into a form. Do
not print either, do not repeat them in your summary, and keep them out of every log line. The
security decision is the first line. Duplicati always has a web password: set none and it
generates a random one at first start, then writes a one-time sign-in link into the container
log, leaving the way in inside `docker compose logs`. Setting the password first replaces that
with a value the user owns. `SETTINGS_ENCRYPTION_KEY`, the one variable with no `DUPLICATI__`
prefix, encrypts the credential fields in the settings database, where the destination's keys
are about to live.

```bash
cd ~/selfhost/duplicati
umask 077
cat > .env <<EOF
DUPLICATI__WEBSERVICE_PASSWORD=$(openssl rand -hex 24)
SETTINGS_ENCRYPTION_KEY=$(openssl rand -hex 32)
EOF
chmod 600 .env
umask 022
ls -l .env
```

Assert: the file exists at mode `-rw-------`. On Windows those mode bits are advisory and the
real boundary is the user's own account. Tell the user their password is readable with
`grep DUPLICATI__WEBSERVICE_PASSWORD ~/selfhost/duplicati/.env`, and that both values go in their
password manager today.

## 5. compose.yml

```bash
cat > ~/selfhost/duplicati/compose.yml <<'EOF'
# Duplicati · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker image readme . https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/ReleaseBuilder/Resources/Docker/README.md
#   image build ......... https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/ReleaseBuilder/Resources/Docker/Dockerfile
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/duplicati/, which lets one file work on macOS, Linux and Windows.
# ../.. is the home folder two levels up, read only: the files this install
# exists to copy somewhere safe. No allowed-hostnames value is set here,
# because localhost and bare IP addresses are on the API's list already.
#
# Tag and digest read from docker.io on 2026-08-12; the manifest list covers
# amd64, arm64 and arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  duplicati:
    image: duplicati/duplicati:2.3.0.4-stable@sha256:01f8cb81ad7d548b7ceec61d696bb5d27d8057fee0ddee37c2b8a0ff1f1729f7
    container_name: duplicati
    restart: unless-stopped
    env_file: .env
    environment:
      # The container's clock zone. Schedules fire against it.
      TZ: UTC
      # Usage reporting ships on; this is upstream's own opt-out variable.
      DO_NOT_TRACK: "1"
    volumes:
      # Duplicati-server.sqlite, the per-job databases, the JWT signing keys.
      - ./data:/data
      # Your home folder, read only. Restores go to ./restore instead.
      - ../..:/source:ro
      - ./restore:/restore
    ports:
      # Loopback only: no other device on the wifi can reach 8188.
      - "127.0.0.1:8188:8200"
    healthcheck:
      # /health needs no token and no allowed hostname; curl is in the image.
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8200/health"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd ~/selfhost/duplicati && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, three mounts, no database.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve, and a certificate attests a public name; browsers treat http://localhost as a secure
context, so the login form works. Nothing is published beyond loopback, so no port needs closing,
and 8188 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone on the
internet. A backup tool loses little to that: the uploads still reach the destination. Confirm
the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/duplicati/compose.yml
```

Assert: that prints `1`. If it prints `0`, the compose file was edited and the port is open to
the whole network; stop and put the binding back.

## 7. Start and verify

```bash
cd ~/selfhost/duplicati
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8188/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8188/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8188/api/v1/backups
printf '{"Password":"%s","RememberMe":false}' "$(grep DUPLICATI__WEBSERVICE_PASSWORD ~/selfhost/duplicati/.env | cut -d= -f2-)" | curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8188/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @-
docker compose exec -T duplicati ls /source | head -5
```

Assert all five, and print what you received for each. The loop ends printing `200`. The second
prints `Healthy`. The third prints `401`, the security assert here: the API refuses a call with
no token, so anything else on this machine that finds the port is locked out. The fourth prints
`200`, proving the generated password is the one the container holds; it reaches curl on standard
input, never a command line. The fifth prints names from the home folder: an empty listing means
the container cannot read through that mount, and there is nothing worth backing up until it can.

If any of the five misses, stop, run `docker compose logs --tail 40 duplicati`, and name the
cause. A `401` on the fourth means .env holds a password the container did not start with, which
happens if it ran before .env existed: `docker compose down`, then `up -d`. If
`port is already allocated` came back, find what holds 8188 (`lsof -nP -iTCP:8188 -sTCP:LISTEN`,
or `netstat -ano | findstr :8188` on Windows). A running container is not success.

STOP: tell the user to read their password with
`grep DUPLICATI__WEBSERVICE_PASSWORD ~/selfhost/duplicati/.env`, put it in their password
manager, open http://localhost:8188, and sign in. Do not continue until they confirm. The first
screen is one `Password` box: there are no usernames and no second account.

## 8. First backup and restore

Two backups live in this step. The archive below backs up Duplicati itself, the settings
database that knows what to copy and where to send it. The user's own first job is the other.

```bash
cd ~/selfhost/duplicati
docker compose stop
if [ "$(uname -s)" = "Linux" ]; then SUDO=sudo; else SUDO=""; fi
$SUDO tar -C ~/selfhost/duplicati -czf ~/selfhost/duplicati/backups/duplicati-config-$(date +%F).tar.gz data compose.yml .env
docker compose start
ls -lh ~/selfhost/duplicati/backups/
```

Assert: the archive exists and is non-empty. Print its size. The stop is on purpose: a SQLite
database copied mid-write is not a backup, and it costs a few seconds. On Linux the container
wrote `data` as root, which is what the `SUDO` line is for; on macOS and Windows Docker Desktop
hands those files to the user's own account and it stays empty. The archive holds .env, so it
holds the key protecting the rest of it.

That archive is on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB stick,
and copy it there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert: the user
confirms the file is there.

STOP: tell the user to open http://localhost:8188, choose `Add backup`, set a passphrase, pick a
destination, add `/source` as the source folder with `/source/selfhost/duplicati` excluded, run
the job once, then restore one file from it into `/restore`. Do not continue until they confirm.
Two things while they do it. The passphrase encrypts every file before it leaves this machine,
nothing here can recover it, and losing it makes the destination unreadable to them as much as to
anyone else. And the folder picker shows container paths: home is `/source`, so Documents is
`/source/Documents`.

```bash
ls -lR ~/selfhost/duplicati/restore
```

Assert: the restored file is there and non-empty. Print the listing. A backup nobody has restored
is a hope, and that turns it into a fact. To restore Duplicati itself: `docker compose down`, set
`SUDO` again the same way, then `$SUDO rm -rf ~/selfhost/duplicati/data`, then
`$SUDO tar -xzf ~/selfhost/duplicati/backups/<archive> -C ~/selfhost/duplicati`, then
`docker compose up -d` and re-run step 7. That archive carries .env, so the password is back in
place before anything starts.

## 9. Updating later

Upstream publishes three channels and this pins stable, the slowest; beta and canary carry
higher numbers on the same day and are where changes are tried out, and backups are the wrong
place to be early. Stable releases appear at https://github.com/duplicati/duplicati/releases with
a tag ending in `_stable_`, and the image tag ends in `-stable`. Take the step 8 archive first,
then edit the image line in compose.yml:

```bash
cd ~/selfhost/duplicati
docker compose pull
docker compose up -d
docker compose logs --tail 30 duplicati
```

Duplicati migrates its settings database on the way up, and a version step can rebuild a job's
file index on its first run, which is slow and looks like a hang. Watch the log until it settles,
then re-run step 7's checks.

## 10. What will probably go wrong

Nothing will run, and the screen will not say so. I rebooted, Docker Desktop did not come back
with the machine, and nine days later the dashboard opened on a last-run date recent enough to
skim past without reading the year on it. A tool switched off looks exactly like one with nothing
to do. Turn on Docker Desktop's start-at-login setting, run
`cd ~/selfhost/duplicati && docker compose up -d` after any reboot, and read the last successful
run date once a month.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not install updates from inside the web UI. The version here is the image tag, and an
  in-place update is gone at the next recreate.
- Do not mount /source read-write. Restoring on top of live files is how a bad afternoon becomes
  a bad week; /restore exists for this.
