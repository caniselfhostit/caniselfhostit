You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install PhotoPrism 260728-ce, with the MariaDB that holds its index, under ~/selfhost/photoprism,
answering at http://localhost:8164.

## 1. Preflight

Say both of these to the user before step 2 runs; together they decide whether they want the
install at all. PhotoPrism organises, searches and shows photographs; it does not develop them, so
there is no exposure slider, no masking and no presets. And it answers only at
http://localhost:8164, this computer, so the phone that took the pictures cannot upload to it and
nobody they would share an album with can open it.

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
distribution ID and codename print next, for step 2. Upstream asks for 2 cores and 3 GB of
physical memory, and this wants 10 GB free on the home disk. Both images publish amd64 and arm64.
If available RAM is under 3072 MB or free disk is under 10 GB, print both numbers and stop. On
macOS and Windows Docker Desktop's virtual machine takes its allocation out of that total.

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
mkdir -p ~/selfhost/photoprism/backups ~/selfhost/photoprism/originals ~/selfhost/photoprism/storage
ls -la ~/selfhost/photoprism
```

Assert: all three present and owned by the user. `originals` is the library, the folder every
photograph goes into; `storage` is cache, sidecar YAML and the nightly dump PhotoPrism writes
itself. On Linux the container writes into these folders as root and
`sudo chown -R "$(id -u):$(id -g)" ~/selfhost/photoprism` hands them back; on macOS and Windows
Docker Desktop maps ownership.

## 4. Secrets

Three secrets: the initial admin password, the database user's password and the MariaDB root
password. Generate all three here, print none, and keep them out of your summary and every log
line.

```bash
umask 077
cat > ~/selfhost/photoprism/.env <<EOF
PHOTOPRISM_SITE_URL=http://localhost:8164/
PHOTOPRISM_ADMIN_PASSWORD=$(openssl rand -hex 24)
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/photoprism/.env
umask 022
ls -l ~/selfhost/photoprism/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same everywhere. Compose
reads this file for the `${...}` substitutions and never mounts it. `PHOTOPRISM_ADMIN_PASSWORD` is
read once, when the superadmin is created on the first start; step 7 says where it is really
changed. On Windows the mode bits are advisory: the real boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/photoprism/compose.yml <<'EOF'
# PhotoPrism · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker compose .. https://docs.photoprism.app/getting-started/docker-compose/
#   config options .. https://docs.photoprism.app/getting-started/config-options/
#   open source faq . https://www.photoprism.app/oss/faq
#
# The image is the "ce" build, the Community Edition upstream distributes under
# the AGPL; the unsuffixed Docker Hub tags carry their Plus License. Paths are
# relative to ~/selfhost/photoprism/, so one file works on all three systems.
# The database is a named volume because MariaDB chowns its data directory to a
# uid Docker Desktop cannot grant on a home bind mount. Digests read 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mariadb:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: photoprism-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    environment:
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DATABASE: photoprism
      MARIADB_USER: photoprism
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    volumes:
      - photoprism-dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  photoprism:
    image: photoprism/photoprism:260728-ce@sha256:15deeb6cc6c31f043625579a29a0e26f5f7b328441fc3945a7a0b7e4b54c0a18
    container_name: photoprism
    restart: unless-stopped
    # Relaxed as upstream's example does, for the tools the indexer runs.
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    working_dir: /photoprism
    environment:
      PHOTOPRISM_ADMIN_USER: "admin"
      PHOTOPRISM_ADMIN_PASSWORD: "${PHOTOPRISM_ADMIN_PASSWORD}"
      PHOTOPRISM_AUTH_MODE: "password"
      PHOTOPRISM_SITE_URL: "${PHOTOPRISM_SITE_URL}"
      PHOTOPRISM_DISABLE_TLS: "true"
      PHOTOPRISM_DEFAULT_TLS: "false"
      # Nothing is installed on first start: the container downloads nothing.
      PHOTOPRISM_INIT: ""
      PHOTOPRISM_DISABLE_MCP: "true"
      PHOTOPRISM_BACKUP_DATABASE: "true"
      PHOTOPRISM_DATABASE_DRIVER: "mysql"
      PHOTOPRISM_DATABASE_SERVER: "mariadb:3306"
      PHOTOPRISM_DATABASE_NAME: "photoprism"
      PHOTOPRISM_DATABASE_USER: "photoprism"
      PHOTOPRISM_DATABASE_PASSWORD: "${DB_PASSWORD}"
    volumes:
      # The library, a bind mount so the pictures stay visible in Finder.
      - ./originals:/photoprism/originals
      - ./storage:/photoprism/storage
    ports:
      # Loopback only: no other device on the wifi reaches 8164.
      - "127.0.0.1:8164:2342"
    depends_on:
      mariadb:
        condition: service_healthy

volumes:
  photoprism-dbdata:
EOF
cd ~/selfhost/photoprism && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. There is no hostname to resolve, a certificate
attests a public name and nothing here has one, and nothing is published beyond loopback. Browsers
treat http://localhost as a secure context, so pages needing crypto still work.

8164 is bound to 127.0.0.1, this computer only. No phone, no laptop on the same wifi, nobody on
the internet. For a photo library that is the trade: every picture stays here, and so does every
way of looking at them. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/photoprism/compose.yml
```

Assert: that prints `1`, the one published port `- "127.0.0.1:8164:2342"`. MariaDB publishes no
host port at all.

## 7. Start and verify

The first start creates the schema and the superadmin account. The image is about a gigabyte.

```bash
cd ~/selfhost/photoprism
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8164/api/v1/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8164/api/v1/status
curl -sS -o /dev/null -w '%{http_code}\n' 'http://localhost:8164/api/v1/photos?count=1'
curl -sS http://localhost:8164/ | grep -c '<title>PhotoPrism</title>'
```

Assert all four, printing what you received. The loop ends on `200`, the status body is exactly
`{"status":"operational"}`, the unauthenticated search prints `401` and the grep prints `1`. That
`401` is the security assert: `PHOTOPRISM_AUTH_MODE` is `password`, not `public`. If any of the
four misses, stop, run `docker compose logs --tail 40 photoprism` and
`docker compose logs --tail 20 mariadb`, and name the cause: a database that never reports healthy
points at step 4, where an empty `DB_PASSWORD` leaves MariaDB refusing to start. For
`port is already allocated`, find what holds 8164 with `lsof -nP -iTCP:8164 -sTCP:LISTEN`, or
`netstat -ano | findstr :8164` on Windows. A running container is not success.

The first screen at http://localhost:8164 is a sign-in card with a `Name` field, a `Password`
field and a `Sign in` button.

STOP: tell the user to open http://localhost:8164 and sign in as `admin` with the password they
read themselves using `grep PHOTOPRISM_ADMIN_PASSWORD ~/selfhost/photoprism/.env`, and wait.
Do not continue until they confirm. Tell them to put it in their password manager; it changes
in Settings, then Account.

## 8. First backup and restore

Two artifacts, not interchangeable. The dump is the index: albums, labels, faces, places and where
every file is. The archive is the configuration and sidecar YAML. Neither holds a photograph.

```bash
cd ~/selfhost/photoprism
docker compose exec -T mariadb sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/photoprism/backups/photoprism-db-$(date +%F).sql.gz
tar --exclude='storage/cache' -C ~/selfhost/photoprism -czf ~/selfhost/photoprism/backups/photoprism-config-$(date +%F).tar.gz compose.yml .env storage
ls -lh ~/selfhost/photoprism/backups/
```

Assert: both exist, both are non-empty, both sizes printed. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or an external drive, copy both archives there with `cp`, then the whole `originals` folder,
which is the photographs. In Git Bash a Windows drive is `/d/Backups`, not `D:\Backups`. Assert:
the user confirms all three are there. If not, say plainly that this install has no backup.

To restore, in this order: `cd ~/selfhost/photoprism`, untar the config archive there first so
.env is back before any container starts, because MariaDB takes `DB_PASSWORD` from it the moment
it initialises an empty volume. Then `docker compose down -v`, which drops the old volume,
`docker compose up -d mariadb`, wait 30 seconds for healthy, pipe `gunzip -c` on the
`.sql.gz` into
`docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
copy `originals` back, then `docker compose up -d`. The dump alone rebuilds an index of files that
are gone.

## 9. Updating later

Releases are datestamped at https://github.com/photoprism/photoprism/releases, and the AGPL image
carries the `-ce` suffix on Docker Hub. Take both backups first, then edit the photoprism image
line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/photoprism
docker compose pull
docker compose up -d
docker compose logs --tail 40 photoprism
```

Watch that log until it settles, then re-run step 7's status check. Upstream does not backport
fixes to older datestamps, so an install left alone updates in one jump.

## 10. What will probably go wrong

I dragged a folder of photographs into ~/selfhost/photoprism/originals, reloaded the browser, and
got an empty library. The mount was fine. PhotoPrism does not watch that folder: its automatic
index fires only for files arriving over WebDAV, so anything copied in by hand sits unseen until
somebody runs `docker compose exec -T photoprism photoprism index`. The other surprise: Docker
Desktop does not always start with the session, so after a reboot nothing answers on 8164 until
`docker compose up -d` runs.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8164 to 0.0.0.0 so a phone can reach the library. That puts every photograph on
  every network the user joins.
