You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Countly Lite 25.03.51, with the MongoDB it stores every event in, under
~/selfhost/countly, answering at http://localhost:8174.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Countly measures an app by having it post events to the address its SDK points at, and
here that is http://localhost:8174, which means "this computer" in any browser that reads it. It
measures software on this machine and nothing anyone else opens.

Detect the OS and measure the machine:

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2.

If `uname -m` printed `arm64` or `aarch64`, stop and tell the user why: upstream publishes the
Countly image for amd64 only, so an Apple Silicon Mac or an arm Linux box has nothing to pull.
This needs x86-64.

Countly plus MongoDB needs 4096 MB of RAM available and 20 GB free on the home disk, because the
image starts two Node processes with a 2048 MB heap ceiling each and MongoDB is a third beside
them. Every branch above prints free memory, and Docker Desktop's VM takes its share out of that.
Under either floor, print both numbers and stop.

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
mkdir -p ~/selfhost/countly/backups
ls -la ~/selfhost/countly
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: everything is a
document in MongoDB, which step 5 keeps in a Docker-managed volume, so no ownership fix is
needed.

## 4. Secrets

Two secrets, both read by the dashboard. `WEB_SESSION_SECRET` replaces the value upstream ships
in its sample config, published in the repository, and signs the session cookie.
`PASSWORDSECRET` is mixed into every password before hashing, so it has to exist before the first
account does. Generate both here, print neither, keep both out of your summary and any log.

```bash
umask 077
cat > ~/selfhost/countly/.env <<EOF
COUNTLY_CONFIG_FRONTEND_WEB_SESSION_SECRET=$(openssl rand -hex 32)
COUNTLY_CONFIG_FRONTEND_PASSWORDSECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/countly/.env
umask 022
ls -l ~/selfhost/countly/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same everywhere. On Windows the mode bits are advisory, and the real boundary is the user's own
Windows account. A dump restored without this file returns every account and no working
password.

## 5. compose.yml

```bash
cat > ~/selfhost/countly/compose.yml <<'EOF'
# Countly Lite · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream sources, not copied from a repository:
#   single-image build . https://github.com/Countly/countly-server/blob/25.03.51/Dockerfile-core
#   api config keys .... https://github.com/Countly/countly-server/blob/25.03.51/api/config.sample.js
#
# Every path is relative to ~/selfhost/countly/, so one file works on macOS,
# Linux and Windows. countly-core runs an nginx, the collection API on 3001 and
# the dashboard on 6001 inside one image under runit. The database is a named
# volume because MongoDB chowns /data/db to a uid Docker Desktop cannot grant on
# a Windows home-directory mount, and it is the only volume because fileStorage
# defaults to gridfs. Digests read on 2026-08-07; countly-core is amd64 only.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mongodb:
    image: mongo:8.0.28@sha256:98605bfa1bb2a15dd82109e1d78ad31527a9a744909fab4606076fa71a0ae515
    container_name: countly-db
    restart: unless-stopped
    command: ["mongod", "--bind_ip_all", "--quiet"]
    volumes:
      - countly-mongo:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "quit(db.adminCommand('ping').ok ? 0 : 1)"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 20s
    # No `ports:`, no user and no password, as upstream's own compose runs it.

  countly:
    image: countly/countly-core:25.03.51@sha256:e3d94902a3c4c609fdda3895ea4326693c5f30289cf2f6a84e35b9773a182c03
    container_name: countly
    restart: unless-stopped
    env_file: ./.env
    environment:
      # The empty middle component means "the API and the dashboard both".
      COUNTLY_CONFIG__MONGODB_HOST: mongodb
      COUNTLY_CONFIG__FILESTORAGE: gridfs
      # One Node heap per worker, so this is a ceiling, not a target.
      COUNTLY_CONFIG_API_API_WORKERS: "2"
      # Upstream ships an Intercom widget and reporting to stats.count.ly on.
      COUNTLY_CONFIG_FRONTEND_WEB_USE_INTERCOM: "false"
      COUNTLY_CONFIG_FRONTEND_WEB_TRACK: none
    ports:
      # Loopback only: no other device on the wifi can reach 8174.
      - "127.0.0.1:8174:80"
    depends_on:
      mongodb:
        condition: service_healthy

volumes:
  countly-mongo:
EOF
cd ~/selfhost/countly && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. There is no hostname to resolve, no public
name for a certificate to attest, and nothing published beyond loopback for a rule to close.
Browsers treat http://localhost as a secure context anyway, so pages needing crypto still work.

8174 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. MongoDB publishes no host port at all, which is what makes running it without a
password acceptable. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/countly/compose.yml
```

Assert: that prints `1`, the single published-port line `- "127.0.0.1:8174:80"`. Anything larger
means a second service publishes a port and this step has not held.

## 7. Start and verify

The image writes its plugin list and loads a city database into MongoDB before serving anything,
so the first `up` takes minutes.

```bash
cd ~/selfhost/countly
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8174/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8174/ping; echo
curl -sS http://localhost:8174/setup | grep -c 'data-localize="setup.ready"'
```

Assert all three and print what you got: the loop ends on `200`, the dashboard prints the bare
word `Success`, upstream's own health check, which answers only after it reaches MongoDB, and
the last prints `1`, meaning the registration screen is served and nobody owns this install yet. On a miss, stop, run `docker compose logs --tail 40 countly` and
`docker compose logs --tail 20 mongodb`, and name the cause: a database that never reports healthy
is step 5, a container still writing plugin files wants more time, and `port is already allocated`
means `lsof -nP -iTCP:8174 -sTCP:LISTEN` will name what holds 8174. A running container is not
success.

The first screen at http://localhost:8174/setup shows the heading `Your Countly server is ready!`
over a `Full Name` field and a `Create Account` button.

STOP: tell the user to open http://localhost:8174/setup, create their administrator account, then
finish the wizard after it by adding their first application, and wait. Do not continue until they
confirm both. No mail server here can reset that password, so it goes in their password manager as
they type it, and the wizard's analytics question reports to Countly, which compose.yml already
declines.

Once they confirm:

```bash
cd ~/selfhost/countly
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8174/setup
key=$(docker compose exec -T mongodb mongosh --quiet countly --eval 'const a=db.apps.findOne({}); print(a ? (a.key || (a.keys && a.keys[0] && a.keys[0].key) || "") : "")' | tr -d '\r\n')
curl -sS "http://localhost:8174/i?app_key=${key}&device_id=selfhost-check&begin_session=1"; echo
printf '<script src="http://localhost:8174/sdk/web/countly.min.js"></script>\n<script>Countly.init({ app_key: "%s", url: "http://localhost:8174" }); Countly.track_pageview();</script>\n' "$key"
```

Assert both. `/setup` prints `302`, upstream redirecting to the login page because the members
collection is no longer empty; a `200` means the install is still claimable, so stop. The event
call prints `{"result":"Success"}`, carried end to end into MongoDB. The last command prints the
snippet, with the user's own app key in it, for a page served from this machine. That key sits in
the source of every page it measures, so it is not a secret the way .env is. The dashboard is
empty until the snippet is on a page they open.

## 8. First backup and restore

Two artifacts. MongoDB holds everything, and `mongodump` with no database named takes all of it,
because file storage sits in a second database beside the first. The config archive rebuilds
the service.

```bash
cd ~/selfhost/countly
docker compose exec -T mongodb mongodump --quiet --archive --gzip > ~/selfhost/countly/backups/countly-db-$(date +%F).archive.gz
tar -C ~/selfhost/countly -czf ~/selfhost/countly/backups/countly-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/countly/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops: `mongodump` reads a
running database.

A backup on the same disk is not a backup, and on a laptop the disk and the machine die
together. Ask the user for a destination that leaves this computer, a folder a sync service
watches or a USB stick, and copy both there with `cp`. Assert: the user confirms both filenames
are listed there. If not, say plainly this install has no backup.

To restore, in this order. `cd ~/selfhost/countly`, untar the config archive there first so .env
is back before any container starts, because the password secret in it is mixed into every stored
password. Then `docker compose down -v`, the one place `-v` belongs because it drops the old
volume on purpose, `docker compose up -d mongodb`, wait 30 seconds for healthy, pipe `gunzip -c`
on the archive into `docker compose exec -T mongodb mongorestore --archive --gzip --drop`, then
`docker compose up -d` and re-run step 7's checks. That is the whole disaster plan.

## 9. Updating later

New versions are at https://github.com/Countly/countly-server/releases. Take both backups first,
then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/countly
docker compose pull
docker compose up -d
docker compose logs --tail 30 countly
```

Countly migrates its collections on the way up. Watch that log until it settles, then re-run
step 7's checks.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8174, and got a connection error that reads like
a lost database. It was not: Docker Desktop had not started with the session, so nothing listened
on 8174 and every event a page sent went nowhere, silently. `restart: unless-stopped` acts only
once the Docker daemon is up. Turn on its start-at-login
setting, and after a reboot run `cd ~/selfhost/countly && docker compose up -d` before deciding
anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8174 to 0.0.0.0 so a phone can reach it. That puts an unauthenticated
  collection API on every network this computer joins.
- Do not add `drill`, `funnels`, `cohorts` or `flows` to a `COUNTLY_PLUGINS` variable. Those
  directories are not in the repository this image is built from.
