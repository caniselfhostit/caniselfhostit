You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Ghostfolio 3.50.0, with its PostgreSQL and Redis, under ~/selfhost/ghostfolio, answering
at http://localhost:8196.

## 1. Preflight

Say this before step 2 runs. Ghostfolio tracks investments, not spending: no categories, no
budgets, no bank connection, so activities are typed in or imported from a CSV. It answers at
http://localhost:8196 only, so a phone cannot open it, and prices refresh only when this computer
is awake.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. This stack needs 2048 MB of RAM available
and 10 GB free on the home disk, on amd64 or arm64. If RAM is under 2048 MB or free disk under
10 GB, print both and stop.

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
mkdir -p ~/selfhost/ghostfolio/backups
ls -la ~/selfhost/ghostfolio
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: every account and
price is a PostgreSQL row in the volume step 5 creates.

## 4. Secrets

Four secrets. `POSTGRES_PASSWORD` and `REDIS_PASSWORD` guard the data services,
`ACCESS_TOKEN_SALT` hashes the user's security token before storage, `JWT_SECRET_KEY` signs the
session tokens. Generate all four here, print none, keep them out of summaries and logs.

```bash
umask 077
cat > ~/selfhost/ghostfolio/.env <<EOF
ROOT_URL=http://localhost:8196
POSTGRES_DB=ghostfolio
POSTGRES_USER=ghostfolio
POSTGRES_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
ACCESS_TOKEN_SALT=$(openssl rand -hex 32)
JWT_SECRET_KEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/ghostfolio/.env
umask 022
ls -l ~/selfhost/ghostfolio/.env
```

Assert: mode `-rw-------`. Tell the user what `ACCESS_TOKEN_SALT` costs: a database restored
beside a different .env accepts
nobody, and changing it locks every token out, with no password reset to fall back on. On Windows
those bits are advisory and the real boundary is the Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/ghostfolio/compose.yml <<'EOF'
# Ghostfolio · the deterministic fallback for the local path. Authored by
# caniselfhostit from upstream's own packaging at the pinned tag:
#   compose file ... https://github.com/ghostfolio/ghostfolio/blob/3.50.0/docker/docker-compose.yml
#   variables ...... https://github.com/ghostfolio/ghostfolio/blob/3.50.0/README.md
#
# Three services on the computer you are sitting at. Paths are relative to
# ~/selfhost/ghostfolio/, so one file works on macOS, Linux and Windows. The
# database is a named volume, not a bind mount: PostgreSQL chowns its data
# directory to its own uid, which Windows bind mounts cannot allow. 5432 and
# 6379 are published nowhere. Digests read 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:15.19-alpine@sha256:5d23207f297fbb632e375dd80b4631282086d18f537d5e981dd0058501963a43
    container_name: ghostfolio-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ghostfolio
      POSTGRES_USER: ghostfolio
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ghostfolio-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ghostfolio -d ghostfolio"]
      interval: 10s
      retries: 12

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: ghostfolio-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    # Upstream's own command and probe. $$ becomes a literal $ inside.
    command:
      - /bin/sh
      - -c
      - redis-server --requirepass "$$REDIS_PASSWORD"
    healthcheck:
      test:
        - CMD-SHELL
        - redis-cli --pass "$$REDIS_PASSWORD" ping | grep -q PONG
      interval: 10s
      retries: 12

  ghostfolio:
    image: ghostfolio/ghostfolio:3.50.0@sha256:9b8cab0eddcaecdfe1611a218f09567d39a660677b612e12837d2084d97e21a4
    container_name: ghostfolio
    restart: unless-stopped
    init: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    env_file: ./.env
    environment:
      DATABASE_URL: postgresql://ghostfolio:${POSTGRES_PASSWORD}@postgres:5432/ghostfolio?connect_timeout=300
      REDIS_HOST: redis
      REDIS_PORT: 6379
    ports:
      - "127.0.0.1:8196:3333"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:3333/api/v1/health"]
      interval: 10s
      retries: 30
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  ghostfolio-pgdata:
EOF
cd ~/selfhost/ghostfolio && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one port, one volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. A certificate attests a public name and
nothing here has one, and browsers treat http://localhost as a secure context, so pages needing
crypto still work. Nothing is published beyond loopback: 8196 is bound to 127.0.0.1, not the
user's phone, not a laptop on the wifi, nobody outside. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/ghostfolio/compose.yml
```

Assert: that prints `1`. PostgreSQL and Redis publish no host port, so neither 5432 nor 6379 can
appear.

## 7. Start and verify

First boot applies 117 database migrations and a seed before the server answers. Use the loop,
not a sleep.

```bash
cd ~/selfhost/ghostfolio
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8196/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8196/api/v1/health; echo
curl -sS http://localhost:8196/en | grep -c '<title>Ghostfolio'
curl -sS http://localhost:8196/api/v1/info | grep -c createUserAccount
```

Assert all four and print what you received. The loop ends on `200`. Health prints
`{"status":"OK"}`, which upstream returns only when the database and the Redis cache both answer,
so one line covers all three containers. The third prints a number above `0`. The fourth prints
`1`: account creation is open and the first account created becomes the administrator. If any of
the four misses, read `docker compose logs --tail 40 ghostfolio`: `Applying migration` wants
more time, `Can't reach database server` is step 4, `port is already allocated` is step 10.
A running container is not success.

Create the administrator account yourself and close the door behind it. An instance that takes
new accounts is one router change from belonging to somebody else:

```bash
umask 077
curl -sS -X POST http://localhost:8196/api/v1/user -o ~/selfhost/ghostfolio/first-user.json
grep -o '"role":"[A-Z]*"' ~/selfhost/ghostfolio/first-user.json
grep -o '"accessToken":"[^"]*"' ~/selfhost/ghostfolio/first-user.json | cut -d'"' -f4 > ~/selfhost/ghostfolio/security-token.txt
chmod 600 ~/selfhost/ghostfolio/first-user.json ~/selfhost/ghostfolio/security-token.txt
curl -sS -o /dev/null -w '%{http_code}\n' -X PUT -H "Authorization: Bearer $(grep -o '"authToken":"[^"]*"' ~/selfhost/ghostfolio/first-user.json | cut -d'"' -f4)" -H 'Content-Type: application/json' -d '{"value":"false"}' http://localhost:8196/api/v1/admin/settings/IS_USER_SIGNUP_ENABLED
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8196/api/v1/user
rm ~/selfhost/ghostfolio/first-user.json
curl -sS http://localhost:8196/api/v1/info | grep -c createUserAccount
```

Assert, in order: `"role":"ADMIN"`, `200`, `403`, `0`. The `403` is upstream refusing to create
an account, the `0` is the same fact from the public info endpoint, and both must pass. Never
print the token, and do not continue on `"role":"USER"`.

STOP: tell the user to read their token with `cat ~/selfhost/ghostfolio/security-token.txt`, save
it in their password manager, then open http://localhost:8196, press `Sign in`, and paste it.
Do not continue until they confirm they see their own empty portfolio.
That token is the only way in: the account has no email and no password.

## 8. First backup and restore

Two artifacts: a database dump, and a config archive with what rebuilds the service around it,
token included.

```bash
cd ~/selfhost/ghostfolio
docker compose exec -T postgres pg_dump -U ghostfolio -d ghostfolio | gzip > ~/selfhost/ghostfolio/backups/ghostfolio-db-$(date +%F).sql.gz
tar -C ~/selfhost/ghostfolio -czf ~/selfhost/ghostfolio/backups/ghostfolio-config-$(date +%F).tar.gz compose.yml .env security-token.txt
ls -lh ~/selfhost/ghostfolio/backups/
```

Assert: both exist, non-empty, sizes printed. The dump is about 16 KB fresh.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination off this computer, a sync folder or a USB stick, and
copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert: the user confirms
both filenames are there, or say there is no backup.

To restore, in this order: untar the config archive into ~/selfhost/ghostfolio first, so
compose.yml and .env are back before any container starts, because PostgreSQL takes
`POSTGRES_PASSWORD` from .env the moment it initialises an empty volume. Then
`docker compose down -v`, the one place `-v` belongs, `docker compose up -d postgres`, wait 30
seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U ghostfolio -d ghostfolio`, then `docker compose up -d`.
The dump alone is not enough: the token is hashed with `ACCESS_TOKEN_SALT`, so a database beside
a fresh .env is unopenable.

## 9. Updating later

New versions are at https://github.com/ghostfolio/ghostfolio/releases, and the release tag is the
image tag. Upstream ships most weeks, so treat this pin as a snapshot and read the changelog
before crossing minor versions. PostgreSQL stays on upstream's 15 line. Back up, then edit the
image line:

```bash
cd ~/selfhost/ghostfolio
docker compose pull
docker compose up -d
docker compose logs --tail 30 ghostfolio
```

The log ends with the version banner and `Listening at http://0.0.0.0:3333`. Watch it settle,
then re-run step 7's health check.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8196, and got a connection error that reads like
a lost database. It was not: Docker Desktop had not started with the session, so nothing was
listening on 8196, and `restart: unless-stopped` acts only once the Docker daemon is up. Turn on
its start-at-login setting, then after a reboot run
`cd ~/selfhost/ghostfolio && docker compose up -d` before deciding anything is broken. Two more
look broken and are not: `port is already allocated` means something else holds 8196, which
`lsof -nP -iTCP:8196 -sTCP:LISTEN` names, and blank prices are usually the machine having been
asleep. For prices ask http://localhost:8196/api/v1/health/data-provider/YAHOO: `200` means Yahoo
answered and `503` means rate-limited, neither of which this install fixes.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8196 to 0.0.0.0 so a phone can reach it, and do not point `ROOT_URL` at a LAN
  address. Both put a portfolio on every network the user joins.
- Do not set `ENABLE_FEATURE_AUTH_OIDC`, any `OIDC_` or `API_KEY_` variable, or
  `ENABLE_FEATURE_SUBSCRIPTION`. The defaults need no account.
