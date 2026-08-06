You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Mattermost 11.9.0 and the PostgreSQL it stores every message in, under
~/selfhost/mattermost, answering at http://localhost:8113.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Mattermost is a team chat server, and this one answers only at http://localhost:8113: this
computer and nowhere else. Nobody they invite can reach it, and neither can their own phone.

Detect the OS and measure the machine:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. Mattermost plus
PostgreSQL needs 2048 MB of RAM available and 10 GB free on the home disk. If either is under,
print both numbers and stop. Do not install and hope.

Upstream publishes the Mattermost image for amd64 only. If `uname -m` printed `arm64`, this is an
Apple Silicon Mac and Docker Desktop runs the server under x86 translation: it works and starts
slowly. If it printed `aarch64`, this is arm64 Linux with no translation layer: print and stop.

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
  with its signing key saved to a file first, never piped into a shell. The fence is guarded, a
  no-op on anything but a Linux with apt:

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

The Mattermost image is distroless and runs as uid 2000, writing to four directories.

```bash
mkdir -p ~/selfhost/mattermost/{config,data,plugins,client-plugins,backups}
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 2000:2000 ~/selfhost/mattermost/{config,data,plugins,client-plugins}
fi
ls -la ~/selfhost/mattermost
```

Assert: `ls -la` shows all five directories. The chown is Linux-only: on macOS and Windows Docker
Desktop maps container writes onto the user's own account. There is no PostgreSQL directory,
because step 5 keeps that database in a Docker volume.

## 4. Secrets

One secret: the PostgreSQL password. Generate it here, print it nowhere, and keep it out of your
summary and out of any log line. Hex rather than base64, because it is pasted into a connection
string where `+` and `/` would need escaping.

```bash
umask 077
cat > ~/selfhost/mattermost/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/mattermost/.env
umask 022
ls -l ~/selfhost/mattermost/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same on
all three systems. Mattermost writes its own at-rest encryption key and public-link salt into
`config/config.json` on first start. On Windows those mode bits are advisory: NTFS does not
enforce them, and the user's own account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/mattermost/compose.yml <<'EOF'
# Mattermost · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   container deploy ... https://docs.mattermost.com/deployment-guide/server/deploy-containers.html
#   variable reference . https://github.com/mattermost/docker/blob/main/env.example
#
# Two services, every path relative to ~/selfhost/mattermost/ so one file works
# on macOS, Linux and Windows. PostgreSQL is a named volume because that image
# chowns its cluster to a uid Docker Desktop cannot grant on a Windows bind
# mount. Mattermost runs as uid 2000, so step 3 chowns its four bind mounts on
# Linux. Digests read 2026-08-06; only amd64 for Mattermost.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: mattermost-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: mattermost
      POSTGRES_USER: mmuser
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - mattermost-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mmuser -d mattermost"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 never leaves the compose network.

  mattermost:
    image: mattermost/mattermost-team-edition:11.9.0@sha256:1c538cf33c2144ba2c825571cd414aaaebf8d8c231d4b18081b811cd0ca0ef2a
    container_name: mattermost
    platform: linux/amd64
    restart: unless-stopped
    environment:
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: "postgres://mmuser:${DB_PASSWORD}@postgres:5432/mattermost?sslmode=disable&connect_timeout=10"
      # Nothing terminates TLS here, so every link says http and localhost.
      MM_SERVICESETTINGS_SITEURL: http://localhost:8113
      # Anonymous signup stays shut; the server exempts the first account.
      MM_TEAMSETTINGS_ENABLEOPENSERVER: "false"
      # No SMTP and no telemetry: no mail, nothing reported to Sentry.
      MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS: "false"
      MM_LOGSETTINGS_ENABLEDIAGNOSTICS: "false"
    volumes:
      - ./config:/mattermost/config
      - ./data:/mattermost/data
      - ./plugins:/mattermost/plugins
      - ./client-plugins:/mattermost/client/plugins
    ports:
      # Loopback only: no other device on the wifi can reach 8113.
      - "127.0.0.1:8113:8065"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  mattermost-pgdata:
EOF
cd ~/selfhost/mattermost && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the webapp still works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8113 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. For a chat server that is the whole trade, which is why step 1
says it first. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/mattermost/compose.yml
```

Assert: one line, `- "127.0.0.1:8113:8065"`. PostgreSQL publishes no host port, so 5432 cannot
appear.

## 7. Start and verify

Mattermost runs its own migrations on the way up, so the first start is much slower than the
second, and slower again under x86 translation.

```bash
cd ~/selfhost/mattermost
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8113/api/v4/system/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8113/api/v4/system/ping
curl -sS http://localhost:8113/api/v4/config/client | tr ',' '\n' | grep NoAccounts
```

Assert all three, and print what you received for each: the loop ends on `200`; the ping response
contains `"status":"OK"`; the last line prints `"NoAccounts":"true"`, the server saying it has no
users yet. If any misses, stop, run `docker compose logs --tail 40 mattermost` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a database that never
reports healthy points at step 4, where an empty `DB_PASSWORD` leaves PostgreSQL refusing to
start; a log that cannot load its configuration points at the ownership of `config` in step 3. If
`port is already allocated` came back, find what holds 8113 (`lsof -nP -iTCP:8113 -sTCP:LISTEN`)
and stop until the user frees it. A running container is not success.

The first screen at http://localhost:8113 is the account form, headed `Create your account`. The
first account made here becomes the system administrator.

STOP: tell the user to open http://localhost:8113, create their account, put that password in
their password manager, and wait. Do not continue until they confirm. There is no mail here, so a
forgotten password has no reset link.

Once they confirm:

```bash
curl -sS http://localhost:8113/api/v4/config/client | tr ',' '\n' | grep NoAccounts
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"email":"signup-check@example.invalid","username":"signupcheck"}' http://localhost:8113/api/v4/users
```

Assert: the first prints `"NoAccounts":"false"`, the second `403`, the server refusing an
anonymous signup now that an account exists. Both must pass before you report success.

## 8. First backup and restore

Two artifacts: a database dump with every message, channel and account, and a file archive with
the uploads and the generated config.

```bash
cd ~/selfhost/mattermost
docker compose exec -T postgres pg_dump -U mmuser -d mattermost | gzip > ~/selfhost/mattermost/backups/mattermost-db-$(date +%F).sql.gz
tar -C ~/selfhost/mattermost -czf ~/selfhost/mattermost/backups/mattermost-files-$(date +%F).tar.gz compose.yml .env config data
ls -lh ~/selfhost/mattermost/backups/
```

Assert: both files exist and are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy both there with `cp`; in Git Bash a Windows
drive is written `/d/Backups`. Assert: the user confirms both filenames are listed there, and if
they have neither, say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/mattermost`, untar the file archive there first so .env
is back before any container starts: PostgreSQL reads `DB_PASSWORD` the moment it initialises an
empty volume, and a missing .env means a blank password and a database that will not start. Then
`docker compose down -v`, the one place `-v` belongs because it drops the old volume on purpose,
`docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T postgres psql -U mmuser -d mattermost`, then `docker compose up -d`.
Log in and open a channel. That is the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/mattermost/mattermost/releases. Take both backups
first, then edit the image line in ~/selfhost/mattermost/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/mattermost
docker compose pull
docker compose up -d
docker compose logs --tail 30 mattermost
```

Watch that log until the migrations settle, then re-run step 7's ping check. Move one major
version at a time.

## 10. What will probably go wrong

I ran `docker compose up -d`, curled http://localhost:8113 straight away, got a connection reset,
and started undoing things. Nothing was broken: Mattermost was still on its first migration,
which took the better part of two minutes. Then I looked inside with
`docker compose exec mattermost sh` and got `executable file not found`, which is not a second
failure: the image is distroless and has no shell at all. Step 7's loop covers the first,
`docker compose logs -f mattermost` the second.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `MM_SERVICESETTINGS_SITEURL` to a LAN address or rebind 8113 to 0.0.0.0 so a
  phone can reach it. That puts real messages on every network the user joins.
- Do not configure SMTP, and do not enable AD/LDAP, SAML or OpenID sign-on. Mattermost runs
  without mail, and the sign-on integrations are licensed features of the paid editions that
  answer with an error here rather than a login page.
- Do not switch to the mattermost-enterprise-edition image. That is a different licence and this
  install chose Team Edition on purpose.
