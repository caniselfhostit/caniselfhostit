You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Weblate 2026.8.1.0, with the PostgreSQL and Valkey it needs, under ~/selfhost/weblate,
answering at http://localhost:8173.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all. Weblate
answers on this computer and nowhere else, so no translator they invite can open it, and it polls
the repositories it watches only while this machine is awake. What they keep is their own strings,
their own translation memory, and commits pushed back to their own git remotes.

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
distribution ID and codename print too, for step 2. Upstream states 3 GB of RAM as the floor for
Weblate, its database and a web server on one host, so this wants 3072 MB available and 10 GB free
on the home disk; all three images publish amd64 and arm64. If RAM is under 3072 MB or disk under
10 GB, print both numbers and stop. On macOS and Windows, Docker Desktop's virtual machine has its
own memory allocation and everything here runs inside it: have the user set it to 4 GB in
Settings, Resources.

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
mkdir -p ~/selfhost/weblate/data ~/selfhost/weblate/cache ~/selfhost/weblate/backups
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 1000:1000 ~/selfhost/weblate/data ~/selfhost/weblate/cache
fi
ls -la ~/selfhost/weblate
```

Assert: `ls -la` shows `data`, `cache` and `backups`. The Weblate image runs as uid 1000 and stops
when /app/data is not writable, so on Linux those two go to that uid; the guard skips on macOS and
Windows, where Docker Desktop handles it.

## 4. Secrets

Two secrets: the PostgreSQL password and the first password on the `admin` account. Generate both
here, print neither, and keep both out of your summary and out of every log line.

```bash
umask 077
cat > ~/selfhost/weblate/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
WEBLATE_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 ~/selfhost/weblate/.env
umask 022
ls -l ~/selfhost/weblate/.env
```

Assert: the file exists with mode `-rw-------`; Git Bash ships openssl. Upstream resets the
account to that variable on every start, so step 7 removes the line. On Windows those mode bits
are advisory: the real boundary is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/weblate/compose.yml <<'EOF'
# Weblate · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.weblate.org/en/latest/admin/install/docker.html
#   repository access .. https://docs.weblate.org/en/latest/vcs.html
#   image .............. https://github.com/WeblateOrg/docker/blob/main/Dockerfile
#
# Three services on the computer you are sitting at. Paths are relative to
# ~/selfhost/weblate/, so one file works on macOS, Linux and Windows. The
# database and the cache are named volumes, not folders you can open: both
# images chown their own data directory and a home-directory bind mount cannot
# grant that on Windows. Weblate's data and cache stay real folders it writes
# as uid 1000. Digests read 2026-08-07, amd64 and arm64; no TLS anywhere.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: weblate-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: weblate
      POSTGRES_USER: weblate
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - weblate-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U weblate -d weblate"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 stays on the compose network.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    container_name: weblate-cache
    restart: unless-stopped
    command: ["valkey-server", "--save", "60", "1", "--loglevel", "warning"]
    read_only: true
    volumes:
      - weblate-valkey:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 12

  weblate:
    image: weblate/weblate:2026.8.1.0@sha256:44cd8cc84c41079fa9559d7f3cb7e9b80990f2b1ef975868423e322a507edc1b
    container_name: weblate
    restart: unless-stopped
    env_file: ./.env
    environment:
      WEBLATE_SITE_DOMAIN: "localhost:8173"
      WEBLATE_SITE_TITLE: Weblate
      WEBLATE_ALLOWED_HOSTS: localhost,127.0.0.1
      WEBLATE_ADMIN_NAME: Weblate admin
      WEBLATE_ADMIN_EMAIL: admin@example.com
      # Nobody signs themselves up: translators arrive on an invitation link.
      WEBLATE_REGISTRATION_OPEN: "0"
      WEBLATE_ADMIN_NOTIFY_ERROR: "0"
      POSTGRES_HOST: postgres
      POSTGRES_PORT: "5432"
      POSTGRES_DB: weblate
      POSTGRES_USER: weblate
      REDIS_HOST: valkey
      REDIS_PORT: "6379"
    volumes:
      - ./data:/app/data
      - ./cache:/app/cache
    read_only: true
    tmpfs:
      - /run
      - /tmp
    ports:
      # Loopback only: no other device can reach 8173.
      - "127.0.0.1:8173:8080"
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy

volumes:
  weblate-pgdata:
  weblate-valkey:
EOF
cd ~/selfhost/weblate && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose fills `${POSTGRES_PASSWORD}` from `.env` here.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. There is no hostname to resolve; a certificate
attests a public name and nothing here has one, and browsers treat http://localhost as a secure
context anyway; nothing is published beyond loopback, so no port needs closing. 8173 is bound to
127.0.0.1: not the user's phone, not a laptop on the wifi, nobody on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/weblate/compose.yml
```

Assert: that prints `1`, the one published port `- "127.0.0.1:8173:8080"`. PostgreSQL and Valkey
publish no host port.

## 7. Start and verify

Weblate migrates, collects static files and starts a web server, a Celery worker and a scheduler
in one container, which is why its image sets a five-minute health-check start period and the loop
below is long.

```bash
cd ~/selfhost/weblate
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8173/healthz/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8173/healthz/
curl -sS http://localhost:8173/accounts/login/ | grep -c 'Sign in @ Weblate' || true
curl -sS http://localhost:8173/accounts/login/ | grep -c 'Register new account' || true
```

Assert all four, and print what you received for each: the loop ends on `200`; the health endpoint
answers `ok`; the third prints `1`; the fourth prints `0`, the security assert here, because
registration is closed and the `Register new account` link is absent. If any misses, stop, run
`docker compose logs --tail 40 weblate`, and name the likely cause: an empty `POSTGRES_PASSWORD`
from step 4 stops the database, a log still in migrations wants more time, exit code `137` is
step 10, and `port is already allocated` means the user has to free 8173. A running container is
not success.

The first screen at http://localhost:8173/accounts/login/ shows `Sign in to Weblate` over a
username and password form, with no register link.

STOP: tell the user to read their admin password with
`grep WEBLATE_ADMIN_PASSWORD ~/selfhost/weblate/.env`, put it in their password manager, sign in
at http://localhost:8173/accounts/login/ as `admin`, and wait. Do not continue until they confirm.

Then take that password out of configuration, so a restart cannot reset the account to it:

```bash
sed -i.bak '/^WEBLATE_ADMIN_PASSWORD/d' ~/selfhost/weblate/.env
rm -f ~/selfhost/weblate/.env.bak
cd ~/selfhost/weblate && docker compose up -d --force-recreate weblate
sleep 60
grep -c WEBLATE_ADMIN_PASSWORD ~/selfhost/weblate/.env || true
curl -sS http://localhost:8173/healthz/
```

Assert: the count prints `0` and the health endpoint answers `ok` again. Both must pass before
you report success.

## 8. First backup and restore

Two artifacts: a database dump with every project, string, translation and user, and a file
archive with the data directory, where the cloned repositories, the translation memory and the VCS
private key live.

```bash
cd ~/selfhost/weblate
docker compose exec -T postgres pg_dump -U weblate -d weblate | gzip > ~/selfhost/weblate/backups/weblate-db-$(date +%F).sql.gz
tar -C ~/selfhost/weblate -czf ~/selfhost/weblate/backups/weblate-files-$(date +%F).tar.gz data compose.yml .env
ls -lh ~/selfhost/weblate/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. On Linux a permission error from `tar` means the login
user is not uid 1000, and `sudo` in front of that line fixes it.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a synced
folder or a USB stick, and copy both there with `cp`. Assert: the user confirms both are there,
or say plainly that this install has no backup.

To restore: `cd ~/selfhost/weblate`, untar the file archive there first so compose.yml and .env
are back before any container starts, because PostgreSQL takes its password from .env the moment
it initialises an empty volume. Then `docker compose down -v`, the one place `-v` belongs,
`docker compose up -d postgres`, wait 30 seconds, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U weblate -d weblate`, then `docker compose up -d`.

## 9. Updating later

New versions are at https://github.com/WeblateOrg/weblate/releases and the matching four-part
image tag is on https://hub.docker.com/r/weblate/weblate. Back up first, then edit the image line
in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/weblate
docker compose pull
docker compose up -d
docker compose logs --tail 30 weblate
```

Watch that log until it settles, then re-run step 7's health check. Upstream supports direct
upgrades only within the current or previous calendar year.

## 10. What will probably go wrong

Memory, on a machine with plenty of it. My laptop had 9 GB free and the container still died
partway through its first start, with exit code `137` in `docker compose ps` and nothing useful in
the log. Docker Desktop had 2 GB assigned to its virtual machine, everything here runs inside that
machine, and upstream asks for 3 GB, so the migration was killed by a limit the host never felt.
Settings, Resources, memory to 4 GB, restart, `docker compose up -d`. Any later `137` is this.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not add a project or component, and do not generate the VCS key. Weblate makes that key at
  http://localhost:8173/manage/, under SSH keys, and pushing back needs its public half on the
  code host, on an account the user holds.
- Do not configure SMTP and do not set any `WEBLATE_SOCIAL_AUTH_`, `WEBLATE_SAML_`,
  `WEBLATE_AUTH_LDAP_` or `WEBLATE_MT_` variable. Each is an account somewhere else.
