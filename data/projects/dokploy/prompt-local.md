You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Dokploy v0.29.14 and the PostgreSQL it keeps every project in, under ~/selfhost/dokploy,
answering at http://localhost:8144.

## 1. Preflight

Say this before step 2, because it decides whether they want this install at all. Dokploy is a
deploy panel, and here it deploys to this computer: what it builds runs on this machine's
Docker, at localhost and nowhere else, and stops when the machine sleeps. And it drives that
Docker daemon through a mounted socket, in Swarm mode, which is an administrator account handed
to a web page.

Detect the OS and measure it:

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
distribution ID and codename print next, for step 2. Upstream asks for 2048 MB of RAM available
and 30 GB free, a floor rather than a budget, because builds run here too. Both images publish
amd64 and arm64; on macOS and Windows that memory is the host's, and Docker Desktop takes a
share. If RAM available is under 2048 MB or free disk under 30 GB, print both and stop.

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

## 3. Layout and Swarm mode

Everything the panel deploys is a Swarm service, so Swarm mode is not optional here, and the
network has to exist first.

```bash
mkdir -p ~/selfhost/dokploy/config ~/selfhost/dokploy/backups
docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active || docker swarm init --advertise-addr 127.0.0.1
docker network inspect dokploy-network >/dev/null 2>&1 || docker network create --driver overlay --attachable dokploy-network
docker info --format 'swarm={{.Swarm.LocalNodeState}}'
docker network inspect dokploy-network --format 'network={{.Name}} {{.Driver}} attachable={{.Attachable}}'
ls -la ~/selfhost/dokploy
```

Assert three: `swarm=active`, a line reading
`network=dokploy-network overlay attachable=true`, and `ls -la` showing `config` and `backups`
owned by the user. `config` is the panel's tree, seen at /etc/dokploy inside the container; on
Linux it writes there as root, and on macOS and Windows Docker Desktop settles ownership. No
database folder: step 5 keeps PostgreSQL in a volume.

## 4. Secrets

Two secrets, both generated here: the PostgreSQL password and the key the panel signs sessions
with. Print neither, and keep both out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/dokploy/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
AUTH_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/dokploy/.env
umask 022
ls -l ~/selfhost/dokploy/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these run the same on
all three systems. Upstream falls back to a published hard-coded signing key when that value is
unset, warning rather than refusing to start, so this file is what makes the session cookie here
unforgeable. On Windows those mode bits are advisory: NTFS does not enforce them, and the real
boundary is the account.

## 5. compose.yml

```bash
cat > ~/selfhost/dokploy/compose.yml <<'EOF'
# Dokploy · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   installation ....... https://docs.dokploy.com/docs/core/installation
#   manual install ..... https://docs.dokploy.com/docs/core/manual-installation
#
# Two services, every path relative to ~/selfhost/dokploy/ so one file works on
# macOS, Linux and Windows. PostgreSQL uses a named volume because it chowns
# that directory to a uid of its own, which a Windows bind mount cannot allow.
# No proxy container: nothing is public and the panel answers on 127.0.0.1:8144.
# Its own tree is /etc/dokploy in the container and ./config out here, so a file
# the panel mounts points at a path this machine has not got. dokploy-network is
# the attachable overlay network the install step made, and Swarm mode is not
# optional. Digests read 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  dokploy:
    image: dokploy/dokploy:v0.29.14@sha256:57771f6edc7921f741c004002b9be9b39cfa5cb84ecd4ba325f735219a8cae6b
    container_name: dokploy
    restart: unless-stopped
    environment:
      # Upstream reads DATABASE_URL ahead of its Docker-secret path.
      DATABASE_URL: postgres://dokploy:${DB_PASSWORD}@postgres:5432/dokploy
      BETTER_AUTH_SECRET: ${AUTH_SECRET}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./config:/etc/dokploy
      - dokploy-docker:/root/.docker
    ports:
      # Loopback only: no other device on the wifi can reach 8144.
      - "127.0.0.1:8144:3000"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/api/health || exit 1"]
      interval: 10s
      retries: 30
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: dokploy-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: dokploy
      POSTGRES_USER: dokploy
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - dokploy-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dokploy -d dokploy"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

networks:
  default:
    name: dokploy-network
    external: true

volumes:
  dokploy-docker:
    name: dokploy-docker
  dokploy-pgdata:
    name: dokploy-pgdata
EOF
cd ~/selfhost/dokploy && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Two services, one published port, two volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers treat
http://localhost as a secure context anyway, so pages needing crypto still work. Nothing is
published beyond loopback: 8144 binds to 127.0.0.1, this computer only, not the user's phone and
not a laptop on the wifi. For a panel holding the keys to this machine that is the point of this
path, not a shortcoming. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/dokploy/compose.yml
```

Assert: `1`, the panel's port. PostgreSQL publishes none, so 5432 cannot appear, and anything
deployed later is the user's to keep on loopback too.

## 7. Start and verify

The panel waits for PostgreSQL, migrates, then serves. A cold start takes minutes.

```bash
cd ~/selfhost/dokploy
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8144/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8144/api/health; echo
curl -sSL -o /dev/null -w '%{url_effective}\n' http://localhost:8144/
curl -sSL http://localhost:8144/register | grep -c 'Setup the server'
docker compose ps
```

Assert all five, printing what you got for each. The loop ends on `200`. `/api/health` answers
`{"ok":true}`. The root lands on `http://localhost:8144/register`, where an instance with no
account sends everyone. The grep prints at least `1`: that screen carries the heading
`Setup the server` above `Enter your email and password to setup the server`, and `ps` shows
both containers up. On any miss, stop, run `docker compose logs --tail 40 dokploy` and name the
cause: a database that never reports healthy is step 4 with a blank `DB_PASSWORD`;
`network dokploy-network declared as external, but could not be found` is step 3; and
`port is already allocated` means something else holds 8144, which
`lsof -nP -iTCP:8144 -sTCP:LISTEN` names. A running container is not success.

STOP: tell the user to open http://localhost:8144 and create their account there. It is the only
moment it can be made and nothing here can reset it, so have them save the password in a manager
first. Do not continue until they confirm.

```bash
curl -sSL -o /dev/null -w '%{url_effective}\n' http://localhost:8144/register
```

Assert: `http://localhost:8144/`. Registration closes once an account exists.

## 8. First backup and restore

Two artifacts: the database with every project, application and credential, and an archive of
the files and panel tree that rebuild the service around it.

```bash
cd ~/selfhost/dokploy
docker compose exec -T postgres pg_dump -U dokploy -d dokploy | gzip > ~/selfhost/dokploy/backups/dokploy-db-$(date +%F).sql.gz
tar -C ~/selfhost/dokploy -czf ~/selfhost/dokploy/backups/dokploy-config-$(date +%F).tar.gz compose.yml .env config
ls -lh ~/selfhost/dokploy/backups/
```

Assert: both exist and are non-empty, and print both sizes. Nothing stops: `pg_dump` snapshots
a running database.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination off this computer, a folder their sync
service watches or a USB stick, and copy both there with `cp`; in Git Bash a Windows drive is
`/d/Backups`. Assert: the user confirms both are listed there. If they have neither, say plainly
that this has no backup.

To restore, in this order. `cd ~/selfhost/dokploy` and untar the archive there first, so
compose.yml, .env and config land before any container starts: PostgreSQL takes `DB_PASSWORD`
from .env the moment it initialises an empty volume, and a missing .env means a blank password
and a database that will not start. Then `docker compose down -v`, the one place `-v` belongs
because it drops the old volume on purpose, `docker compose up -d postgres`, wait 30 seconds,
pipe `gunzip -c` on the dump into
`docker compose exec -T postgres psql -U dokploy -d dokploy`, then `docker compose up -d` and
log in once. That is the disaster plan.

## 9. Updating later

Versions are at https://github.com/Dokploy/dokploy/releases. Back up first, then edit the image
line in ~/selfhost/dokploy/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/dokploy
docker compose pull
docker compose up -d
docker compose logs --tail 40 dokploy
```

It migrates its own database on the way up, so watch that log settle, then re-run step 7's
health check. Do not use the panel's update button: it drives a Swarm service named `dokploy`,
and this runs a compose container, so the pinned image line is the only thing that moves a
version here.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8144, and got a connection refused that reads
like a lost install. It was not: Docker Desktop had not started with the session, so nothing was
listening on 8144, and `restart: unless-stopped` only acts once the daemon is up. The other half
of it is that everything it had deployed was down too, on that same daemon. Turn on Docker
Desktop's start-at-login, and after a reboot run
`cd ~/selfhost/dokploy && docker compose up -d` before concluding anything broke.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not start a Traefik container, and do not use a panel action that offers to. It wants 80
  and 443 here, and this path publishes nothing outside loopback.
- Do not rebind 8144 to 0.0.0.0 so a phone can reach the panel. That puts a dashboard with
  administrator reach over this machine on every network the user joins.
- Do not add a second server, and do not configure SMTP, a notification transport or a GitHub
  App. Each is a credential of its own and none is needed here.
