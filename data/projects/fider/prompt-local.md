You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Fider v0.36.0, with the PostgreSQL it stores posts and votes in, under ~/selfhost/fider,
answering at http://localhost:8181.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Fider's product is a board customers post to and vote on, and this one answers only at
http://localhost:8181, which means "this computer" wherever it is read. Nobody whose feedback
they wanted can open it. They get a private list of their own ideas with a vote button.

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
distribution ID and codename print next, for step 2. This install needs 1024 MB of RAM available
and 5 GB free on the home disk, and both images publish amd64 and arm64. On macOS and Windows
that figure is the host's, and Docker Desktop takes its cut. If either floor is missed, print
both numbers and stop.

Settle one thing more, because step 4 stops dead without it. Fider has no passwords: you sign in
by following a link it mails you, and it refuses to boot until told where to post mail. Upstream
states that without a valid SMTP server you get
`panic: could not find environment variable named 'EMAIL_SMTP_HOST'`. Have the user find a relay
host, port, username, password and from-address first.

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
mkdir -p ~/selfhost/fider/backups
ls -la ~/selfhost/fider
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: posts, votes,
comments, accounts and images are rows in PostgreSQL, which step 5 keeps in a volume Docker
manages, so no ownership fix is needed anywhere.

## 4. Secrets

Two secrets: the PostgreSQL password and the token-signing key. Generate both here, print
neither, keep both out of your summary and any log line. Hex for both, 64 bytes of it for
`JWT_SECRET`, which clears the 512 bits upstream's generator recommends.

```bash
cd ~/selfhost/fider
umask 077
cat > .env <<EOF
BASE_URL=http://localhost:8181
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 64)
SIGNUP_DISABLED=false
EMAIL_NOREPLY=CHANGE_ME
EMAIL_SMTP_HOST=CHANGE_ME
EMAIL_SMTP_PORT=587
EMAIL_SMTP_USERNAME=CHANGE_ME
EMAIL_SMTP_PASSWORD=CHANGE_ME
EOF
chmod 600 .env
umask 022
ls -l .env
```

Assert: mode `-rw-------`. Git Bash ships openssl; on Windows the mode bits are advisory and the
real boundary is the user's own account. `SIGNUP_DISABLED` is false until step 7 closes it.

STOP: tell the user to open ~/selfhost/fider/.env in an editor, replace every `CHANGE_ME`,
correct `EMAIL_SMTP_PORT` if their relay is not 587, add a line reading
`EMAIL_SMTP_ENABLE_IMPLICIT_TLS=true` if it is 465, and save. Do not continue until they
confirm, and never ask them to paste those values.

```bash
grep -c CHANGE_ME .env || true
```

Assert: that prints `0`. It counts lines, never values.

## 5. compose.yml

```bash
cat > ~/selfhost/fider/compose.yml <<'EOF'
# Fider · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker hosting ... https://docs.fider.io/hosting-instance
#   configuration .... https://github.com/getfider/fider/blob/v0.36.0/app/pkg/env/env.go
#
# Two services, paths relative to ~/selfhost/fider/ so one file works on
# macOS, Linux and Windows. The database is a named volume, not a bind mount:
# the PostgreSQL image chowns its data directory to a uid Docker Desktop
# cannot grant on a Windows home directory. Upstream wants PostgreSQL 12 or
# newer and runs the floating getfider/fider:stable; this pins 16, and v0.36.0
# by digest, the newest version tag the registry carries. BLOB_STORAGE
# defaults to sql, so images are rows too, and LOG_SQL is off because
# upstream's default writes every log line into a table nothing reads.
# Digests read on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: fider-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: fider
      POSTGRES_USER: fider
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - fider-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U fider -d fider"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  fider:
    image: getfider/fider:v0.36.0@sha256:466669b3c932158d7fc082d4037ad881fce6c5cd49cf973e15d9bcaedc27889a
    container_name: fider
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgres://fider:${POSTGRES_PASSWORD}@postgres:5432/fider?sslmode=disable
      LOG_SQL: "false"
    healthcheck:
      # `fider ping` ships in the image and asks its own /_health route.
      test: ["CMD", "./fider", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    ports:
      - "127.0.0.1:8181:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  fider-pgdata:
EOF
cd ~/selfhost/fider && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume, no
password: compose reads `${POSTGRES_PASSWORD}` out of ./.env.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve, and a certificate attests a public name nothing here has; browsers treat
http://localhost as a secure context anyway, so pages needing crypto still work. Nothing is
published beyond loopback: 8181 is bound to 127.0.0.1, this computer only, not the user's phone
and not anyone whose feedback they wanted. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/fider/compose.yml
```

Assert: that prints `1`, the published-port line `- "127.0.0.1:8181:3000"`. PostgreSQL publishes
no host port, so 5432 cannot appear.

## 7. Start and verify

The image runs `fider migrate` before the server listens, so the first boot takes minutes.

```bash
cd ~/selfhost/fider
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8181/_health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8181/_health
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8181/
curl -sS http://localhost:8181/signup | grep -c 'Sign up for Fider and let your customers share'
```

Assert all four, and print what you received for each. The loop ends on `200`. The health body
is exactly `{"status":"Healthy"}`. The bare address prints `307`, because no board exists yet and
Fider redirects to the installer. The grep prints `1`. If any misses, stop, run
`docker compose logs --tail 60 fider`, and name the cause: a
`panic: could not find environment variable named` line points at step 4, where a `CHANGE_ME`
survived, and `port is already allocated` means something else holds 8181. A running container
is not success.

The first screen at http://localhost:8181/signup is the installer, headed `1. Who are you?`
above a name and email box, with `2. What is this Feedback Forum for?` below.

STOP: tell the user to open http://localhost:8181/signup, fill in their name, their email and
the board's name, submit, then follow the link in the confirmation mail. Do not continue until
they confirm the board opened. That mail is the only proof the relay from step 4 works, and
until the link is followed every page says `Pending Activation`.

Once they confirm, close the installer and prove it is closed:

```bash
cd ~/selfhost/fider
sed 's/^SIGNUP_DISABLED=false$/SIGNUP_DISABLED=true/' .env > .env.next && mv .env.next .env
chmod 600 .env
docker compose up -d --force-recreate fider
sleep 45
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8181/signup
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8181/
```

Assert: /signup prints `404` and the bare address prints `200`. Both must pass; the rewrite
avoids `sed -i`, spelled differently on macOS. Migrations are done by now, so 45 seconds is
enough for a recreate.

## 8. First backup and restore

Two artifacts: a dump with every post, vote, comment, account and image, and a config archive
with the two files that rebuild the service.

```bash
cd ~/selfhost/fider
docker compose exec -T postgres pg_dump -U fider -d fider | gzip > ~/selfhost/fider/backups/fider-db-$(date +%F).sql.gz
tar -C ~/selfhost/fider -czf ~/selfhost/fider/backups/fider-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/fider/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops: `pg_dump` snapshots a
running database.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a
synced folder or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is
written `/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are there, or
say plainly this install has no backup.

To restore, in this order. In ~/selfhost/fider, untar the config archive first, so compose.yml
and .env are back before any container starts: PostgreSQL reads `POSTGRES_PASSWORD` from .env
the moment it initialises an empty volume. Then `docker compose down -v`, the one place `-v`
belongs, `docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U fider -d fider`, and
`docker compose up -d`. The archive matters as much as the dump: `JWT_SECRET` signs every
session.

## 9. Updating later

New versions are listed at https://github.com/getfider/fider/releases, the tags that exist as
images at https://hub.docker.com/r/getfider/fider/tags. Check the second: on 2026-08-07 the
newest release was v0.36.1 with no image under that name, which is why this pins v0.36.0. Do not
answer that with the floating `stable` tag. Take both backups first, then edit the image line in
compose.yml to the new tag and digest:

```bash
cd ~/selfhost/fider
docker compose pull
docker compose up -d
docker compose logs --tail 40 fider
```

Watch that log until it settles, then re-run step 7's `/_health` check.

## 10. What will probably go wrong

I rebooted this machine, opened the board I had made the day before, and got a connection error
that reads exactly like a lost database. It was not. Docker Desktop had not started with the
session, nothing was listening on 8181, and `restart: unless-stopped` acts only once the Docker
daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/fider && docker compose up -d` before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `BASE_URL` to this machine's LAN address and do not rebind 8181 to 0.0.0.0 so a
  colleague can vote. That puts a board that mails sign-in links on every network they join.
- Do not configure Google, Facebook or GitHub sign-in. Each is an app registered in somebody
  else's console; this install signs people in by email.
- Do not switch `BLOB_STORAGE` to `s3` or `fs`, and do not set `HOST_MODE` to multi-tenant.
