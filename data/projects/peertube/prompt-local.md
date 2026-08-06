You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install PeerTube 8.2.4, with the PostgreSQL and Redis it needs, under ~/selfhost/peertube,
answering at http://localhost:8124.

## 1. Preflight

Say this before step 2 runs; it decides whether the user wants this at all. PeerTube is a
federated video platform and here it federates with nothing: it answers only at
http://localhost:8124, which means "this computer" wherever it is read. Nobody they send a link
to can open it and their own phone cannot play it. They get a video library on one machine.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. This wants 2048 MB of RAM available and
40 GB free on the home disk before a single video; upstream's own floor is 1.5 GB for the
application alone. All three images are multi-arch. Under either floor, print both and stop. 40 GB
is a floor, not a budget: every upload is re-encoded and kept as HLS segments beside it.

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
mkdir -p ~/selfhost/peertube/data ~/selfhost/peertube/config ~/selfhost/peertube/redis ~/selfhost/peertube/backups
ls -la ~/selfhost/peertube
```

Assert: four folders owned by the user. No ownership fix runs on any of the three systems: the
container starts as root, chowns /data and /config to its own account and drops to it. The
database lives in a Docker volume, not in this tree.

## 4. Secrets

Three: the PostgreSQL password, the key PeerTube signs tokens with, and the password its built-in
`root` account is created with. Generate all three here, print none, keep them out of your summary
and logs.

```bash
umask 077
cat > ~/selfhost/peertube/.env <<EOF
PEERTUBE_WEBSERVER_HOSTNAME=localhost
PEERTUBE_ADMIN_EMAIL=admin@example.com
POSTGRES_PASSWORD=$(openssl rand -hex 32)
PEERTUBE_SECRET=$(openssl rand -hex 32)
PT_INITIAL_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/peertube/.env
umask 022
ls -l ~/selfhost/peertube/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run the same on all three. Hex not
base64: Compose reads this file for interpolation and a `$` in a value would expand. The
administrator address is a reserved documentation domain; this install sends no mail.

The third line matters most: left unset, PeerTube invents the root password and the documented
way to learn it is to grep the container log, putting a live credential in this transcript. Tell
the user it is in ~/selfhost/peertube/.env, read with
`grep PT_INITIAL_ROOT_PASSWORD ~/selfhost/peertube/.env`, and belongs in their password manager
now. On Windows those mode bits are advisory: their account is the boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/peertube/compose.yml <<'EOF'
# PeerTube · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream docs, not copied from a repository:
#   https://docs.joinpeertube.org/install/docker
#   https://github.com/Chocobozzz/PeerTube/tree/v8.2.4/support/docker/production
#
# Three services, every path relative to ~/selfhost/peertube/ so one file
# works on macOS, Linux and Windows. Upstream's nginx, certbot, reload-loop
# and postfix containers have no job here: nothing is published past loopback
# and there is nothing to certify. The database is a named volume because
# PostgreSQL chowns its data directory to a uid a home-directory bind mount
# cannot grant on Windows. PeerTube connects as the superuser that image
# creates, for CREATE EXTENSION pg_trgm and unaccent. Digests 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    restart: unless-stopped
    environment:
      POSTGRES_DB: peertube
      POSTGRES_USER: peertube
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - peertube-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U peertube -d peertube"]
      interval: 10s
      retries: 18
    # No `ports:`: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 18

  peertube:
    image: chocobozzz/peertube:v8.2.4@sha256:fee7ff44b9705401d8c228227e770257f088c3f3cb056746493888344a5a0324
    restart: unless-stopped
    env_file: ./.env
    environment:
      PEERTUBE_DB_HOSTNAME: postgres
      PEERTUBE_DB_USERNAME: peertube
      PEERTUBE_DB_PASSWORD: ${POSTGRES_PASSWORD}
      PEERTUBE_DB_SSL: "false"
      PEERTUBE_REDIS_HOSTNAME: redis
      # Nothing terminates TLS, so PeerTube's links say http.
      PEERTUBE_WEBSERVER_HTTPS: "false"
      PEERTUBE_WEBSERVER_PORT: "8124"
      # Closed registration, stated rather than assumed. No proxy sits in
      # front of this, so no trust_proxy override either.
      PEERTUBE_SIGNUP_ENABLED: "false"
      # Federation off: nobody outside can resolve this name.
      PEERTUBE_FEDERATION_ENABLED: "false"
      PEERTUBE_LIVE_ENABLED: "false"
    volumes:
      # The folder that grows; a bind mount, so Finder can see it.
      - ./data:/data
      - ./config:/config
    ports:
      # Loopback only: no other device on the wifi can reach 8124.
      - "127.0.0.1:8124:9000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  peertube-pgdata:
EOF
cd ~/selfhost/peertube && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Three services, one published port, one volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision: there is no hostname
to resolve, a certificate attests a public name nothing here has, and browsers treat
http://localhost as a secure context anyway, so the player and the uploader work. 8124 is bound
to 127.0.0.1: not the phone, not a laptop on the wifi, not anyone on the internet. That is the
trade here, not a defect. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/peertube/compose.yml
```

Assert: one line, `- "127.0.0.1:8124:9000"`. The other two publish no host port.

## 7. Start and verify

PeerTube runs its migrations, creates `root` from `PT_INITIAL_ROOT_PASSWORD` and builds its
storage tree on the way up; on a cold pull, several minutes.

```bash
cd ~/selfhost/peertube
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8124/api/v1/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8124/api/v1/ping; echo
curl -sS http://localhost:8124/api/v1/config | grep -o '"signup":{"allowed":false'
curl -sS http://localhost:8124/api/v1/accounts/root | grep -o '"name":"root"'
curl -sS http://localhost:8124/login | grep -o 'og:platform" content="PeerTube"'
```

Assert all five, printing what you got: the loop ends on `200`; ping answers `pong`; the third
prints `"signup":{"allowed":false`, the security assert here; the fourth prints `"name":"root"`;
the fifth prints `og:platform" content="PeerTube"`. On any miss, stop, run
`docker compose logs --tail 40 peertube` and `docker compose logs --tail 20 postgres` and name
the cause: a database never healthy points at step 4, where an empty `POSTGRES_PASSWORD` leaves
PostgreSQL refusing to start. On `port is already allocated`, find what holds 8124 and wait until
it is free. A running container is not success.

The first screen at http://localhost:8124/login shows the heading `Login on PeerTube` over a
`Username or email address` box, a `Password` box and a `Login` button.

STOP: tell the user to read their password with
`grep PT_INITIAL_ROOT_PASSWORD ~/selfhost/peertube/.env`, save it, sign in at
http://localhost:8124/login as `root`, upload one short video at
http://localhost:8124/videos/upload, and wait. Do not continue until they confirm it plays back:
a file in, ffmpeg to HLS, back out. Step 10 says how long.

## 8. First backup and restore

Two artifacts: a database dump with the accounts, video records, comments and views, and a config
archive with what rebuilds the service around them. The videos are in neither: that folder runs to
tens of gigabytes and needs its own copy.

```bash
cd ~/selfhost/peertube
docker compose exec -T postgres pg_dump -U peertube -d peertube | gzip > ~/selfhost/peertube/backups/peertube-db-$(date +%F).sql.gz
tar -C ~/selfhost/peertube -czf ~/selfhost/peertube/backups/peertube-config-$(date +%F).tar.gz compose.yml .env config
ls -lh ~/selfhost/peertube/backups/
```

Assert: both exist, both non-empty, print both sizes. Nothing stops: `pg_dump` is consistent on a
running database.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`.
Assert: the user confirms both filenames are there. If not, say plainly that this install has no
backup.

To restore, in this order. `cd ~/selfhost/peertube` and untar the config archive there first, so
.env is back before any container starts: PostgreSQL reads `POSTGRES_PASSWORD` from it the moment
it initialises an empty volume, and without it the database will not start. Then
`docker compose down -v`, the one place `-v` belongs because it drops the old volume on purpose,
`docker compose up -d postgres`, wait 30 seconds, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U peertube -d peertube`, then `docker compose up -d`. Rows
pointing at videos nobody copied are dead links, so `data` travels with the dump.

## 9. Updating later

Releases are at https://github.com/Chocobozzz/PeerTube/releases. Back up first, then edit the
image line in ~/selfhost/peertube/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/peertube
docker compose pull
docker compose up -d
docker compose logs --tail 40 peertube
```

PeerTube migrates its database on the way up, a major version for minutes. Watch it settle, then
re-run step 7's five checks.

## 10. What will probably go wrong

The first upload will look like a broken install, and on a laptop it is worse than on a server.
Mine said the video was published, then showed a spinner where the player belongs for eleven
minutes while the fans spun up. Nothing was wrong: ffmpeg had the file, on one thread, upstream's
default. Then I closed the lid halfway through, and the job was still queued when I opened it,
because a sleeping computer transcodes nothing. Leave it awake until the log settles.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not turn `PEERTUBE_FEDERATION_ENABLED` back on or follow another instance. Federation needs
  a name other servers can resolve, and this one is `localhost` to everybody.
- Do not enable live streaming. It wants a second published port and a second transcoding
  pipeline running while somebody watches.
- Do not configure SMTP or add upstream's postfix container. The one password resets with
  `docker compose exec -u peertube peertube npm run reset-password -- -u root`.
