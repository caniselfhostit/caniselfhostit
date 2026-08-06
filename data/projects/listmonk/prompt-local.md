You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install listmonk 6.2.0 and the PostgreSQL it stores subscribers in, under ~/selfhost/listmonk,
answering at http://localhost:8096.

## 1. Preflight

Say this before step 2 runs; it decides whether they want this install at all. This listmonk
can still send through a relay, but the unsubscribe link in every message is built from this
machine's address, and http://localhost:8096 means "your own computer" to the recipient. The
honest use here is a list they build and draft on plus campaigns they send to themselves;
mailing strangers hands them a message they cannot unsubscribe from.

Ask this too: do they have an SMTP relay account, with a host, port, username and password?
listmonk delivers nothing itself, and step 7 waits on those four.

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
distribution ID and codename print next, for step 2. listmonk plus PostgreSQL needs 1024 MB of
RAM available and 5 GB free on the home disk; both images publish amd64 and arm64. If available
RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/listmonk/uploads ~/selfhost/listmonk/backups
ls -la ~/selfhost/listmonk
```

Assert: `ls -la` shows `uploads` and `backups`, both owned by the user. There is no `data`
folder: everything that matters is a row in PostgreSQL, which step 5 keeps in a Docker-managed
volume, so no ownership fix is needed here.

## 4. Secrets

Two secrets: the PostgreSQL password and the Super Admin password. Generate both here, print
neither, keep both out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/listmonk/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
LISTMONK_ADMIN_USER=admin
LISTMONK_ADMIN_PASSWORD=$(openssl rand -base64 30)
EOF
chmod 600 ~/selfhost/listmonk/.env
umask 022
ls -l ~/selfhost/listmonk/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these run the same
on all three. Upstream reads `LISTMONK_ADMIN_USER` and `LISTMONK_ADMIN_PASSWORD`
during the one-time install pass, so the Super Admin exists the first time the container
starts. On Windows those mode bits are advisory: NTFS does not enforce them, and the user's own
account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/listmonk/compose.yml <<'EOF'
# listmonk · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://listmonk.app/docs/installation/
#   variable reference . https://listmonk.app/docs/configuration/
#   upgrade path ....... https://listmonk.app/docs/upgrade/
#   health route ....... https://github.com/knadh/listmonk/blob/v6.2.0/cmd/handlers.go
#
# Two services on the computer you are sitting at, every path relative to
# ~/selfhost/listmonk/. The database is a named volume, not a bind mount,
# because the PostgreSQL image chowns its data directory to its own uid, which
# a home-directory bind mount cannot allow on Windows. The command is
# upstream's three-phase form; --config '' means "env vars, no TOML file".
# Digests read on 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: listmonk-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: listmonk
      POSTGRES_USER: listmonk
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - listmonk-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U listmonk -d listmonk"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  app:
    image: listmonk/listmonk:v6.2.0@sha256:f535d59e14991337a9f2d570273685378ae86b0d7698c3e00da444e3bc205286
    container_name: listmonk-app
    restart: unless-stopped
    env_file: ./.env
    command: [sh, -c, "./listmonk --install --idempotent --yes --config '' && ./listmonk --upgrade --yes --config '' && ./listmonk --config ''"]
    environment:
      LISTMONK_app__address: 0.0.0.0:9000
      LISTMONK_db__host: db
      LISTMONK_db__port: 5432
      LISTMONK_db__user: listmonk
      LISTMONK_db__database: listmonk
      LISTMONK_db__password: ${POSTGRES_PASSWORD}
      LISTMONK_db__ssl_mode: disable
      LISTMONK_db__max_open: 25
      LISTMONK_db__max_idle: 25
      LISTMONK_db__max_lifetime: 300s
      TZ: Etc/UTC
    volumes:
      # Admin -> Media uploads. The entrypoint chowns /listmonk to 0:0 by
      # default, so on Linux this folder ends up root-owned but readable.
      - ./uploads:/listmonk/uploads
    ports:
      # Loopback only: no other device on the wifi can reach 8096.
      - "127.0.0.1:8096:9000"
    depends_on:
      db:
        condition: service_healthy

volumes:
  listmonk-pgdata:
EOF
cd ~/selfhost/listmonk && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule, because nothing is published beyond loopback.

8096 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not the internet.
Mail still leaves, because that connection is outbound, which is why step 1's unsubscribe link
is the limit here and not the sending.

```bash
grep -n '127.0.0.1' ~/selfhost/listmonk/compose.yml
```

Assert: one line, `- "127.0.0.1:8096:9000"`. PostgreSQL publishes no host port at all.

## 7. Start and verify

```bash
cd ~/selfhost/listmonk
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8096/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8096/health
curl -sS http://localhost:8096/admin/login | grep -o '<h2>Login</h2>'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8096/api/lists
```

Assert all four, and print what you received for each: the loop ends on `200`; the health call
prints `{"data":true}`; the grep prints `<h2>Login</h2>`, the first screen; the unauthenticated
API call prints `403`, the admin API refusing a caller with no session. If any miss, stop, run
`docker compose logs --tail 40 app` and `--tail 20 db`, and name the cause. A grep printing
nothing while the page shows `New user` means the database was not empty on first start: run
`docker compose down -v` and this block again. `port is already allocated` means something else
holds 8096 (`lsof -nP -iTCP:8096`, `netstat -ano | findstr :8096` on Windows). A running
container is not success.

STOP: tell the user to do these three things and wait. Do not continue until they confirm.

- Read the admin password with `grep LISTMONK_ADMIN_PASSWORD ~/selfhost/listmonk/.env`, save it
  in their password manager, log in at http://localhost:8096/admin/login as `admin`.
- Settings -> General: set Root URL to `http://localhost:8096` and the default from-address to
  one on a domain they control. Both ship as examples and both go into every message sent.
- Settings -> SMTP: the seeded first entry is on and points at `smtp.yoursite.com` with
  placeholder credentials. Replace its host, port, username and password with the relay's, and
  use the Test connection button before saving.

Settings reload on save. Once they confirm, check the values moved:

```bash
cd ~/selfhost/listmonk
docker compose exec -T db psql -U listmonk -d listmonk -tAc "SELECT key, value FROM settings WHERE key IN ('app.root_url', 'app.from_email')"
docker compose exec -T db psql -U listmonk -d listmonk -tAc "SELECT count(*) FROM settings, jsonb_array_elements(value) s WHERE key='smtp' AND (s->>'enabled')::bool AND s->>'host'='smtp.yoursite.com'"
```

Assert: the first prints a root URL of `"http://localhost:8096"` and a from-address with no
`listmonk.yoursite.com` in it, and the second prints `0`.

## 8. First backup and restore

Two artifacts: the database holds subscribers, campaigns, settings and click history; the
archive holds the config and the uploads.

```bash
cd ~/selfhost/listmonk
docker compose exec -T db pg_dump -U listmonk -d listmonk | gzip > ~/selfhost/listmonk/backups/listmonk-db-$(date +%F).sql.gz
tar -C ~/selfhost/listmonk -czf ~/selfhost/listmonk/backups/listmonk-files-$(date +%F).tar.gz compose.yml .env uploads
ls -lh ~/selfhost/listmonk/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Both carry live credentials: .env in the
archive, and the SMTP relay's own credential in the dumped settings table. Treat them like a
password-manager export.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination off this computer, a sync folder or a USB
stick, and copy both there with `cp`. In Git Bash a Windows drive is written `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both files are listed there.

To restore, in this order. `cd ~/selfhost/listmonk`, untar the file archive there first, so
compose.yml and .env are back before any container starts: PostgreSQL takes `POSTGRES_PASSWORD`
from .env the moment it initialises an empty volume. Then `docker compose down -v`, the one
place `-v` belongs, `docker compose up -d db`, wait 30 seconds for healthy, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T db psql -U listmonk -d listmonk`,
then `docker compose up -d` and re-run step 7's check. The consent record for every subscriber
lives in that database, and a list restored from nothing is a list they may no longer mail.

## 9. Updating later

New versions are at https://github.com/knadh/listmonk/releases. Upstream says to back up the
database before every upgrade, so run step 8 first, then edit the image line in
~/selfhost/listmonk/compose.yml:

```bash
cd ~/selfhost/listmonk
docker compose pull
docker compose up -d
docker compose logs --tail 30 app
```

The `--upgrade` pass migrates on the way up. Watch that log, then re-run step 7's check.

## 10. What will probably go wrong

I scheduled a campaign for nine in the morning, closed the lid, and found it still at zero sent
at lunchtime. Nothing was broken. A campaign here moves only while the machine is awake and the
Docker daemon is up, and `restart: unless-stopped` acts only once that daemon runs, so a reboot
leaves nothing on 8096 until Docker Desktop starts. Turn on its start-at-login setting, and
after a reboot run `cd ~/selfhost/listmonk && docker compose up -d` before concluding anything
is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not send a campaign to anybody but the user. The unsubscribe link resolves only on this
  computer, so a recipient cannot use it.
- Do not configure bounce processing or OIDC. Each wants a second account somewhere else.
- Do not move media uploads to S3. The uploads folder from step 3 is the choice here.
