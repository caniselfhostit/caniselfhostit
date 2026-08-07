You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Rallly 4.12.1, with the PostgreSQL it stores polls in, under ~/selfhost/rallly,
answering at http://localhost:8153.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Rallly's product is a link a group opens to vote on a time, and every link here begins with
http://localhost:8153, which means "this computer" wherever it is read. Nobody they invite can
open it, their own phone included. They get a scheduling tool for themselves, not a poll a group
can answer.

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
distribution ID and codename print next, for step 2. This install needs 2048 MB of RAM available
and 5 GB free on the home disk, upstream's own floor, and both images publish amd64 and arm64. On
macOS and Windows that figure is the host's, and Docker Desktop's virtual machine takes its cut of
it. If either floor is missed, print both numbers and stop.

Settle one thing more, because step 4 stops dead without it. Rallly signs people in by mailing a
six-digit code and offers no other way in, so even here it needs an SMTP relay. Upstream names
Resend, Postmark, Mailgun and Brevo, and says not to use a Gmail or Proton mailbox, because
consumer inboxes rate-limit automated senders and block sign-in mail. Have the user find a host,
port, username and password first.

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
mkdir -p ~/selfhost/rallly/backups
ls -la ~/selfhost/rallly
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: polls, votes and
accounts are rows in PostgreSQL, which step 5 keeps in a volume Docker manages, so no ownership
fix is needed anywhere.

## 4. Secrets

Two secrets: the PostgreSQL password and the session key. Generate both here, print neither, keep
both out of your summary and any log line. Upstream documents `openssl rand -hex 32` for
`SECRET_PASSWORD`, which rejects anything shorter than 32 characters.

```bash
cd ~/selfhost/rallly
umask 077
cat > .env <<EOF
NEXT_PUBLIC_BASE_URL=http://localhost:8153
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SECRET_PASSWORD=$(openssl rand -hex 32)
REGISTRATION_ENABLED=true
SUPPORT_EMAIL=CHANGE_ME
INITIAL_ADMIN_EMAIL=CHANGE_ME
SMTP_HOST=CHANGE_ME
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=CHANGE_ME
SMTP_PWD=CHANGE_ME
EOF
chmod 600 .env
umask 022
ls -l .env
```

Assert: mode `-rw-------`. Git Bash ships openssl; on Windows the mode bits are advisory and the
real boundary is the user's own account. `SUPPORT_EMAIL` is validated as an email at start-up, so
the container refuses to boot while it reads `CHANGE_ME`. `INITIAL_ADMIN_EMAIL` is the address
allowed to claim admin in step 7, and `REGISTRATION_ENABLED` is true until step 7 closes it.

STOP: tell the user to open ~/selfhost/rallly/.env in an editor, replace every `CHANGE_ME`,
correct `SMTP_PORT` if their relay is not 587 and set `SMTP_SECURE=true` if it is 465, and save.
Do not continue until they confirm, and never ask them to paste those values to you.

```bash
grep -c CHANGE_ME .env || true
```

Assert: that prints `0`. It counts lines, never values.

## 5. compose.yml

```bash
cat > ~/selfhost/rallly/compose.yml <<'EOF'
# Rallly · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://support.rallly.co/self-hosting/installation/docker
#   configuration ...... https://support.rallly.co/self-hosting/configuration
#
# Two services on the computer you are sitting at. Paths are relative to
# ~/selfhost/rallly/, so one file works on all three systems. The database is a
# named volume, not a bind mount, because the PostgreSQL image chowns its data
# directory to a uid Docker Desktop cannot grant on a Windows home directory.
# Upstream's stack adds a Traefik and a Garage object store; neither runs here.
# Digests read on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: rallly-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: rallly
      POSTGRES_USER: rallly
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - rallly-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U rallly -d rallly"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  rallly:
    image: lukevella/rallly:4.12.1@sha256:6049260ff6d3accd86730372a650b5e8063c373a09f253c45f7e4a8dc9202752
    container_name: rallly
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Built here rather than kept in .env so the password appears once.
      DATABASE_URL: postgres://rallly:${POSTGRES_PASSWORD}@postgres:5432/rallly
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:3000/api/status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s
    ports:
      # Loopback only: no other device on the wifi can reach 8153.
      - "127.0.0.1:8153:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  rallly-pgdata:
EOF
cd ~/selfhost/rallly && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume, no password:
compose reads `${POSTGRES_PASSWORD}` out of ./.env.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers treat
http://localhost as a secure context anyway. Nothing is published beyond loopback: 8153 is bound
to 127.0.0.1, this computer only, and not the user's phone or anyone they want to meet. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/rallly/compose.yml
```

Assert: that prints `1`, the published-port line `- "127.0.0.1:8153:3000"`. PostgreSQL publishes no
host port, so 5432 cannot appear.

## 7. Start and verify

The container runs its own Prisma migrations before the server listens, so the first boot takes
minutes.

```bash
cd ~/selfhost/rallly
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8153/api/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8153/api/status
curl -sS http://localhost:8153/login | grep -c '>Log in to your account or create a new one</p>'
```

Assert all three, and print what you received for each. The loop ends on `200`. The status body is
a small JSON object containing `"status":"ok"` and `"database":"connected"`. The grep prints `1`.
If any misses, stop, run `docker compose logs --tail 60 rallly`, and name the cause. Both usual
ones point at step 4: `Invalid environment variables` means a `CHANGE_ME` survived or
`SECRET_PASSWORD` is too short, and a database that never reports healthy means an empty
`POSTGRES_PASSWORD`. `port is already allocated` means something else holds 8153, so stop until
the user frees it. A running container is not success.

The first screen at http://localhost:8153/login is headed `Welcome`, with
`Log in to your account or create a new one` under it and one box asking for an email address.

STOP: tell the user to open http://localhost:8153/login, enter the address they put in
`INITIAL_ADMIN_EMAIL`, type in the six-digit code Rallly mails to it, then open
http://localhost:8153/control-panel and press the button that makes them an admin.
Do not continue until they confirm both. That code arriving is the only proof the relay from
step 4 works.

Once they confirm, close registration and prove it is closed:

```bash
cd ~/selfhost/rallly
sed 's/^REGISTRATION_ENABLED=true$/REGISTRATION_ENABLED=false/' .env > .env.next && mv .env.next .env
chmod 600 .env
docker compose up -d --force-recreate rallly
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8153/api/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8153/login | grep -c '>Login to your account to continue</p>'
curl -sS http://localhost:8153/login | grep -c '>Log in to your account or create a new one</p>' || true
```

Assert: the loop reaches `200` again, the first grep prints `1` and the second prints `0`. Both
must pass before you report success; the rewrite avoids `sed -i`, spelled differently on macOS.

## 8. First backup and restore

Two artifacts: a dump holding every poll, vote and account, and a config archive with the two
files that rebuild the service.

```bash
cd ~/selfhost/rallly
docker compose exec -T postgres pg_dump -U rallly -d rallly | gzip > ~/selfhost/rallly/backups/rallly-db-$(date +%F).sql.gz
tar -C ~/selfhost/rallly -czf ~/selfhost/rallly/backups/rallly-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/rallly/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops: `pg_dump` snapshots a
running database consistently.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a synced
folder or a USB stick, and copy both there with `cp`.
Assert: the user confirms both filenames are there, or say plainly this install has no backup.

To restore, in this order. In ~/selfhost/rallly, untar the config archive first so compose.yml and
.env are back before any container starts: PostgreSQL reads `POSTGRES_PASSWORD` from .env the
moment it initialises an empty volume. Then `docker compose down -v`, the one place `-v` belongs,
`docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T postgres psql -U rallly -d rallly`, then `docker compose up -d`. The
archive matters as much as the dump: `SECRET_PASSWORD` in .env seals every session.

## 9. Updating later

New versions are listed at https://github.com/lukevella/rallly/releases. Take both backups first,
then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/rallly
docker compose pull
docker compose up -d
docker compose logs --tail 40 rallly
```

Rallly migrates on the way up, so watch that log until it settles, then re-run step 7's checks.
Stay inside the 4.x line: a major bump is a separate decision.

## 10. What will probably go wrong

I rebooted this machine, opened the poll I had made the day before, and got a connection error
that reads exactly like a lost database. It was not. Docker Desktop had not started with the
session, nothing was listening on 8153, and `restart: unless-stopped` only acts once the Docker
daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/rallly && docker compose up -d` before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `NEXT_PUBLIC_BASE_URL` to this machine's LAN address and do not rebind 8153 to
  0.0.0.0 so a colleague can vote. That puts an app that mails sign-in codes on every network the
  user joins.
- Do not configure single sign-on or add upstream's Traefik and Garage containers.
