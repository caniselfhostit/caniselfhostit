You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install solidtime 0.19.1 under ~/selfhost/solidtime, answering at http://localhost:8184.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. solidtime is built around organisations, members and billable rates, and this copy answers
at http://localhost:8184 and nowhere else: no colleague can be invited in, no phone can reach
it, and it is gone the moment the lid closes. What is left is a real tracker for their own
hours.

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
distribution ID and codename print next, for step 2. solidtime needs 2048 MB of RAM available
and 10 GB free on the home disk: three PHP containers plus a PostgreSQL, both images amd64 and
arm64. If either is under its floor, print both and stop.

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
mkdir -p ~/selfhost/solidtime/storage ~/selfhost/solidtime/backups
if [ "$(uname -s)" = "Linux" ]; then sudo chown -R 1000:1000 ~/selfhost/solidtime/storage; fi
ls -la ~/selfhost/solidtime
```

Assert: `ls -la` shows `storage` and `backups`. The image runs as uid 1000, so on Linux that
directory has to belong to 1000 or no export can be written; on macOS and Windows the chown is
skipped because Docker Desktop maps ownership.

## 4. Secrets

Four secrets end up here. `APP_KEY` for session cookies, the Passport private key that signs API
tokens and the PostgreSQL password are written now; step 7 has the application generate the
account password. The image mints the first two, so the third uses `openssl`. Print none of
them: the redirect below keeps the minted keys off the terminal.

```bash
umask 077
docker run --rm solidtime/solidtime:0.19.1@sha256:419ae59a806bcd6b15e9b637b5cee4800f7eb8f4941e20f4c5416d71acd5f1dd php artisan self-host:generate-keys > ~/selfhost/solidtime/.env
grep -c -E '^(APP_KEY|PASSPORT_PRIVATE_KEY|PASSPORT_PUBLIC_KEY)=' ~/selfhost/solidtime/.env
cat >> ~/selfhost/solidtime/.env <<EOF
APP_ENV="production"
APP_DEBUG="false"
APP_URL="http://localhost:8184"
APP_FORCE_HTTPS="false"
APP_ENABLE_REGISTRATION="false"
LOG_CHANNEL="stderr"
LOG_LEVEL="info"
DB_CONNECTION="pgsql"
DB_HOST="postgres"
DB_DATABASE="solidtime"
DB_USERNAME="solidtime"
DB_PASSWORD="$(openssl rand -hex 32)"
QUEUE_CONNECTION="database"
MAIL_MAILER="log"
SCHEDULING_TASK_SELF_HOSTING_CHECK_FOR_UPDATE="false"
SCHEDULING_TASK_SELF_HOSTING_TELEMETRY="false"
EOF
chmod 600 ~/selfhost/solidtime/.env
umask 022
ls -l ~/selfhost/solidtime/.env
```

Assert both: `grep -c` prints `3` and the file is mode `-rw-------`. Anything but `3` means the
image wrote something unexpected into it, so delete the file and run the block again. On Windows
those mode bits are advisory; the real boundary is the user's own account.

`QUEUE_CONNECTION` is required because Laravel defaults to `sync` and the queue container drains
that table. `MAIL_MAILER="log"` puts reset links in the log instead of throwing. The last two
are upstream defaults, off here because both post this instance's URL to app.solidtime.io twice
a day and telemetry adds object counts.

## 5. compose.yml

```bash
cat > ~/selfhost/solidtime/compose.yml <<'EOF'
# solidtime · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream self-hosting documentation and the packaging
# at the pinned tag:
#   docker guide ... https://docs.solidtime.io/self-hosting/guides/docker
#   configuration .. https://docs.solidtime.io/self-hosting/configuration
#   image build .... https://github.com/solidtime-io/solidtime/blob/v0.19.1/docker/prod/Dockerfile
#
# Four services from ~/selfhost/solidtime/, three of them the same image:
# CONTAINER_MODE picks HTTP, scheduler or queue worker. Gotenberg, upstream's
# PDF renderer, is left out. The database is a named volume because PostgreSQL
# chowns its data directory to a uid Docker Desktop cannot grant on a Windows
# home bind mount; ./storage stays a bind mount. Digests read 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

x-solidtime: &solidtime
  image: solidtime/solidtime:0.19.1@sha256:419ae59a806bcd6b15e9b637b5cee4800f7eb8f4941e20f4c5416d71acd5f1dd
  restart: unless-stopped
  # The image copies the application in as uid 1000 and runs as it.
  user: "1000:1000"
  env_file: .env
  volumes:
    # framework cache, shared; then the half worth keeping: exports/imports.
    - solidtime-storage:/var/www/html/storage
    - ./storage:/var/www/html/storage/app
  depends_on:
    postgres:
      condition: service_healthy

services:
  postgres:
    image: postgres:17.11-alpine@sha256:5d61573b31c206ae538c85893edeb6e320e1a9ffd838c0f9dca927fb6f765fa4
    container_name: solidtime-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: solidtime
      POSTGRES_USER: solidtime
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - solidtime-postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U solidtime -d solidtime"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other containers.

  solidtime:
    <<: *solidtime
    container_name: solidtime
    environment:
      CONTAINER_MODE: http
    ports:
      # Loopback only: no other device on the wifi can reach 8184.
      - "127.0.0.1:8184:8000"
    healthcheck:
      test: ["CMD", "curl", "--fail", "http://localhost:8000/health-check/up"]
      start_period: 60s
      interval: 15s
      retries: 10

  scheduler:
    <<: *solidtime
    environment:
      CONTAINER_MODE: scheduler
    healthcheck:
      # Ships with the image: asks supervisord if its process runs.
      test: ["CMD", "healthcheck"]
      start_period: 60s
      interval: 30s
      retries: 5

  queue:
    <<: *solidtime
    environment:
      CONTAINER_MODE: worker
      # Worker mode refuses to start without this.
      WORKER_COMMAND: "php /var/www/html/artisan queue:work"
    healthcheck:
      test: ["CMD", "healthcheck"]
      start_period: 60s
      interval: 30s
      retries: 5

volumes:
  solidtime-postgres:
  solidtime-storage:
EOF
cd ~/selfhost/solidtime && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Do not delete `queue`: every saved time entry queues a job
recalculating spent time on its project and task, so without a worker the totals never move.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. A certificate
attests a public name and this has none; browsers treat http://localhost as a secure context
anyway, so the session cookies behave, and nothing is published beyond loopback.

8184 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone on the
internet. For a personal timesheet that is a fair trade. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/solidtime/compose.yml
```

Assert: that prints `1`, the single published port. `0` means step 5 did not land; more than `1`
means a second published port appeared, and the install stops.

## 7. Start and verify

The health endpoint answers before the schema exists, because upstream wrote it to touch neither
the database nor the cache, and sessions live in a table, so the login page is a 500 until
migrate has run.

```bash
cd ~/selfhost/solidtime
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8184/health-check/up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8184/health-check/up; echo
docker compose exec -T solidtime php artisan migrate --force
curl -sS http://localhost:8184/login | grep -o '<title inertia>[^<]*</title>'
```

Assert all four and print each: the loop ends on `200`, the health body is `{"success":true}`,
the migration prints migrations each ending `DONE` with no exception, and the title prints
`<title inertia>solidtime</title>`. If any misses, stop and run
`docker compose logs --tail 40 solidtime`. `port is already allocated` means something else holds
8184: find it with `lsof -nP -iTCP:8184 -sTCP:LISTEN` and stop until the user frees it. A running
container is not success.

Registration is off, so the only account is made on the command line. It prints a generated
password, so the output goes to a file. Put the user's display name and email address in place
of the two quoted values; that address identifies the account, nothing is sent to it.

```bash
cd ~/selfhost/solidtime
umask 077
docker compose exec -T solidtime php artisan admin:user:create "Your Name" "you@example.com" --verify-email > ~/selfhost/solidtime/first-account.txt
chmod 600 ~/selfhost/solidtime/first-account.txt
umask 022
grep -c '^Password: ' ~/selfhost/solidtime/first-account.txt
```

Assert: the count prints `1`. `--verify-email` marks the address verified without sending mail,
which is what the account needs here.

STOP: tell the user to read their password with
`grep '^Password: ' ~/selfhost/solidtime/first-account.txt`, put it in their password manager,
sign in at http://localhost:8184, and confirm the dashboard shows a `This Week` card.
Do not continue until they confirm. The next block destroys that file.

Once they confirm, close the account door and prove it is closed:

```bash
cd ~/selfhost/solidtime
rm -f ~/selfhost/solidtime/first-account.txt
docker compose exec -T solidtime printenv APP_ENABLE_REGISTRATION
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8184/api/v1/users/me
```

Assert both and print each. `printenv` prints `false`, the application's own answer: its sign-up
action refuses to create a user while that is off, so the register route cannot mint an account.
The API call prints `401`: nothing reads time entries without a token.

## 8. First backup and restore

Two artifacts: a dump of the database holding every project, client, rate and time entry, and an
archive of compose.yml, .env and `storage`.

```bash
cd ~/selfhost/solidtime
docker compose exec -T postgres pg_dump -U solidtime -d solidtime | gzip > ~/selfhost/solidtime/backups/solidtime-db-$(date +%F).sql.gz
tar -C ~/selfhost/solidtime -czf ~/selfhost/solidtime/backups/solidtime-files-$(date +%F).tar.gz compose.yml .env storage
ls -lh ~/selfhost/solidtime/backups/
```

Assert: both exist and both are non-empty, and print both sizes. Nothing goes offline: `pg_dump`
snapshots a running database consistently.

Those files are on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a synced folder or a USB
stick, and copy both there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both names are listed there.

To restore, in this order. Untar the file archive into ~/selfhost/solidtime first, so `.env` is
back before any container starts: PostgreSQL takes its password from it the moment it
initialises an empty data directory. Then `docker compose down -v`, then
`docker compose up -d postgres`, wait for healthy, then
`gunzip -c ~/selfhost/solidtime/backups/solidtime-db-<date>.sql.gz | docker compose exec -T postgres psql -U solidtime -d solidtime`,
then `docker compose up -d` and re-run step 7's checks. `APP_KEY` is in that `.env`, so a
database restored without it signs everyone out for good.

## 9. Updating later

New versions are at https://github.com/solidtime-io/solidtime/releases. Say the cadence, it is
the load-bearing fact here: the first tag was June 2024, this is still a 0.x line, and it has
shipped roughly two releases a month through 2026, with 0.19.1 landing on 7 August 2026. Read
the notes, back up, then edit the `image:` line:

```bash
cd ~/selfhost/solidtime
docker compose pull
docker compose up -d
docker compose exec -T solidtime php artisan migrate --force
docker compose logs --tail 30 solidtime
```

The migration is separate on purpose: upstream's `AUTO_DB_MIGRATE` runs it at container start,
and leaving it unset means an image pull can never rewrite the schema before there is a dump of
the old one. Re-run step 7's checks first.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8184 out of habit, and got nothing at all. Docker Desktop
had not started, so none of the four containers were running, and a tracker that is not running
is a day of hours reconstructed from memory on Friday. Turn on Docker Desktop's start-at-login
setting, and after any reboot run `cd ~/selfhost/solidtime && docker compose up -d` before you
trust a timer.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP. With `MAIL_MAILER="log"` a reset link is read out of
  `docker compose logs solidtime`, which is enough for one person on one machine.
- Do not add the Gotenberg container. It only makes reports export as PDF; CSV, XLSX and ODS
  work without it.
- Do not turn `APP_ENABLE_REGISTRATION` back on.
