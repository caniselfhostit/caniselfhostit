You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Penpot 2.17.0, with the PostgreSQL and Valkey it needs, under ~/selfhost/penpot,
answering at http://localhost:8122.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Penpot is built around people working in the same file, and here nobody else can reach it: every
board and share link begins with http://localhost:8122, which means "this computer" wherever it
is read. What they get is a full design tool for one person.

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
distribution ID and codename print next, for step 2. Penpot needs 4096 MB of RAM available and
20 GB free on the home disk; all five images publish amd64 and arm64. On macOS and Windows that
figure is the host's, and Docker Desktop's machine takes its slice out of it. Under either
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
mkdir -p ~/selfhost/penpot/assets ~/selfhost/penpot/backups
if [ "$(uname -s)" = "Linux" ]; then sudo chown -R 1001:1001 ~/selfhost/penpot/assets; fi
ls -la ~/selfhost/penpot
```

Assert: `ls -la` shows `assets` and `backups`. Backend and frontend both run as uid 1001 and
share `assets`, so on Linux it is chowned to 1001 or uploads fail on a permission error; on macOS
and Windows that fence is a no-op. There is no `data` folder: the designs are PostgreSQL rows in a
volume Docker manages.

## 4. Secrets

Two: the master key Penpot derives session and invitation keys from, and the PostgreSQL
password. Generate both here, print neither, keep both out of your summary and out of every log
line. Hex, not base64, because `openssl rand -base64 64` wraps onto two lines.

```bash
umask 077
cat > ~/selfhost/penpot/.env <<EOF
PENPOT_PUBLIC_URI=http://localhost:8122
PENPOT_FLAGS=enable-registration disable-email-verification disable-secure-session-cookies enable-prepl-server
PENPOT_SECRET_KEY=$(openssl rand -hex 64)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/penpot/.env
umask 022
ls -l ~/selfhost/penpot/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run the same on all three; on Windows
the mode bits are advisory and the real boundary is the user's own account. The key is 512 bits,
the size upstream asks for. The flags: registration is open until step 7 closes it; verification
is off because nothing here sends mail; secure session cookies are off because upstream's own
compose turns them off on a plain http address; the prepl server is the local socket the
backend's CLI uses, the way back in if a password is forgotten.

## 5. compose.yml

```bash
cat > ~/selfhost/penpot/compose.yml <<'EOF'
# Penpot · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ... https://help.penpot.app/technical-guide/getting-started/docker/
#   configuration .... https://help.penpot.app/technical-guide/configuration/
#   sizing + valkey .. https://help.penpot.app/technical-guide/getting-started/recommended-settings/
#   flag definitions . https://github.com/penpot/penpot/blob/2.17.0/common/src/app/common/flags.cljc
#
# Five services, every path relative to ~/selfhost/penpot/ so one file works on
# macOS, Linux and Windows. The database is a named volume because PostgreSQL
# chowns its data directory to a uid Docker Desktop cannot grant on a home
# bind mount; assets stay a bind mount, chowned to 1001 on Linux, the uid the
# backend and frontend run as. Upstream also runs an MCP server and a
# mailcatcher; both are omitted here, and telemetry is off. Digests read from
# Docker Hub 2026-08-06, all five multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: penpot

services:
  penpot-postgres:
    image: postgres:15.18@sha256:6eb0add3b77c081df18aa518ce43df58fdcc40f2e6d868a6fd08038dc7acd425
    restart: unless-stopped
    stop_signal: SIGINT
    environment:
      POSTGRES_DB: penpot
      POSTGRES_USER: penpot
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_INITDB_ARGS: --data-checksums
    volumes:
      - penpot-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U penpot -d penpot"]
      interval: 10s
      retries: 30
    # No `ports:`: 5432 is reachable only from the other containers.

  penpot-valkey:
    image: valkey/valkey:8.1.9-alpine@sha256:a038175878d66b9d274fbf8be73c0305e93798b83917647f167e18cef3c71eec
    restart: unless-stopped
    # Arguments rather than upstream's env var; numbers from their docs.
    command: ["valkey-server", "--maxmemory", "128mb", "--maxmemory-policy", "volatile-lfu"]
    healthcheck:
      test: ["CMD-SHELL", "valkey-cli ping | grep PONG"]
      interval: 5s
      retries: 20

  penpot-backend:
    image: penpotapp/backend:2.17.0@sha256:471cdebf185be899ef7d7593e9cd7994b908ebd7ffb78ca547e3d843bb83536f
    restart: unless-stopped
    volumes:
      - ./assets:/opt/data/assets
    environment:
      PENPOT_FLAGS: ${PENPOT_FLAGS}
      PENPOT_PUBLIC_URI: ${PENPOT_PUBLIC_URI}
      PENPOT_SECRET_KEY: ${PENPOT_SECRET_KEY}
      PENPOT_DATABASE_URI: postgresql://penpot-postgres/penpot
      PENPOT_DATABASE_USERNAME: penpot
      PENPOT_DATABASE_PASSWORD: ${DB_PASSWORD}
      PENPOT_REDIS_URI: redis://penpot-valkey/0
      PENPOT_OBJECTS_STORAGE_BACKEND: fs
      PENPOT_OBJECTS_STORAGE_FS_DIRECTORY: /opt/data/assets
      PENPOT_TELEMETRY_ENABLED: "false"
    depends_on:
      penpot-postgres:
        condition: service_healthy
      penpot-valkey:
        condition: service_healthy

  penpot-exporter:
    image: penpotapp/exporter:2.17.0@sha256:7e8beb6ef2bdb9d778e9bbcbf7feebf8c99a137b2d9eb3969450c0a1a49e41c5
    restart: unless-stopped
    environment:
      PENPOT_PUBLIC_URI: ${PENPOT_PUBLIC_URI}
      PENPOT_SECRET_KEY: ${PENPOT_SECRET_KEY}
      PENPOT_REDIS_URI: redis://penpot-valkey/0
      PENPOT_INTERNAL_URI: http://penpot-frontend:8080
    depends_on:
      penpot-valkey:
        condition: service_healthy

  penpot-frontend:
    image: penpotapp/frontend:2.17.0@sha256:861989dfff50f12b9de1358c6b0f3cc1e601d7a678db2826f3643d0f93438500
    restart: unless-stopped
    volumes:
      - ./assets:/opt/data/assets
    environment:
      PENPOT_FLAGS: ${PENPOT_FLAGS}
      PENPOT_PUBLIC_URI: ${PENPOT_PUBLIC_URI}
    ports:
      # Loopback only: no other device on the wifi can reach 8122.
      - "127.0.0.1:8122:8080"
    depends_on:
      - penpot-backend
      - penpot-exporter

volumes:
  penpot-pgdata:
EOF
cd ~/selfhost/penpot && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Every `${...}` is filled from the .env in that directory.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. No hostname, so
nothing to resolve. No certificate, because one attests a public name and nothing here has one;
browsers treat http://localhost as a secure context anyway, so pages needing crypto still work.
No firewall rule, because nothing is published beyond loopback: 8122 is bound to 127.0.0.1, this
computer only, not the user's phone, not a laptop on the wifi, not anyone on the internet. For a
tool built around shared files that is the trade, not a defect. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/penpot/compose.yml
```

Assert: one line, `- "127.0.0.1:8122:8080"`. The other four publish no host port at all.

## 7. Start and verify

The pull is about 1.4 GB, mostly the exporter's browser; the backend then migrates its database
before answering.

```bash
cd ~/selfhost/penpot
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8122/readyz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8122/readyz
curl -sS http://localhost:8122/ | grep -c 'Penpot | Full-stack design'
curl -sS http://localhost:8122/js/config.js
```

Assert all four, printing what you got: the loop ends on `200`; `/readyz` prints `OK`, earned by
a real query against PostgreSQL; the grep prints `1`, from the `<title>` Penpot serves;
`config.js` carries step 4's flags, `enable-registration` among them. If any misses, stop, run
`docker compose logs --tail 40 penpot-backend`, and name the cause: a backend that never starts
is step 4 and an empty `DB_PASSWORD`; `port is already allocated` means something else holds
8122 and the user has to free it. A running container is not success.

The first screen at http://localhost:8122 shows the heading `Log into my account` with a
`Create an account` link under it.

STOP: tell the user to open http://localhost:8122, click `Create an account`, and register with
any email address and a password they save in a password manager first. Nothing sends mail here,
so no reset message ever arrives. Do not continue until they confirm.

Then close registration and recreate the two containers that read the flag:

```bash
cd ~/selfhost/penpot
umask 077
sed 's/^PENPOT_FLAGS=enable-registration/PENPOT_FLAGS=disable-registration/' .env > .env.new && mv .env.new .env
umask 022
chmod 600 .env
docker compose up -d --force-recreate penpot-backend penpot-frontend
sleep 20
curl -sS http://localhost:8122/js/config.js | grep -c 'disable-registration'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8122/readyz
```

Assert: `1` and `200`. That write goes through a temporary file because `sed -i` takes an
argument on macOS and none on Linux.

STOP: tell the user to reload http://localhost:8122 in a private window and confirm the
`Create an account` link is gone. That, and both asserts, before you report success.

## 8. First backup and restore

Two artifacts: the database holds every file, board, comment and account; the archive holds the
uploads plus the `.env` those sessions depend on.

```bash
cd ~/selfhost/penpot
docker compose exec -T penpot-postgres pg_dump -U penpot -d penpot | gzip > ~/selfhost/penpot/backups/penpot-db-$(date +%F).sql.gz
tar -C ~/selfhost/penpot -czf ~/selfhost/penpot/backups/penpot-config-$(date +%F).tar.gz compose.yml .env assets
ls -lh ~/selfhost/penpot/backups/
```

Assert: both exist, both non-empty, print both sizes. Nothing stops: `pg_dump` snapshots a
running database consistently, and Valkey holds nothing that outlives a restart. If `tar` says
`Permission denied` on Linux, run that line again with `sudo`.

Both sit on the same disk as the data, which is not a backup; on a laptop the disk and the
machine fail together. Ask the user for a destination off this computer, a sync folder or a USB
stick, and copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both filenames are there. If they have neither, say
plainly this install has no backup.

To restore, in this order. `cd ~/selfhost/penpot`, untar the config archive there first so
compose.yml, .env and assets are back before any container starts: PostgreSQL reads
`DB_PASSWORD` from .env the moment it initialises an empty volume. Then `docker compose down -v`,
the one place `-v` belongs because it drops the old volume on purpose,
`docker compose up -d penpot-postgres`, about 30 seconds for healthy, `gunzip -c` on the
`.sql.gz` piped into `docker compose exec -T penpot-postgres psql -U penpot -d penpot`, then
`docker compose up -d`, then log in and open a file. Those two files are one backup: a database
restored beside a different `PENPOT_SECRET_KEY` logs everyone out, and one restored without
`assets` opens every board with the images missing.

## 9. Updating later

Releases are at https://github.com/penpot/penpot/releases. Take both backups first, then edit
the three `penpotapp/` image lines in compose.yml to the new tag and digest, as one.

```bash
cd ~/selfhost/penpot
docker compose pull
docker compose up -d
docker compose logs --tail 40 penpot-backend
```

The backend migrates its database on the way up. Watch that log settle, then re-run step 7's
check.

## 10. What will probably go wrong

I exported a board to PDF on a laptop, got nothing for a long minute, and assumed the exporter
had died. It had not. That container starts a headless Chromium out of a 641 MB image, and on
macOS and Windows it does so inside Docker Desktop's virtual machine, which gets its own slice of
memory rather than the host figure step 1 measured. If exports hang while the rest of Penpot
feels fine, open Docker Desktop, Settings, Resources and give it 4 GB. Editing works below that;
exporting is what does not.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `PENPOT_PUBLIC_URI` to a LAN address and do not rebind 8122 to 0.0.0.0 so a
  colleague can join a file. That puts a tool whose session cookie is not marked secure onto
  every network this computer joins.
- Do not configure SMTP, and do not add `enable-mcp` or an MCP container.
