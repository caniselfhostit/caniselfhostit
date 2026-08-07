You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install ToolJet v3.20.208-lts, with the PostgreSQL it keeps everything in, under
~/selfhost/tooljet, answering at http://localhost:8176.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
ToolJet builds internal tools for other people to use, and here the only address those tools have
is http://localhost:8176, which means "this computer" wherever it is read. The user gets the
builder; the colleague they meant to hand a form gets a connection error.

Detect the OS and measure:

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. It needs 4096 MB of RAM available and 20 GB
free on the home disk, and Docker Desktop's virtual machine takes its allocation out of the figure
printed. Under either floor, print both and stop. The image is amd64 only: on macOS
`arm64` is fine and slower under emulation, but stop on a `Linux` printing `aarch64`.

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
mkdir -p ~/selfhost/tooljet/backups
ls -la ~/selfhost/tooljet
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: every app and
user is a row in the PostgreSQL that step 5 keeps in a Docker volume.

## 4. Secrets

Four secrets, at the lengths upstream documents: the lockbox master key, the application secret
key, the PostgreSQL password and the PostgREST JWT secret. Generate all four here, print none,
and keep them out of your summary and any log.

```bash
umask 077
cat > ~/selfhost/tooljet/.env <<EOF
TOOLJET_HOST=http://localhost:8176
LOCKBOX_MASTER_KEY=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 64)
PG_PASS=$(openssl rand -hex 32)
PGRST_JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/tooljet/.env
umask 022
ls -l ~/selfhost/tooljet/.env
```

Assert: mode `-rw-------`; Git Bash ships openssl, so these lines run the same on all three
systems. Tell the user to copy `LOCKBOX_MASTER_KEY` into their password manager tonight, reading
it with `grep LOCKBOX_MASTER_KEY ~/selfhost/tooljet/.env`: it encrypts every datasource
credential, so a restore without it gives back every app and no working connection. On Windows
those mode bits are advisory; the real boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/tooljet/compose.yml <<'EOF'
# ToolJet · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker deployment .. https://docs.tooljet.ai/docs/setup/docker/
#   variable reference . https://docs.tooljet.ai/docs/setup/env-vars/
#   sizing ............. https://docs.tooljet.ai/docs/setup/system-requirements/
#   tooljet database ... https://docs.tooljet.ai/docs/tooljet-db/tooljet-database/
#
# The ToolJet server, one PostgreSQL holding the three databases it makes for
# itself, and the PostgREST the ToolJet Database is read through. No Redis
# service: the -ce community-edition image starts one in its own container. The
# database is a named volume because PostgreSQL chowns it to a uid Windows file
# sharing will not grant on a home folder. Digests read 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: tooljet-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: tooljet_production
      POSTGRES_USER: tooljet
      POSTGRES_PASSWORD: ${PG_PASS}
    volumes:
      - tooljet-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U tooljet -d tooljet_production"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other containers.

  tooljet:
    image: tooljet/tooljet-ce:v3.20.208-lts@sha256:78cb01a47c2a0f5efde54ebf2ff3d4c704c1523e1a6b497df65697028701f3c9
    container_name: tooljet
    restart: unless-stopped
    # amd64 only, so an Apple Silicon Mac emulates it, slower but working.
    platform: linux/amd64
    env_file: ./.env
    command: ["npm", "run", "start:prod"]
    environment:
      SERVE_CLIENT: "true"
      PORT: "3000"
      # Three databases are made on the first boot.
      PG_HOST: postgres
      PG_USER: tooljet
      PG_DB: tooljet_production
      TOOLJET_DB_HOST: postgres
      TOOLJET_DB_USER: tooljet
      TOOLJET_DB_PASS: ${PG_PASS}
      TOOLJET_DB: tooljet_db
      PGRST_HOST: http://postgrest:3000
      # No browser makes an account except the first administrator's, and
      # neither of the next two phones home, which upstream ships them doing.
      DISABLE_SIGNUPS: "true"
      DISABLE_TOOLJET_TELEMETRY: "true"
      CHECK_FOR_UPDATES: "false"
    ports:
      # Loopback only: no other device on the wifi can reach 8176.
      - "127.0.0.1:8176:3000"
    depends_on:
      postgres:
        condition: service_healthy

  postgrest:
    image: postgrest/postgrest:v12.2.0@sha256:2cf1efd2c9c2e7606610c113cc73e936d8ce9ba089271cb9cbf11aa564bc30c7
    container_name: tooljet-postgrest
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://tooljet:${PG_PASS}@postgres:5432/tooljet_db
      PGRST_JWT_SECRET: ${PGRST_JWT_SECRET}
      PGRST_DB_PRE_CONFIG: postgrest.pre_config
    depends_on:
      postgres:
        condition: service_healthy
    # Restarts until ToolJet's first boot has made tooljet_db and its
    # postgrest.pre_config function. No `ports:` here either.

volumes:
  tooljet-pgdata:
EOF
cd ~/selfhost/tooljet && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Three services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, no public name to
certify, nothing published beyond loopback to close. Browsers treat http://localhost as a secure
context, so the editor's crypto still works.

8176 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. For a tool whose apps get handed to others, that is the trade. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/tooljet/compose.yml
```

Assert: `1`. PostgreSQL and PostgREST publish no host port, so neither appears.

## 7. Start and verify

About 3 GB to pull, then three databases are made and migrated before it answers.

```bash
cd ~/selfhost/tooljet
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8176/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8176/api/health
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8176/api/onboarding/signup
docker compose exec -T postgres psql -U tooljet -d tooljet_db -tAc "select count(*) from pg_proc where proname='pre_config'"
```

Assert all four and print what you got: the loop ends on `200`; the health body contains
`"works":"yeah"`, and calls the licence expired, which the community edition does honestly; the
third prints `403`, the security assert here, because open signup is shut before any account
exists; the fourth prints `1`, the function PostgREST needs. If any misses, stop and run
`docker compose logs --tail 60 tooljet`: a container restarting in a loop is usually Docker
Desktop's memory cap, and `port is already allocated` means something else holds 8176
(`lsof -nP -iTCP:8176 -sTCP:LISTEN`, or `netstat -ano | findstr :8176` on Windows). A running
container is not success.

The first screen at http://localhost:8176 is the setup form, headed `Set up your admin account`,
over `Name`, `Email`, a password and a `Sign up` button. The browser draws that heading, which is
why the asserts go to the API rather than the page.

STOP: tell the user to open http://localhost:8176, fill that form in, and wait. Do not continue
until they confirm. It makes the only administrator here, and with no mail there is no reset, so
have them save the password as they type.

Once they confirm, prove the door shut behind them:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8176/api/onboarding/setup-super-admin
```

Assert: `403`. Before the account existed it answered `400`, on the empty body rather than on a
closed door, so the move from `400` to `403` is the proof.

## 8. First backup and restore

Two artifacts: a dump with every app, query, datasource and user, and a config archive with the
two files that rebuild the service around it.

```bash
cd ~/selfhost/tooljet
docker compose exec -T postgres pg_dumpall -U tooljet | gzip > ~/selfhost/tooljet/backups/tooljet-db-$(date +%F).sql.gz
tar -C ~/selfhost/tooljet -czf ~/selfhost/tooljet/backups/tooljet-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/tooljet/backups/
```

Assert: both exist and are non-empty. Print both sizes. `pg_dumpall` rather than `pg_dump`,
because there are three databases and the ToolJet Database is one of them.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB stick,
and copy both there with `cp`. Assert: the user confirms both filenames are listed there. If not,
say plainly that this install has no backup.

To restore: `cd ~/selfhost/tooljet` and untar the config archive first, so .env is back before
any container starts. PostgreSQL takes `PG_PASS` from it the moment it initialises an empty
volume, and `LOCKBOX_MASTER_KEY` in the same file decrypts the credentials in the dump. Then
`docker compose down -v`, which drops the old volume deliberately, then
`docker compose up -d postgres`, wait 30 seconds, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U tooljet -d postgres`, then `docker compose up -d`.

## 9. Updating later

New versions are at https://github.com/ToolJet/ToolJet/releases. Stay on the `-lts` line; `-beta`
tags are the pre-release channel upstream advises against. Back up first, then edit the ToolJet
image line in ~/selfhost/tooljet/compose.yml to the new tag and digest.

```bash
cd ~/selfhost/tooljet
docker compose pull
docker compose up -d
docker compose logs --tail 40 tooljet
```

Watch it until the migrations settle, then re-run step 7's health check.

## 10. What will probably go wrong

The wait, on an Apple Silicon Mac. I brought this up on an M-series laptop with plenty of memory,
watched `curl` return nothing for eleven minutes, and started taking the compose file apart
looking for a mistake that was not there. The image is amd64 only, so Docker Desktop was
translating every instruction, and the first boot takes several times what it does on an Intel
box. The loop in step 7 waits fifteen minutes on purpose: let it run and watch
`docker compose logs -f tooljet`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8176 to 0.0.0.0 so a colleague on the wifi can open an app. That publishes an
  internal-tools builder, and its saved credentials, onto every network this machine joins.
- Do not set `TJ_LICENSE` or switch to the `tooljet/tooljet-ee` image. This prompt installs the
  community edition, the AGPL-3.0 one.
- Do not configure SMTP, add a Redis service, or set `WORKER=true`. Mail buys invites and resets
  a single-user install does not need; the extra Redis belongs to the workflow deployment.
