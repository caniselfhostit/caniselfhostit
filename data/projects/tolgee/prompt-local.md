You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Tolgee 3.218.0, with the PostgreSQL it keeps its translations in, under
~/selfhost/tolgee, answering at http://localhost:8178.

## 1. Preflight

Say this before step 2 runs; it decides whether the user wants this at all.
Tolgee answers at http://localhost:8178, which means this computer and nothing else: no
translator on another laptop can open a key, and the SDK reaches it only from an application
running here. A private translation editor with a real API, on one desk.

Detect the OS and measure:

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
distribution ID and codename print next, for step 2. Tolgee is a JVM beside a PostgreSQL: 2048 MB
of RAM available, 10 GB free on the home disk, amd64 or arm64. On macOS and Windows that figure
is the host's and Docker Desktop's virtual machine takes its allocation out of it, so read
step 10 first. Under either floor, print both numbers and stop.

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
mkdir -p ~/selfhost/tolgee/data ~/selfhost/tolgee/backups
ls -la ~/selfhost/tolgee
```

Assert: `ls -la` shows `data` and `backups`, both owned by the user. `data` holds the file
storage, screenshots and the JWT key Tolgee falls back to. No ownership fix runs here: the
container writes as root into a directory the user owns, and on macOS and Windows Docker Desktop
handles that. The database is not in this tree; step 5 puts it in a volume Docker manages.

## 4. Secrets

Three secrets: the PostgreSQL password, the secret Tolgee signs session tokens with (upstream
requires at least 32 characters), and the password of the `admin` account Tolgee creates on first
start. Setting that last one keeps Tolgee from inventing one and writing it to a file inside the
container. Print none of the three and keep them out of every log line.

```bash
umask 077
cat > ~/selfhost/tolgee/.env <<EOF
TOLGEE_FRONT_END_URL=http://localhost:8178
DB_PASSWORD=$(openssl rand -hex 32)
TOLGEE_AUTHENTICATION_JWT_SECRET=$(openssl rand -hex 32)
TOLGEE_AUTHENTICATION_INITIAL_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/tolgee/.env
umask 022
ls -l ~/selfhost/tolgee/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three. On Windows the mode bits are advisory: NTFS does not enforce them, and the
real boundary is the Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/tolgee/compose.yml <<'EOF'
# Tolgee · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   running with docker . https://docs.tolgee.io/platform/self_hosting/running_with_docker
#   configuration ....... https://docs.tolgee.io/platform/self_hosting/configuration
#   image build ......... https://github.com/tolgee/tolgee-platform/blob/v3.218.0/docker/app/Dockerfile
#
# Two services on the computer you are sitting at, with every path relative to
# ~/selfhost/tolgee/ so one file works on macOS, Linux and Windows. The database
# is a named volume because PostgreSQL chowns its data directory to a uid a
# home-directory bind mount cannot grant on Windows. The PostgreSQL 13 this
# image bundles is off because upstream removes it in v4. Digests read on
# 2026-08-07; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: tolgee-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: tolgee
      POSTGRES_USER: tolgee
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - tolgee-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U tolgee -d tolgee"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  tolgee:
    image: tolgee/tolgee:v3.218.0@sha256:1955a9e28fb247bc0404809432d0ee179b43966f5080b8100a70333375db4382
    container_name: tolgee
    restart: unless-stopped
    env_file: ./.env
    environment:
      # The docker profile ships this false: no login screen, everyone an
      # administrator, and a browser tab on this machine is a caller.
      TOLGEE_AUTHENTICATION_ENABLED: "true"
      # New people arrive by invitation, never by signing themselves up.
      TOLGEE_AUTHENTICATION_REGISTRATIONS_ALLOWED: "false"
      # Do not start the PostgreSQL bundled in this image.
      TOLGEE_POSTGRES_AUTOSTART_ENABLED: "false"
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/tolgee
      SPRING_DATASOURCE_USERNAME: tolgee
      SPRING_DATASOURCE_PASSWORD: ${DB_PASSWORD}
      # No daily usage counts leave this computer.
      TOLGEE_TELEMETRY_ENABLED: "false"
    volumes:
      # File storage, plus the JWT key Tolgee falls back to.
      - ./data:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8178.
      - "127.0.0.1:8178:8080"
    # No healthcheck stanza: the image declares its own on /actuator/health.
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  tolgee-pgdata:
EOF
cd ~/selfhost/tolgee && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback.

8178 is bound to 127.0.0.1: not the phone, not another laptop, not the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/tolgee/compose.yml
```

Assert: that prints `1`, the published-port line `- "127.0.0.1:8178:8080"`. PostgreSQL publishes
no host port, so 5432 cannot appear. Authentication still matters here: with it off, any browser
tab on this machine reaches 8178 as an administrator, and step 7 checks that it cannot.

## 7. Start and verify

Tolgee migrates its own schema on the way up, and a cold JVM takes a minute to answer at all.
The loop is that minute.

```bash
cd ~/selfhost/tolgee
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8178/api/public/configuration); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8178/api/public/configuration | grep -o '"authentication":[a-z]*\|"allowRegistrations":[a-z]*'
curl -sS http://localhost:8178/v2/public/initial-data | grep -o '"userInfo":[^,]*'
```

Assert all three and print what you received. The loop ends on `200`. The second command prints
`"authentication":true` and `"allowRegistrations":false`. The third prints `"userInfo":null`.

The third is the security assert. On the image's own default `TOLGEE_AUTHENTICATION_ENABLED` is
false, there is no login screen, and every caller gets a super-powered session as the
administrator, so an anonymous request returns a populated `userInfo` object. `null` means a
caller with no token is nobody. Anything else: stop, do not report success, run
`docker compose exec -T tolgee printenv TOLGEE_AUTHENTICATION_ENABLED`.

If the loop never reaches `200`, stop, run `docker compose logs --tail 40 tolgee` and
`docker compose logs --tail 20 postgres`, and name the cause: a database that never reports
healthy is step 4, where an empty `DB_PASSWORD` leaves PostgreSQL refusing to start, and a
container exiting `137` is step 10. On `port is already allocated`, find what holds 8178 with
`lsof -nP -iTCP:8178 -sTCP:LISTEN`. A running container is not success.

The first screen at http://localhost:8178 is headed `Login` over an `Email` box, a `Password`
box and a `Login` button, with no sign-up link because registration is off.

STOP: tell the user to read their password with
`grep TOLGEE_AUTHENTICATION_INITIAL_PASSWORD ~/selfhost/tolgee/.env`, put it in their password
manager, sign in with `admin` typed into the `Email` box, and confirm they see the dashboard.
Wait. Do not continue until they confirm.

Then tell them the next step is theirs: create a project, add the languages, generate a project
API key in its settings, and point their SDK at `apiUrl` http://localhost:8178 with that key.

## 8. First backup and restore

Two artifacts: a database dump with every key, translation and account, and an archive of the
file storage plus the two files that rebuild the service.

```bash
cd ~/selfhost/tolgee
docker compose exec -T postgres pg_dump -U tolgee -d tolgee | gzip > ~/selfhost/tolgee/backups/tolgee-db-$(date +%F).sql.gz
tar -C ~/selfhost/tolgee -czf ~/selfhost/tolgee/backups/tolgee-config-$(date +%F).tar.gz compose.yml .env data
ls -lh ~/selfhost/tolgee/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing is stopped: `pg_dump` snapshots
a running database.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`. Assert: the user confirms both filenames
are listed there.

To restore, in this order. `cd ~/selfhost/tolgee` and untar the config archive there first, so
.env is back before any container starts: PostgreSQL takes `DB_PASSWORD` from it the moment it
initialises an empty volume, and the JWT secret beside it validates every session already issued.
Then `docker compose down -v`, the one place `-v` belongs because it drops the old volume on
purpose, `docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U tolgee -d tolgee`, then
`docker compose up -d`.

## 9. Updating later

New versions are listed at https://github.com/tolgee/tolgee-platform/releases, and the Docker tag
is the release tag with its leading `v`. Take both backups first, then edit the image line in
compose.yml:

```bash
cd ~/selfhost/tolgee
docker compose pull
docker compose up -d
docker compose logs --tail 30 tolgee
```

Watch that log until it settles, then re-run step 7's checks before calling it done.

## 10. What will probably go wrong

Memory, and it does not announce itself. I ran this on a Mac whose Docker Desktop was set to
2 GB. The tolgee container came up, sat there, and died with exit code `137` about ninety seconds
in, over and over. `137` is the virtual machine's out-of-memory killer, not a fault in the
configuration: a JVM and a PostgreSQL do not fit in 2 GB together. Open Docker Desktop's
Resources settings, give it at least 4 GB, apply and restart, then `docker compose up -d` again.
On Linux there is no such machine and the host memory step 1 measured is the ceiling.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not set `TOLGEE_AUTHENTICATION_ENABLED` to false, and do not rebind 8178 to 0.0.0.0 so a
  teammate can reach it. Together they put an unauthenticated administrator on every network
  this computer joins.
- Do not configure SMTP. Without it there is no invitation mail and no password reset, so the
  password in .env is the recovery story.
- Do not install the Tolgee SDK into the user's application. That needs their repository;
  this prompt installs the server it talks to.
