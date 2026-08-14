You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Outline 1.9.2 under ~/selfhost/outline, answering at http://localhost:8185.

## 1. Preflight

Say this before step 2 runs, because it decides whether they want this install. Outline is a wiki
for a team, and this one answers at http://localhost:8185: this computer only, so every link it
makes opens nothing for a colleague. A knowledge base for one, that stops when the lid shuts.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. Outline needs 2048 MB of RAM available and 10
GB free on the home disk; all images are amd64 and arm64. Under either floor, print and stop.

Settle one thing more, because step 4 stops dead without it. Outline has no password login: after
the workspace is claimed the way in is a mailed link, so have the user hold relay host, port,
username, password and sender ready.

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
mkdir -m 755 -p ~/selfhost/outline/data ~/selfhost/outline/backups
if [ "$(uname -s)" = "Linux" ]; then sudo chown -R 1001:1001 ~/selfhost/outline/data; fi
ls -la ~/selfhost/outline
```

Assert: `ls -la` shows `data` and `backups`. Outline runs as the non-root user 1001, so on Linux
`data` goes to that uid or attachment uploads fail while nothing else does. On macOS and Windows
the guard is a no-op.

## 4. Secrets

Three secrets: the key that encrypts stored data, the utility secret, and the PostgreSQL password.
Generate all three here, print none, keep them out of your summary and every log line. Hex, since
`SECRET_KEY` must be exactly 64 hex characters.

```bash
cd ~/selfhost/outline
umask 077
cat > .env <<EOF
URL=http://localhost:8185
SECRET_KEY=$(openssl rand -hex 32)
UTILS_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
SMTP_HOST=CHANGE_ME
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USERNAME=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
SMTP_FROM_EMAIL=CHANGE_ME
EOF
chmod 600 .env
umask 022
ls -l .env
```

Assert: mode `-rw-------`. Git Bash ships openssl; on Windows mode bits are advisory and the real
boundary is the user's account. Changing `SECRET_KEY` later locks everyone out, upstream says.

STOP: tell the user to open ~/selfhost/outline/.env in an editor, replace every `CHANGE_ME` with
the value from their mail provider, set `SMTP_PORT` to 465 and `SMTP_SECURE` to true if their relay
wants that, and save. Do not continue until they confirm, and never ask them to paste those values
back to you.

```bash
awk '/CHANGE_ME/ {n++} END {print n+0}' ~/selfhost/outline/.env
```

Assert: `0`. It counts lines, never values.

## 5. compose.yml

```bash
cat > ~/selfhost/outline/compose.yml <<'EOF'
# Outline · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation and source, not copied from a
# repository:
#   docker hosting ..... https://docs.getoutline.com/s/hosting/doc/docker-7pfeLP5a8t
#   variables and smtp . https://github.com/outline/outline/blob/v1.9.2/.env.sample
#   image .............. https://github.com/outline/outline/blob/v1.9.2/Dockerfile
#
# Three services on the computer you are sitting at, paths relative to
# ~/selfhost/outline/ so one file works on macOS, Linux and Windows. Postgres
# and Redis are named volumes, because both images chown their own data
# directory and Docker Desktop cannot grant that on a Windows bind mount.
# Attachments stay a real folder, ./data, owned by uid 1001.
#
# FORCE_HTTPS is the one line that differs from the VPS file: it defaults to
# true, and with no proxy setting X-Forwarded-Proto it sends every request to
# https://localhost, where nothing answers. The other four settings carry the
# same values, and reasons, as the VPS file. Digests read on 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.6-alpine@sha256:432b3b824c0769275ec9b0947736ef8b376d6997bcaa9de29818f613819c2feb
    container_name: outline-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: outline
      POSTGRES_USER: outline
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - outline-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U outline -d outline"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 stays on the compose network.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: outline-redis
    restart: unless-stopped
    # appendonly persists every change; noeviction makes Redis refuse writes
    # rather than silently drop a queued job when memory runs out.
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - outline-redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 6379 stays on the compose network.

  outline:
    image: outlinewiki/outline:1.9.2@sha256:32d76719c378931dd65d93945930ca380d8376a0337d98a991fcc12b266f33cf
    container_name: outline
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgres://outline:${DB_PASSWORD}@postgres:5432/outline
      PGSSLMODE: disable
      REDIS_URL: redis://redis:6379
      FILE_STORAGE: local
      WEB_CONCURRENCY: "1"
      ENABLE_UPDATES: "false"
      FORCE_HTTPS: "false"
    volumes:
      # Attachments, avatars and imported files, in a folder you can open.
      - ./data:/var/lib/outline/data
    ports:
      # Loopback only: no other device can reach 8185.
      - "127.0.0.1:8185:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  outline-pgdata:
  outline-redis:
EOF
cd ~/selfhost/outline && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Outline migrates its schema on the way up.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. A certificate attests a
public name and nothing here has one; browsers treat http://localhost as a secure context anyway,
which is why step 7's passkey works. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/outline/compose.yml
```

Assert: that prints `1`, the line `- "127.0.0.1:8185:3000"`. PostgreSQL and Redis publish no port
at all.

## 7. Start and verify

The first start runs the migrations, so it is slow. While no workspace exists the server offers a
`Create workspace` form to anyone reaching 8185, and the first to fill it in is admin.

```bash
cd ~/selfhost/outline
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8185/_health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8185/_health; echo
curl -sS -H 'content-type: application/json' -d '{}' http://localhost:8185/api/auth.config; echo
```

Assert all three and print what you received. The loop ends printing `200`. `/_health` prints
`OK`, returned only after querying PostgreSQL and pinging Redis. The config call prints
`{"data":{"providers":[]},"status":200,"ok":true}`: no workspace yet, no sign-in option yet. If
any miss, stop and run `docker compose logs --tail 40 outline`:
`Environment configuration is invalid` is step 4.

STOP: tell the user to open http://localhost:8185, fill in the `Create workspace` form with a
workspace name, their name and their email, and confirm they land inside the wiki.
Do not continue until they confirm.

Once they confirm, prove the door is shut:

```bash
curl -sS -H 'content-type: application/json' -d '{}' http://localhost:8185/api/auth.config; echo
curl -sS -o /dev/null -w '%{http_code}\n' -H 'content-type: application/json' -d '{}' http://localhost:8185/api/documents.list
curl -sS -H 'content-type: application/json' -d '{"teamName":"closed","userName":"closed","userEmail":"closed@example.com"}' http://localhost:8185/api/installation.create; echo
```

Assert all three and print every response. The config call now carries the workspace name and a
provider whose `"id"` is `"email"`, proving the relay settings arrived. The documents call prints
`401`. The last prints `Installation already has existing teams`: the create-workspace route now
refuses, and that refusal is the closure.

STOP: tell the user to sign out, enter their email on the sign-in page, open the link in the mail
that arrives, and confirm they are back inside. Do not continue until they confirm they are signed
in again. There is no password to fall back on. Tell them to add a passkey under Settings, Security
afterwards: here that is the fastest way in, and it needs no mail.

## 8. First backup and restore

The database is a named volume, so a folder copy misses every document. Two artifacts: a dump and
an archive of the attachments and the two files that rebuild the service.

```bash
cd ~/selfhost/outline
docker compose exec -T postgres pg_dump -U outline -d outline | gzip > backups/outline-db-$(date +%F).sql.gz
tar -C ~/selfhost/outline -czf backups/outline-files-$(date +%F).tar.gz compose.yml .env data
ls -lh backups/
```

Assert: both exist and are non-empty. Print the sizes. Nothing stops: `pg_dump` snapshots a
running database consistently.

Both sit on the same disk as the data, which is not a backup, and on a laptop disk and machine fail
together. Ask the user for a destination off this computer, a synced folder or a USB stick, and
copy both there with `cp`. In Git Bash that is `/d/Backups`, not `D:\Backups`. Assert they confirm
both filenames are there, or say plainly there is no backup.

To restore: `cd ~/selfhost/outline`, `docker compose down -v`, untar the archive there so `.env` is
back first, on Linux re-run step 3's `chown`, `docker compose up -d postgres`, wait for healthy,
pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U outline -d outline`, then `docker compose up -d`. The two
travel together, since `SECRET_KEY` decrypts columns in that dump.

## 9. Updating later

New versions are listed at https://github.com/outline/outline/releases; release tag `v1.9.2` and
image tag `1.9.2` are the same number. This pins the newest stable line, not the `nightly` tag
built from the day's commits. Back up first, then edit the image line:

```bash
cd ~/selfhost/outline
docker compose pull
docker compose up -d
docker compose logs --tail 40 outline
```

Watch that log until the migrations settle, then re-run step 7's checks before calling it done.

## 10. What will probably go wrong

The machine will sleep, and Outline will look broken when it wakes. I closed the lid mid-sentence,
opened it an hour later, and the editor sat there refusing to save: the page holds a WebSocket to
the collaboration service, and a suspended container drops it without telling the tab. Reloading
fixes it every time. The other is a reboot, after which Docker Desktop may not have started. Turn
on its start-at-login setting, and after any reboot run `docker compose up -d` in that folder.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8185 to 0.0.0.0 so a phone on the wifi can reach it. `URL` says localhost, so
  every link the app builds still points back at this machine.
- Do not configure Google, Slack, Microsoft, Discord or OIDC sign-in, and do not set
  `FILE_STORAGE=s3`. This install needs neither.
