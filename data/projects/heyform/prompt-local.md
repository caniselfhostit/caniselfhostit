You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install HeyForm v3.0.0, with the MongoDB and Valkey it needs, under ~/selfhost/heyform,
answering at http://localhost:8170.

## 1. Preflight

Say this before step 2 runs; it decides whether the user wants this install at all. Every form
is published at http://localhost:8170/form/ and an id, and that address means "this computer"
wherever it is read, so a link sent to a colleague, or opened on their own phone, reaches
nothing. They get a builder and an inbox they fill in themselves.

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
ID and codename print next, for step 2. This needs 2048 MB of RAM available and 10 GB free on
the home disk; all three images publish amd64 and arm64. On macOS and Windows that figure is
the host's, and Docker Desktop takes its share out of it. If RAM is under 2048 MB or disk under
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
mkdir -p ~/selfhost/heyform/backups ~/selfhost/heyform/uploads
ls -la ~/selfhost/heyform
```

Assert: `ls -la` shows `backups` and `uploads`, owned by the user. There is no database folder:
step 5 keeps both databases in volumes Docker manages, because the mongo image chowns its data
directory to a uid a home bind mount cannot grant on Windows. `uploads` holds what respondents
attach, which the dump misses.

## 4. Secrets

Four secrets: the session key, the form-token key, the MongoDB password and the Valkey
password. Generate all four here, print none, and keep them out of your summary and out of any
log line.

```bash
umask 077
cat > ~/selfhost/heyform/.env <<EOF
SESSION_KEY=$(openssl rand -hex 32)
FORM_ENCRYPTION_KEY=$(openssl rand -hex 32)
MONGO_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/heyform/.env
umask 022
ls -l ~/selfhost/heyform/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same everywhere. The
file does two jobs: Compose fills the `${MONGO_PASSWORD}` and `${REDIS_PASSWORD}` slots in step
5 from it, and HeyForm reads it as its environment. `SESSION_KEY` encrypts the login cookie and
`FORM_ENCRYPTION_KEY` the token a live form page carries, so rotating either signs the user
out. On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary
is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/heyform/compose.yml <<'EOF'
# HeyForm · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   self-hosting ... https://docs.heyform.net/open-source/self-hosting
#   image and port . https://github.com/heyform/heyform/blob/v3.0.0/Dockerfile
#   variables ...... https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/environments/index.ts
#   health ......... https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/controller/health.controller.ts
#
# Three services on the computer you are sitting at. Every path is relative to
# ~/selfhost/heyform/, so one file works on macOS, Linux and Windows. mongo 7.0
# and Valkey stand in for upstream's percona-server-mongodb:4.4 and
# eqalpha/keydb: 4.4 left support 2024-02-29, KeyDB ships no multi-arch tag.
# Both databases are named volumes, because the mongo image chowns /data/db to a
# uid Docker Desktop cannot grant on a home bind mount. Digests read 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mongo:
    image: mongo:7.0.39@sha256:35a5926f71f8b6cb19206bee928c5a85f241a8be99f20c81abe35ae78a73415d
    restart: unless-stopped
    command: ["mongod", "--bind_ip_all", "--quiet"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: heyform
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD}
    volumes:
      - heyform-mongo:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "quit(db.adminCommand({ping:1}).ok === 1 ? 0 : 1)"]
      interval: 10s
      retries: 30
      start_period: 20s
    # No `ports:` on either database: both stay on the compose network.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    restart: unless-stopped
    environment:
      VALKEY_PASSWORD: ${REDIS_PASSWORD}
    command: ["sh", "-c", "exec valkey-server --appendonly yes --requirepass \"$$VALKEY_PASSWORD\""]
    volumes:
      - heyform-valkey:/data
    healthcheck:
      test: ["CMD-SHELL", 'valkey-cli -a "$$VALKEY_PASSWORD" --no-auth-warning ping | grep -q PONG']
      interval: 10s
      retries: 30

  heyform:
    image: heyform/community-edition:v3.0.0@sha256:27507032eb39ddb23dcadb4490ad383a104d1a32a6b368ad0f2e78538a187877
    restart: unless-stopped
    env_file: ./.env
    environment:
      APP_HOMEPAGE_URL: http://localhost:8170
      # authSource=admin: the credential is the root user mongo makes there.
      MONGO_URI: mongodb://mongo:27017/heyform?authSource=admin
      MONGO_USER: heyform
      REDIS_HOST: valkey
      REDIS_PORT: 6379
      ENABLE_GOOGLE_FONTS: "false"
    volumes:
      - ./uploads:/app/packages/server/static/upload
    ports:
      # Loopback only: no other device on the wifi can reach 8170.
      - "127.0.0.1:8170:9157"
    depends_on:
      mongo:
        condition: service_healthy
      valkey:
        condition: service_healthy

volumes:
  heyform-mongo:
  heyform-valkey:
EOF
cd ~/selfhost/heyform && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port, two named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, nothing public to
certify, nothing published past loopback. Browsers treat http://localhost as a secure context,
so pages needing crypto work.

8170 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. For a form builder that is the trade, because nobody else can answer the forms
either. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/heyform/compose.yml
```

Assert: `1`, the published-port line `- "127.0.0.1:8170:9157"`. Neither database publishes a
host port, so neither can appear.

## 7. Start and verify

```bash
cd ~/selfhost/heyform
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8170/health/ready); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8170/health/ready
curl -sS http://localhost:8170/login | grep -o '<title>HeyForm</title>'
```

Assert all three, and print what you received for each. The loop ends printing `200`. The
readiness body contains `"checks":{"mongo":"up","redis":"up"}`, the only line proving both
databases answered rather than one. The grep prints `<title>HeyForm</title>`. If any misses,
stop, run `docker compose logs --tail 40 heyform` and `docker compose logs --tail 20 mongo`,
and name the cause: `"mongo":"down"` points at step 4, where a `.env` rewritten after the
volume existed leaves the old password in the database. `port is already allocated` means
something else holds 8170. A running container is not success.

The first screen at http://localhost:8170/login is a sign-in form with an `Email address` field
and a `create an account` link under the heading.

STOP: tell the user to open http://localhost:8170/sign-up now, create the account with a real
email address, and confirm once they are signed in on the workspace screen.
Do not continue until they confirm. HeyForm refuses disposable-address domains, and no mail
arrives: there is no mail server, and the account works without one.

Once they confirm, close registration, open until now to anything that reaches 8170:

```bash
cd ~/selfhost/heyform
echo 'APP_DISABLE_REGISTRATION=true' >> ~/selfhost/heyform/.env
docker compose up -d --force-recreate heyform
sleep 20
curl -sS http://localhost:8170/api/config | grep -o '"appDisableRegistration":true'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8170/sign-up
```

Assert: the grep prints `"appDisableRegistration":true` and the curl prints `302`. The sign-up
mutation refuses too, so this is not a hidden button. Then have the user reload the login page
and confirm the `create an account` link is gone.

## 8. First backup and restore

Two artifacts: a dump with every form, submission and the account, and a config archive with
what rebuilds the service around it.

```bash
cd ~/selfhost/heyform
docker compose exec -T mongo sh -c 'mongodump --quiet --archive --gzip --db=heyform -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > ~/selfhost/heyform/backups/heyform-db-$(date +%F).archive.gz
tar -C ~/selfhost/heyform -czf ~/selfhost/heyform/backups/heyform-config-$(date +%F).tar.gz compose.yml .env uploads
ls -lh ~/selfhost/heyform/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped, and the
credentials stay in the container.

Both archives sit on the same disk as the data, which is not a backup: on a laptop the disk and
the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`. Assert: the user confirms both filenames
are listed there, or say plainly this install has no backup.

To restore: untar the config archive into ~/selfhost/heyform first, so compose.yml and .env are
back before any container starts: mongo reads its root password from .env the moment it
initialises an empty volume. Then `docker compose down -v`, the one place `-v` belongs,
`docker compose up -d mongo`, wait 30 seconds for healthy, then:

```bash
gunzip -c ~/selfhost/heyform/backups/heyform-db-*.archive.gz | docker compose exec -T mongo sh -c 'mongorestore --archive --drop -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
```

Then `docker compose up -d` and re-run step 7's check. Every answer is in that one dump.

## 9. Updating later

New versions are at https://github.com/heyform/heyform/releases. Take both backups, then edit
the image line in ~/selfhost/heyform/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/heyform
docker compose pull
docker compose up -d
docker compose logs --tail 30 heyform
```

Watch that log until it settles, then re-run step 7's asserts. Leave the mongo line alone.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8170, and got a connection refused that read
like a lost database. It was not: Docker Desktop had not started with the session, so nothing
was listening on 8170. `restart: unless-stopped` acts only once the Docker daemon is up. Turn
on start-at-login, then after a reboot run `cd ~/selfhost/heyform && docker compose up -d`
before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `APP_HOMEPAGE_URL` to this machine's LAN address and do not rebind 8170 to
  0.0.0.0 so a phone can reach it. That puts a sign-up page on every network the user joins.
- Do not configure SMTP, and do not set `GOOGLE_LOGIN_CLIENT_ID`, the Apple login variables,
  `OPENAI_API_KEY`, `AKISMET_KEY`, the reCAPTCHA keys or the `S3_` variables. Each is an
  account somewhere else, and the builder, the logic and storage work without them.
