You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Metabase 0.63.2 under ~/selfhost/metabase, answering at http://localhost:8210.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Metabase is the screen a team reads together, and this one answers at http://localhost:8210:
no colleague, no phone, no other laptop on the wifi, and scheduled work stops whenever the
machine sleeps. What they get is a private analysis tool over databases they can reach.

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
distribution ID and codename print next, for step 2. This install needs 4096 MB of RAM available
and 10 GB free on the home disk; both images publish amd64 and arm64. Metabase runs on the JVM,
which takes about a quarter of the memory it can see as its heap ceiling, and here that is
whatever Docker Desktop was given, so raise its Resources limit rather than calling the machine
too small. If either number is short, print both and stop.

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
mkdir -p ~/selfhost/metabase/backups
ls -la ~/selfhost/metabase
```

Assert: `ls -la` shows `backups`. There is no data directory: the application database is a named
volume (the compose header says why) and Metabase writes only `/plugins` in its container. No
ownership fix is needed on any OS.

## 4. Secrets

Two secrets: `MB_DB_PASS` for PostgreSQL, and `MB_ENCRYPTION_SECRET_KEY`, the key Metabase
encrypts stored connection details with, from upstream's own command. Never print either.

```bash
umask 077
cat > ~/selfhost/metabase/.env <<EOF
MB_SITE_URL=http://localhost:8210
MB_DB_PASS=$(openssl rand -hex 32)
MB_ENCRYPTION_SECRET_KEY=$(openssl rand -base64 32)
EOF
chmod 600 ~/selfhost/metabase/.env
umask 022
ls -l ~/selfhost/metabase/.env
```

Assert: mode `-rw-------`. On Windows those bits are advisory and the real boundary is the user's
own account, which on a single-user machine is the boundary that matters. Tell the user the key
is in ~/selfhost/metabase/.env, that they read it with
`grep MB_ENCRYPTION_SECRET_KEY ~/selfhost/metabase/.env`, and that connection details in a
restored database cannot be decrypted without it. It belongs in a password manager, not next to
the backups.

## 5. compose.yml

```bash
cat > ~/selfhost/metabase/compose.yml <<'EOF'
# Metabase · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream docs and source at the pinned tag:
#   docker + app db .... https://github.com/metabase/metabase/blob/v0.63.2/docs/installation-and-operation/running-metabase-on-docker.md
#   variables .......... https://github.com/metabase/metabase/blob/v0.63.2/docs/configuring-metabase/environment-variables.md
#
# Two services on the computer you are sitting at, paths relative to
# ~/selfhost/metabase/ so one file works on macOS, Linux and Windows. The
# PostgreSQL data directory is a named volume, not a bind mount, because that
# image chowns it to its own uid, which a Windows home-folder bind mount
# cannot allow. It holds the accounts, questions, dashboards and encrypted
# connection details; what you analyse stays in the databases you connect.
#
# Digests read from Docker Hub on 2026-08-14; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.6-alpine@sha256:432b3b824c0769275ec9b0947736ef8b376d6997bcaa9de29818f613819c2feb
    container_name: metabase-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: metabase
      POSTGRES_USER: metabase
      POSTGRES_PASSWORD: ${MB_DB_PASS}
    volumes:
      - metabase-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U metabase -d metabase"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  metabase:
    image: metabase/metabase:v0.63.2@sha256:252f8c9bd56dd21158005675b55876cf9fb838e0a0e0541581af859eafe1f32e
    container_name: metabase
    restart: unless-stopped
    # MB_SITE_URL, MB_DB_PASS and MB_ENCRYPTION_SECRET_KEY live here, mode 600.
    env_file: ./.env
    environment:
      # Without this the image writes an H2 file no mount here catches.
      MB_DB_TYPE: postgres
      MB_DB_HOST: postgres
      MB_DB_PORT: "5432"
      MB_DB_DBNAME: metabase
      MB_DB_USER: metabase
      # Default is true; an env var outranks what the wizard writes.
      MB_ANON_TRACKING_ENABLED: "false"
      # Every report and every scheduled hour is read in this zone.
      JAVA_TIMEZONE: UTC
    healthcheck:
      # Upstream's own: 503 with a progress number while migrations run.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://localhost:3000/api/health"]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 120s
    ports:
      # Loopback only: no other device on the wifi can reach 8210.
      - "127.0.0.1:8210:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  metabase-pgdata:
EOF
cd ~/selfhost/metabase && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. A certificate attests
a public name nothing here has, and browsers treat http://localhost as a secure context anyway.
8210 is bound to 127.0.0.1, this computer only:

```bash
grep -c '"127.0.0.1:' ~/selfhost/metabase/compose.yml
```

Assert: that prints `1`. One published port, on loopback, and PostgreSQL publishes nothing. A
loopback binding governs what arrives, not what Metabase can call outward.

## 7. Start and verify

The first boot runs the whole migration set, so it takes minutes.

```bash
cd ~/selfhost/metabase
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8210/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8210/api/health; echo
curl -sS http://localhost:8210/api/session/properties | grep -oE '"(has-user-setup":[a-z]*|setup-token":")'
```

Assert all three and print what you received. The loop ends printing `200`. The health call
prints `{"status":"ok"}`, which upstream returns only once start-up is complete and the
application database answers. The third prints `"has-user-setup":false` and `"setup-token":"`:
Metabase mints a setup token on first launch and publishes it as a public setting, readable here
only from this computer.

If any of the three misses, stop, run `docker compose logs --tail 40 metabase` and
`docker compose logs --tail 20 postgres`. A `503` reading `{"status":"initializing"` is this step
unfinished, not a failure. If `port is already allocated` came back, find what holds 8210 with
`lsof -nP -iTCP:8210 -sTCP:LISTEN`, or `netstat -ano | findstr :8210` on Windows.

STOP: tell the user to open http://localhost:8210/setup, complete the wizard that creates their
administrator account, and wait. Do not continue until they confirm.
The password still belongs in a password manager: upstream's shipped rule accepts six characters
with one digit, and this database will hold credentials for every data source they connect. When
the wizard offers a database, choose to add data later.

Then:

```bash
curl -sS http://localhost:8210/api/session/properties | grep -oE '"(has-user-setup|setup-token)":[a-z]*'
```

Assert: `"has-user-setup":true` and `"setup-token":null`. Upstream clears the token the moment
the first user exists, so it can never be used again.

STOP: tell the user to sign in and do two things, then wait. Do not continue until they confirm.
One: open `+ New`, choose `Question`, pick the `Orders` table of the `Sample Database` that ships
inside the image, summarize it as a count of rows grouped by a date column, and save it. That is
the whole loop, on data already there. Two: under the grid icon, `Admin`, `Databases`,
`Add a database`, connect one of their own. `localhost` there is the Metabase container, not this
machine; a database on this machine is `host.docker.internal`.

## 8. First backup and restore

Two artifacts. The database holds every account, question, dashboard and connection detail; the
config archive holds what rebuilds the service around it, including the key. Being a named
volume, it is dumped, not copied.

```bash
cd ~/selfhost/metabase
docker compose exec -T postgres pg_dump -U metabase -d metabase | gzip > ~/selfhost/metabase/backups/metabase-db-$(date +%F).sql.gz
tar -C ~/selfhost/metabase -czf ~/selfhost/metabase/backups/metabase-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/metabase/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing is stopped, because `pg_dump`
snapshots a running database consistently.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB stick,
and copy both there with `cp`; in Git Bash that is `/d/Backups`, not `D:\Backups`. Assert: the
user confirms both names are there. If they have nowhere, say so plainly.

To restore: `docker compose down -v`, `tar -xzf backups/metabase-config-<date>.tar.gz`,
`docker compose up -d postgres`, wait twenty seconds, then
`gunzip -c backups/metabase-db-<date>.sql.gz | docker compose exec -T postgres psql -U metabase -d metabase`,
and `docker compose up -d`. Order matters: a Metabase started against an empty database writes a
fresh schema and you do this twice. Neither archive holds the data they analyse.

## 9. Updating later

New versions are listed at https://github.com/metabase/metabase/releases. One repository ships
two lines: `v0.x` is the open source build published as `metabase/metabase`, `v1.x` the
commercial build published as `metabase/metabase-enterprise`, so stay on `v0`. Docker Hub also
carries patch tags upstream has not tagged in the repository, so a tag there is no proof the
source behind it is public; this pins 0.63.2, the newest release upstream has tagged.

Back up first, then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/metabase
docker compose pull
docker compose up -d
docker compose logs --tail 40 metabase
```

A major version upgrade changes the schema, and upstream is explicit that going back means the
backup or a `migrate down` from the higher version. Watch the log until it settles, then re-run
step 7's health check.

## 10. What will probably go wrong

I closed the laptop, opened it next morning, went to http://localhost:8210 and got nothing at
all. Docker Desktop had not come back after the reboot; the second time it had, but Metabase was
four minutes into its migrations and answering `503` with `{"status":"initializing"` in the body,
which looks exactly like a broken install if you do not read it. Turn on
Docker Desktop's start-at-login, and after a reboot run
`cd ~/selfhost/metabase && docker compose up -d` and wait out step 7's loop.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8210 to 0.0.0.0 so a phone on the wifi can load a dashboard. That puts a tool
  holding credentials for every connected database on every network this machine joins.
- Do not switch to the `metabase-enterprise` image, set a license token, or configure SMTP. The
  first two need a subscription, the third a mail relay on a laptop.
