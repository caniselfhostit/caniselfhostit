You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Kener 4.1.2 and the Redis its scheduler needs under ~/selfhost/kener, answering at
http://localhost:8179.

## 1. Preflight

Say this to the user before step 2, because it decides whether they want this install at all.
A status page exists so other people can read it, and this one answers at
http://localhost:8179: this computer and nothing else, not a colleague, not their own phone.
Checks also run only while this machine is awake, and a closed laptop records nothing. What
they get is a private dashboard over their own sites.

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
distribution ID and codename print next, for step 2. Kener plus Redis needs 1024 MB of RAM
available and 5 GB free on the home disk, and both images publish amd64 and arm64. On macOS and
Windows the memory figure is the host's, and Docker Desktop takes its allocation out of that.
If either floor is missed, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/kener/database ~/selfhost/kener/backups
ls -la ~/selfhost/kener
```

On Linux only, `./database` is a real directory and the image runs as uid 1000, so hand it
over:

```bash
sudo chown -R 1000:1000 ~/selfhost/kener/database
```

Do not run that on macOS or Windows: Docker Desktop rewrites ownership across its file share,
so the container already sees itself as the owner. Assert: `ls -la` shows `database` and
`backups`, and on Linux `database` belongs to `1000`. Keep `database` on the local disk and
out of any synced folder: `kener.sqlite.db` needs real POSIX file locks.

## 4. Secrets

One secret, `KENER_SECRET_KEY`. Upstream documents it as the key that signs the session tokens
and encrypts stored credentials, and documents `openssl rand -base64 32` as the way to make
one. Git Bash ships openssl, so this runs the same on all three systems. Generate it here,
print it nowhere, and keep it out of your summary and any log.

`ORIGIN` is in the same file and is not a secret: it is what SvelteKit compares against on
every form post, http://localhost:8179, with no trailing slash.

```bash
umask 077
cat > ~/selfhost/kener/.env <<EOF
ORIGIN=http://localhost:8179
TZ=UTC
KENER_SECRET_KEY=$(openssl rand -base64 32)
EOF
chmod 600 ~/selfhost/kener/.env
umask 022
ls -l ~/selfhost/kener/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user the key is in
~/selfhost/kener/.env, readable with `grep KENER_SECRET_KEY ~/selfhost/kener/.env`, and that
changing it signs everyone out and makes anything Kener encrypted under it unreadable, so it
belongs in their password manager today. On Windows those mode bits are advisory and the real
boundary is their own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/kener/compose.yml <<'EOF'
# Kener · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   deployment ......... https://kener.ing/docs/v4/setup/deployment
#   environment ........ https://kener.ing/docs/v4/setup/environment-variables
#   database ........... https://kener.ing/docs/v4/setup/database-setup
#   image build ........ https://github.com/rajnandan1/kener/blob/v4.1.2/Dockerfile
#
# Two services, on the computer you are sitting at, every path relative to
# ~/selfhost/kener/ so one file works on macOS, Linux and Windows. Redis is not
# optional in v4: upstream calls it required for the queues, the cache and the
# scheduler, and its /data is a named volume because that image chowns its data
# directory to its own uid, which a Windows bind mount cannot allow. The
# database stays a bind mount and DATABASE_URL is unset, so upstream defaults
# to SQLite there, under the node user uid 1000, hence step 3's Linux-only
# chown. Digests read on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: kener-redis
    restart: unless-stopped
    volumes:
      # Queue state only: monitors and results are in the SQLite file below.
      - kener-redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    # No `ports:` at all: 6379 is reachable only from the other container.

  kener:
    image: ghcr.io/rajnandan1/kener:v4.1.2@sha256:239ab635b900b3fe0a4e22f5599f77525211d1b7a25b8fcf3d173936ddacc1cc
    container_name: kener
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Redis is on the compose network only, so this carries no credential.
      REDIS_URL: redis://redis:6379
      NODE_ENV: production
    volumes:
      # kener.sqlite.db: every monitor, incident, page, user and result.
      - ./database:/app/database
    ports:
      # Loopback only: no other device on the wifi can reach 8179.
      - "127.0.0.1:8179:3000"
    depends_on:
      redis:
        condition: service_healthy

volumes:
  kener-redis-data:
EOF
cd ~/selfhost/kener && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no
hostname to resolve, a certificate attests a public name and nothing here has one, and browsers
treat http://localhost as a secure context anyway. Nothing is published past loopback, so no
port needs closing.

8179 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, nobody on the
internet. For most apps that is a fair trade; for a status page it is the trade, because being
readable by somebody else is what this software exists to do. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/kener/compose.yml
```

Assert: that prints `1`, the one published-port line `- "127.0.0.1:8179:3000"`. Redis publishes
no host port. The checks still reach the internet: loopback governs what arrives, not what a
container can call.

## 7. Start and verify

Kener runs migrations and a seed on the way up, so the first boot writes a schema and a starter
page before answering. Use the loop, not a fixed sleep.

```bash
cd ~/selfhost/kener
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' 'http://localhost:8179/healthcheck?strict=1'); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8179/healthcheck; echo
curl -sSL http://localhost:8179/ | grep -c 'Service Status'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8179/api/v1/monitors
curl -sSL http://localhost:8179/account/signin | grep -c 'Create Admin Account'
```

Assert all five, and print what you received for each. The loop ends on `200`, and it asks
with `?strict=1` on purpose: upstream answers `200` from `/healthcheck` even when a dependency
is down, and only the strict form turns that into `503`. The plain call then prints
`{"status":"ok","db":true,"redis":true}`, and all three fields matter. The third prints a
number greater than `0`, because `Service Status` is the heading the seeded page renders. The
API call prints `401`, upstream's answer to a request with no bearer token. The last prints a
number greater than `0`, because with no users yet the sign-in page is a `Create Admin Account`
form. If any of the five misses, stop, run `docker compose logs --tail 40 kener`, then
`docker compose logs --tail 20 redis`: a Redis that never reports healthy holds the app in
`depends_on`. If `port is already allocated` came back, find what holds 8179
(`lsof -nP -iTCP:8179 -sTCP:LISTEN`, `ss -ltnp | grep 8179` on Linux,
`netstat -ano | findstr :8179` on Windows) and stop until the user frees it: 8179 is inside
`ORIGIN`. A running container is not success.

STOP: tell the user to open http://localhost:8179/account/signin, fill in a name, an email
address and a password to create the administrator account, and save that password in their
password manager. Do not continue until they confirm.

Once they confirm, prove the setup form is gone:

```bash
curl -sSL http://localhost:8179/account/signin | grep -c 'Create Admin Account'
curl -sSL http://localhost:8179/account/signin | grep -c 'Sign In'
```

Assert: the first prints `0`, the second a number greater than `0`. Upstream's signup action
refuses once a user exists, so that page is a login form from here on.

## 8. First backup and restore

One archive: the SQLite database, the environment file and the compose file. Redis is not in
it, because it holds only queue state that rebuilds itself.

```bash
cd ~/selfhost/kener
docker compose stop
tar -C ~/selfhost/kener -czf ~/selfhost/kener/backups/kener-$(date +%F).tar.gz database .env compose.yml
docker compose start
ls -lh ~/selfhost/kener/backups/
```

Assert: the archive exists and is non-empty. Print its size. The containers stop for a few
seconds on purpose, because a SQLite file copied mid-write is not a backup.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB
stick, and copy it there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms the filename is listed there. If they have nowhere to
put it, say plainly that this install has no backup.

To restore: `cd ~/selfhost/kener`, `docker compose down`, `rm -rf database`, untar the archive
there, then `docker compose up -d`. `database/kener.sqlite.db` is their monitors, their
incidents and their account; `.env` is the key that decrypts what Kener stored under it.

## 9. Updating later

New versions are at https://github.com/rajnandan1/kener/releases, and the release tag is the
image tag. Take a backup first, then edit the image line in ~/selfhost/kener/compose.yml to the
new tag and its digest:

```bash
cd ~/selfhost/kener
docker compose pull
docker compose up -d
docker compose logs --tail 30 kener
```

Kener migrates on the way up, so watch that log until it settles, then re-run step 7's health
check and the `Service Status` grep before calling the update done.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8179 out of habit, and got a connection error that read
like a lost database. It was not. Docker Desktop had not started with the session, so nothing
was listening on 8179 and no check had run since the reboot: `restart: unless-stopped` acts
only once the Docker daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/kener && docker compose up -d` before concluding anything broke. The quieter
version: uptime is worked out from the results that exist, so hours when this machine slept
leave no failed result and read as clean.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8179 to 0.0.0.0 and do not point `ORIGIN` at this machine's LAN address. That
  publishes a page listing every URL the user monitors, plus its sign-in form, on every network
  this machine joins.
- Do not set `DATABASE_URL` and do not add a Postgres or MySQL service. SQLite is why this is
  one folder to copy.
- Do not configure SMTP, `RESEND_API_KEY`, or any alerting provider. Each is an account or key
  somewhere else.
