You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install OpenProject 17.7.1, with the PostgreSQL it stores every project in, under
~/selfhost/openproject, answering at http://localhost:8116.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
OpenProject answers at http://localhost:8116, this computer and nowhere else, so nobody they
invite to a project can reach it, nor their own phone, and it runs only while the machine is
awake. On this path it is a planner for one person, not a place a team meets.

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
distribution ID and codename print next, for step 2. Upstream publishes a floor of 4096 MB of
RAM and 20 GB of disk; both images publish amd64 and arm64. On macOS and Windows that figure is
the host's and Docker Desktop takes its share out of it, so check it is allowed 4 GB. If RAM is
under 4096 MB or disk under 20 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/openproject/assets ~/selfhost/openproject/backups
ls -la ~/selfhost/openproject
```

Assert: `ls -la` shows `assets` and `backups`, owned by the user. `assets` holds every file
attached to a work package; the container chowns it to its `app` user, so its owner changing in
step 7 is expected. Upstream notes macOS can refuse that chown outside the user's own home,
which is why this layout stays inside it. The database has no folder: step 5 keeps it in a
volume Docker manages.

## 4. Secrets

Three secrets, generated here. `SECRET_KEY_BASE` signs sessions and derives the key for
encrypted columns, `OPENPROJECT_SEED_ADMIN_USER_PASSWORD` replaces the password the seeder would
put on the `admin` account, and `DB_PASSWORD` is the PostgreSQL password. Hex, not
base64: OpenProject parses environment values as YAML, where base64 punctuation is a hazard.
Print none of them and keep all three out of your summary and every log line.

```bash
umask 077
cat > ~/selfhost/openproject/.env <<EOF
OPENPROJECT_HOST__NAME=localhost:8116
OPENPROJECT_HTTPS=false
SECRET_KEY_BASE=$(openssl rand -hex 64)
OPENPROJECT_SEED_ADMIN_USER_PASSWORD=$(openssl rand -hex 24)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/openproject/.env
umask 022
ls -l ~/selfhost/openproject/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three. `OPENPROJECT_HTTPS=false` is required here and only here: nothing on this
machine terminates TLS, and at its default OpenProject redirects every request to an address
that does not exist. On Windows those mode bits are advisory; the real boundary is the user's
own account.

## 5. compose.yml

```bash
cat > ~/selfhost/openproject/compose.yml <<'EOF'
# OpenProject · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://www.openproject.org/docs/installation-and-operations/installation/docker/
#
# Two services, every path relative to ~/selfhost/openproject/ so one file
# works on macOS, Linux and Windows. The database is a named volume because the
# PostgreSQL image chowns its data directory to a uid a Windows home bind
# cannot grant; attachments stay a bind mount, visible in Finder or Explorer.
# The all-in-one image runs Puma, the worker, memcached, the collaborative
# editing server and an Apache under one supervisord, and starts no PostgreSQL
# of its own. Digests read 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: openproject-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: openproject
      POSTGRES_USER: openproject
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - openproject-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U openproject -d openproject"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  openproject:
    image: openproject/openproject:17.7.1@sha256:bbaaedbe3837097dd189f739565064accb731d23cd87294a21bd07e0be010f6a
    container_name: openproject
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgres://openproject:${DB_PASSWORD}@postgres/openproject
      RAILS_MIN_THREADS: "4"
      RAILS_MAX_THREADS: "16"
      IMAP_ENABLED: "false"
    volumes:
      - ./assets:/var/openproject/assets
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1/health_checks/default || exit 1"]
      interval: 15s
      retries: 20
      start_period: 600s
    ports:
      # Loopback only: no other device on the wifi can reach 8116.
      - "127.0.0.1:8116:80"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  openproject-pgdata:
EOF
cd ~/selfhost/openproject && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Do not set `SERVER_NAME`: left unset, the Apache inside the
image answers on any hostname, which is what makes `localhost` and the container's own health
check both work.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the editor still works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8116 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. Confirm it:

```bash
grep -n '127.0.0.1:8116' ~/selfhost/openproject/compose.yml
```

Assert: one line, `- "127.0.0.1:8116:80"`. PostgreSQL publishes no host port, so 5432 cannot
appear at all.

## 7. Start and verify

The container runs every migration and then the seeder before Apache starts, so the first boot
takes minutes. The loop allows ten of them.

```bash
cd ~/selfhost/openproject
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8116/health_checks/default); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8116/health_checks/default
curl -sS http://localhost:8116/login | grep -o '<h1>Sign in</h1>'
docker compose exec -T openproject bundle exec rails runner 'puts "shipped-default-still-works=" + User.find_by(login: "admin").check_password?("admin").to_s'
```

Assert all four and print what you received: the loop ends on `200`; the health response
contains `PASSED`; the third prints `<h1>Sign in</h1>`, the first screen's heading; the fourth
prints `shipped-default-still-works=false`, the security assert here, because upstream
seeds login `admin` with password `admin` and step 4 replaced it. If it prints `true`, stop and
say so.

If any of the four misses, stop, run `docker compose logs --tail 60 openproject` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a database that never
reports healthy points at step 4, where an empty `DB_PASSWORD` leaves PostgreSQL refusing to
start; a log still in migrations wants more time. If `port is already allocated`
came back, find what holds 8116 (`lsof -nP -iTCP:8116 -sTCP:LISTEN`, or
`netstat -ano | findstr :8116` on Windows) and stop until the user frees it. A running container
is not success.

STOP: tell the user to read the seeded password with
`grep OPENPROJECT_SEED_ADMIN_USER_PASSWORD ~/selfhost/openproject/.env`, put it in their
password manager, sign in at http://localhost:8116/login as `admin`, and wait. Do not continue
until they confirm. OpenProject forces a password change on that first sign-in; the seeded value
exists so no account here answers to a password printed in upstream's docs.

## 8. First backup and restore

Two artifacts: a database dump with every project, work package, comment and user, and a file
archive with the attachments and the two files that rebuild the service.

```bash
cd ~/selfhost/openproject
docker compose exec -T postgres pg_dump -U openproject -d openproject -x -O | gzip > ~/selfhost/openproject/backups/openproject-db-$(date +%F).sql.gz
tar -C ~/selfhost/openproject -czf ~/selfhost/openproject/backups/openproject-files-$(date +%F).tar.gz compose.yml .env assets
ls -lh ~/selfhost/openproject/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`; in Git Bash a Windows drive is
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames there, or say plainly
this install has no backup.

To restore, in this order. `cd ~/selfhost/openproject`, untar the file archive there first so
compose.yml and .env are back before any container starts: PostgreSQL takes `DB_PASSWORD` from
.env when it initialises an empty volume, and `SECRET_KEY_BASE` decrypts the encrypted columns
in the dump, so a database restored without its .env is one nobody can read. Then
`docker compose down -v`, which drops the old volume on purpose,
`docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U openproject -d openproject`, then
`docker compose up -d` and wait for step 7's loop. That is the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/opf/openproject/releases. Take both backups first,
then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/openproject
docker compose pull
docker compose up -d
docker compose logs --tail 40 openproject
```

A minor-version jump migrates the database and can take as long as the first boot. Watch that
log until it settles, then re-run step 7's health check. Read the release notes before crossing
a major version: those carry steps this prompt does not.

## 10. What will probably go wrong

I closed the lid with a work package half written, opened it an hour later, and got a browser
error that read like a lost database. It was not: the machine had suspended both containers with
itself, and OpenProject needed a minute after the wake to answer. Where it really is gone is
after a reboot, because `restart: unless-stopped` acts only once the Docker daemon is up and
Docker Desktop starts with the session only if that setting is on. Turn it on, and after a
reboot run `cd ~/selfhost/openproject && docker compose up -d`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `OPENPROJECT_HOST__NAME` to this machine's LAN address and do not rebind 8116 to
  0.0.0.0 so a colleague can reach it. That puts a Rails application on every network the user
  joins.
- Do not configure SMTP. OpenProject runs without it, so every notification it would have
  emailed stays in the web interface.
- Do not switch to the `-slim` image or split this into upstream's nine-service compose file.
