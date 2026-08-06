You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Mealie 3.22.0 under ~/selfhost/mealie, answering at http://localhost:8117.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install. Mealie is
at its best when the phone in the kitchen and the laptop in the study open the same recipe
list. Here there is one address, http://localhost:8117, and it means "this computer" wherever
it is typed, so the phone by the stove gets a connection error and nobody else in the household
can be invited.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. Mealie needs 1024 MB of RAM available and
5 GB free on the home disk; the image publishes amd64 and arm64, not 32-bit ARM. Under either
floor, print both numbers and stop.

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
mkdir -p ~/selfhost/mealie/data ~/selfhost/mealie/backups
ls -la ~/selfhost/mealie
```

Assert: `ls -la` shows `data` and `backups`, both owned by the user. Everything Mealie keeps
goes under `data`: the database, the photos, and two key files it writes for itself on first
start. On Linux the image chowns it to uid 911 on first start, leaving it readable but
not writable by the user; Docker Desktop absorbs that on macOS and Windows.

## 4. Secrets

One secret: `ADMIN_PASSWORD`, which step 7 puts on the account the image seeds in place of the
password upstream publishes. Mealie writes its own token signing keys into `data/` on first
start, so there is nothing else to create. Generate it here, print it never, keep it out of
your summary and every log line.

```bash
umask 077
cat > ~/selfhost/mealie/.env <<EOF
BASE_URL=http://localhost:8117
TZ=UTC
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/mealie/.env
umask 022
ls -l ~/selfhost/mealie/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same
everywhere. Docker Compose reads it for the `${...}` substitutions in compose.yml when it runs
from ~/selfhost/mealie, so `BASE_URL` and `TZ` reach the container and the file is never
mounted. `ADMIN_PASSWORD` is not a setting and no container sees it.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/mealie/compose.yml <<'EOF'
# Mealie · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   install checklist .. https://docs.mealie.io/documentation/getting-started/installation/installation-checklist/
#   sqlite sample ...... https://docs.mealie.io/documentation/getting-started/installation/sqlite/
#   variable reference . https://docs.mealie.io/documentation/getting-started/installation/backend-config/
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/mealie/, so one file works on macOS, Linux and Windows and the
# recipes stay a folder you can open in Finder or Explorer. Mealie holds
# everything in SQLite inside its own image, so there is no database container,
# and it writes its own signing keys into data/ on first start. The 1000M
# ceiling is upstream's recommendation for Python. The image runs as uid 911 and
# chowns /app on start: on Linux that leaves ./data owned by 911, readable by
# you and writable with sudo, and Docker Desktop absorbs it elsewhere. Digest
# read on 2026-08-06; amd64 and arm64 published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:v3.22.0@sha256:36c28f0642fb6c75fae8997a2d55994631b9b4bcffba3016c208fc132a4c1e69
    container_name: mealie
    restart: unless-stopped
    environment:
      # Compose substitutes both from ./.env, which is mode 600 and is never
      # mounted. ADMIN_PASSWORD is in that same file and deliberately not listed
      # here, so no container ever sees it.
      BASE_URL: ${BASE_URL}
      TZ: ${TZ}
      # Nobody can create an account from the login screen.
      ALLOW_SIGNUP: "false"
    volumes:
      - ./data:/app/data
    deploy:
      resources:
        limits:
          memory: 1000M
    ports:
      # Loopback only: no other device on the wifi can reach 8117.
      - "127.0.0.1:8117:9000"
EOF
cd ~/selfhost/mealie && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. There is no database container: SQLite rides inside the same
image, which is what upstream recommends at household scale.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8117 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/mealie/compose.yml
```

Assert: one line, `- "127.0.0.1:8117:9000"`. Nothing else in the file publishes a port.

## 7. Start and verify

Mealie migrates its database on the way up, and that start-up seeds one admin account whose
username and password upstream publishes. Bring it up and prove it answers:

```bash
cd ~/selfhost/mealie
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8117/api/app/about); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8117/api/app/about
curl -sS http://localhost:8117/ | grep -o '<title>[^<]*</title>'
```

Assert all three, printing what you got for each: the loop ends on `200`; the JSON contains
`"version":"v3.22.0"` and `"allowSignup":false`; the last prints `<title>Mealie</title>`. If any
misses, stop, run `docker compose logs --tail 40 mealie`, and name the cause: a container still
working through migrations wants more time, one restarting in a loop points at step 3, and
`port is already allocated` means something else already holds 8117. A running container is not
success.

Now close the seeded account. Its email is `changeme@example.com` and its password is
`MyPassword`, both printed in the upstream checklist:

```bash
cd ~/selfhost/mealie
shipped=MyPassword
token=$(curl -sS -X POST http://localhost:8117/api/auth/token --data-urlencode 'username=changeme@example.com' --data-urlencode "password=$shipped" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$token" ] && echo "logged in"
printf '{"currentPassword":"%s","newPassword":"%s"}' "$shipped" "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' ~/selfhost/mealie/.env)" | curl -sS -o /dev/null -w '%{http_code}\n' -X PUT http://localhost:8117/api/users/password -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' --data-binary @-
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8117/api/auth/token --data-urlencode 'username=changeme@example.com' --data-urlencode "password=$shipped"
unset token shipped
```

Assert all three: `logged in`, then `200`, then `401`. Nothing here is reachable from another
machine, but a published password on a laptop that joins other networks is still a published
password. Anything other than `401` on the last line, stop and say so. The new
password was piped in from the file rather than typed, so it never reaches the process list,
and neither it nor the token enters your output. That refused login costs one of five tries
before a day's lockout.

The first screen at http://localhost:8117 shows the wordmark `Mealie` over a `Sign in` heading,
an `Email or Username` box, a `Password` box and a `Login` button, above them a first-login
banner printing the shipped email and password. It keys off the address, not the password, so
it keeps advertising one that no longer works.

STOP: tell the user to read their password with `grep ADMIN_PASSWORD ~/selfhost/mealie/.env`,
put it in their password manager, sign in at http://localhost:8117 as `changeme@example.com`,
and confirm the recipe page loads. Wait. Do not continue until they confirm. Then tell them to
put their own address on the account under user settings, which clears that banner.

## 8. First backup and restore

One archive holds everything that matters: the database, the photos and Mealie's own key files.
Upstream's advice is to stop the container and copy `data` whole, which is what this does; the
second archive holds the two files that rebuild the service.

```bash
cd ~/selfhost/mealie
docker compose stop
tar -C ~/selfhost/mealie -czf ~/selfhost/mealie/backups/mealie-data-$(date +%F).tar.gz data
docker compose start
tar -C ~/selfhost/mealie -czf ~/selfhost/mealie/backups/mealie-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/mealie/backups/
```

Assert: both files exist and both are non-empty. Print both sizes.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is written
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both files are listed there. If they
have neither, say this install has no backup.

To restore: `cd ~/selfhost/mealie`, `docker compose down`, delete `data`, unpack the archive in
its place with `tar -xzf backups/mealie-data-<date>.tar.gz -C ~/selfhost/mealie`, untar the
config archive the same way, then `docker compose up -d`. On Linux those two commands need
`sudo` because the container owns the files; on macOS and Windows they run as they are.
Everything lives in that one directory, so restoring it signs nobody out.

## 9. Updating later

New versions are listed at https://github.com/mealie-recipes/mealie/releases; upstream asks you
to read the release notes before upgrading, not after. Take both backups first, then edit the
image line in ~/selfhost/mealie/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/mealie
docker compose pull
docker compose up -d
docker compose logs --tail 30 mealie
```

Watch that log until the migrations settle, then re-run the `/api/app/about` check from step 7
and confirm the version matches the tag you pinned.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8117 with the pan already hot, and got a
connection refused that read like a lost database. It was not: Docker Desktop had
not started with the session, so nothing was listening on 8117, and `restart: unless-stopped`
only acts once the daemon is up. Turn on Docker Desktop's start-at-login setting, and after any
reboot run `cd ~/selfhost/mealie && docker compose up -d` before concluding anything broke.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8117 to 0.0.0.0 so a phone in the kitchen can reach it. That puts a one-account
  recipe manager on every network this machine joins.
- Do not switch to PostgreSQL, configure SMTP, OIDC or LDAP, or add FlareSolverr. This install
  is one container with one account on one computer.
