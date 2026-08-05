You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Linkwarden 2.16.0 on this computer, reachable at http://localhost:8085, with
everything it owns under ~/selfhost/linkwarden.

## 1. Preflight

Detect the OS, then measure the machine:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize | awk '{printf "%d MB installed\n", $1/1048576}' ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`uname -s` prints `Darwin` on macOS, `Linux` on Linux, `MINGW` or `MSYS` in Git Bash on
Windows. Record which: steps 2, 3, 4 and 8 branch on it. The Windows line prints bytes, so
divide by 1048576; it and the macOS line report RAM installed, the Linux line what is free
now.

Linkwarden needs 2048 MB of RAM available and 20 GB free on the home disk. Preserving a
page runs a headless Chromium, and every saved link can leave a screenshot, a PDF and an
HTML copy, so the disk floor is month three. `uname -m` prints `x86_64`, `arm64` or
`aarch64`; both images publish amd64 and arm64, so nothing branches on it.

Stop rule: if the RAM figure is under 2048 MB or free space on `~` is under 20 GB, print
both and stop. The failure here is the OOM killer taking the archiver out mid-import: it
looks random, it was a sizing decision. On macOS and Windows the binding ceiling is Docker
Desktop's VM, not the machine, and step 7 measures it.

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
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this prompt
  resumes at this step. Then STOP: have the user open Docker Desktop, accept its terms, and
  confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt repository,
  with its signing key saved to a file first, never piped into a shell:

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

  Tell the user in one sentence that `docker` group membership is root-equivalent here.
  Then STOP: have them log out, log back in, and run this prompt again from step 2. The
  group is not active in this shell until they do, so the assert below cannot pass. Do not
  continue until they confirm.

- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose plugin
  with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not continue
without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/linkwarden/data ~/selfhost/linkwarden/backups
ls -la ~/selfhost/linkwarden
```

Assert: `ls -la` shows `data` and `backups`. Everything this install owns lives here, apart
from the volume step 5 declares.

Ownership: on Linux the container writes into `./data` as the uid the image runs as, so
removing it later takes `sudo`; nothing needs chowning up front. On macOS and Windows,
Docker Desktop's file sharing owns that.

## 4. Secrets

Two secrets: the PostgreSQL password and the NextAuth signing secret. Generate both here,
print neither, keep both out of your summary and any log line. Hex, not base64: the
password ends up inside a connection URL.

```bash
umask 077
cat > ~/selfhost/linkwarden/.env <<EOF
NEXTAUTH_URL=http://localhost:8085/api/v1/auth
NEXT_PUBLIC_DISABLE_REGISTRATION=false
NEXTAUTH_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/linkwarden/.env
umask 022
ls -l ~/selfhost/linkwarden/.env
```

Assert: the file exists, and on macOS and Linux its mode reads `-rw-------`. In Git Bash
`ls -l` prints `-rw-r--r--` whatever `chmod` did, because NTFS keeps its own permissions,
and that is expected, not a failure. Say one line out loud on Windows: the mode bits are
advisory, and the real boundary is the Windows account another user does not have.

`NEXTAUTH_URL` is the base address Linkwarden builds its login redirects from, so it names
port 8085 and carries the `/api/v1/auth` suffix upstream requires; get it wrong and sign-in
fails like a bad password. Registration is open until step 7 closes it. Tell the user
`grep -E 'POSTGRES_PASSWORD|NEXTAUTH_SECRET' ~/selfhost/linkwarden/.env` prints both values
and that they belong in a password manager now.

## 5. compose.yml

```bash
cat > ~/selfhost/linkwarden/compose.yml <<'EOF'
# Linkwarden · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   setup and env vars . https://docs.linkwarden.app/self-hosting/setup
#   variable reference . https://docs.linkwarden.app/self-hosting/environment-variables
#
# Lives in ~/selfhost/linkwarden/; paths are relative to that folder, which lets
# one file work on macOS, Linux and Windows. MeiliSearch is absent on purpose:
# the search client starts only when MEILI_MASTER_KEY is set. Digests match
# compose.yml, read 2026-08-05. The database is a named volume, not a bind mount:
# PostgreSQL chowns its data directory to a uid Windows bind mounts cannot grant.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: linkwarden-db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - linkwarden-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other container.

  linkwarden:
    image: ghcr.io/linkwarden/linkwarden:v2.16.0@sha256:d805877fb707d160b809027c302f84cfba11a248d7fdc12de90b4791f98e6b55
    container_name: linkwarden
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Built here, not in .env: compose expands ${...} in this file.
      DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
    volumes:
      # Archives, screenshots, PDFs, uploads. STORAGE_FOLDER defaults to `data`
      # under the working directory /data, hence /data/data.
      - ./data:/data/data
    ports:
      # Loopback only. Nothing outside this computer can reach 8085.
      - "127.0.0.1:8085:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  linkwarden-pgdata:
EOF
cd ~/selfhost/linkwarden && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, on loopback.

## 6. Nothing is public

Nothing here is reachable from outside this computer. That is the shape of this path, not a
gap in it. State all four:

- The only published port is `127.0.0.1:8085`. A program on this machine can connect to it;
  a laptop on the same wifi cannot, nothing listens on the network address.
- There is no domain and no certificate, because there is nothing to certify. Browsers
  treat `http://localhost` as a secure context, so in-page crypto works over plain HTTP.
- The database publishes no port. The app container reaches it, nothing else does.
- Any browser here reaches http://localhost:8085, the Linkwarden extension included. A
  phone cannot, on any network, and nothing changes that.

## 7. Start and verify

On macOS and Windows the containers get the VM's memory, not the machine's:

```bash
docker info --format '{{.MemTotal}}'
```

Divide by 1048576. Under 2048, STOP: have the user raise Docker Desktop's memory limit in
Settings, Resources, and confirm Docker restarted.

The first boot is slow: Prisma applies the whole schema before Next.js answers, so refused
connections for the first few minutes are normal.

```bash
cd ~/selfhost/linkwarden
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sSL -o /dev/null -w '%{http_code}' http://localhost:8085/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL http://localhost:8085/ | grep -ci 'linkwarden'
```

Assert: the loop ends printing `200`, and the second command prints a number above `0`,
because `Linkwarden` appears in the served document. Print what you received. If the loop
runs out, stop, run `docker compose logs --tail 50 linkwarden` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a database that never
reports healthy points at step 5, an app log still in migrations wants time. The first
screen is a login form with a username, a password, and a link to create an account.

STOP: tell the user to open http://localhost:8085/register in a browser, create their
account, and wait. Do not continue until they confirm they can sign in.

Then close registration. A restart is not enough: upstream documents that a changed `.env`
needs the containers recreated. macOS `sed` refuses a bare `-i`, hence `-i.bak`, `rm` and
`chmod`.

```bash
cd ~/selfhost/linkwarden
sed -i.bak 's/^NEXT_PUBLIC_DISABLE_REGISTRATION=false$/NEXT_PUBLIC_DISABLE_REGISTRATION=true/' .env
rm -f .env.bak
chmod 600 .env
grep NEXT_PUBLIC_DISABLE_REGISTRATION .env
docker compose down
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sSL -o /dev/null -w '%{http_code}' http://localhost:8085/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
```

STOP: tell the user to sign out, try to create a second account at
http://localhost:8085/register, and confirm it is refused. Do not continue until they
confirm the refusal. Assert: the grep printed `true`, the loop printed `200`, and the user
confirmed the refusal, all three. A running container is not success.

## 8. First backup and restore

Two artifacts: the database holds links, tags and the account, `data` the archived copies
no dump contains.

```bash
cd ~/selfhost/linkwarden
docker compose exec -T postgres pg_dump -U postgres -d postgres | gzip > backups/linkwarden-db-$(date +%F).sql.gz
tar -czf backups/linkwarden-files-$(date +%F).tar.gz data .env
ls -lh backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently, so it is dumped rather than copied off
disk. On Linux, if `tar` reports a permission error inside `data`, run it again with
`sudo`: those files belong to the container's uid.

A backup on the same disk is not a backup, and here the disk and the computer fail
together: one dead SSD takes both. Ask the user once for a folder that leaves this
computer: one a sync service watches, iCloud Drive, OneDrive, Dropbox, or a mounted USB
stick, under /Volumes on macOS, usually /media on Linux, and a drive letter in Git Bash,
where `D:\backups` is typed `/d/backups`. Say plainly that the archive carries `.env`, so
whatever holds it holds the database password and the signing secret: a USB stick or an
end-to-end encrypted folder unless they would trust that service with a password. Copy both
of today's files there with `cp` using the path they gave, then `ls -lh` it. Assert: both
appear there, with sizes.

To restore: `docker compose down -v`, the one place `-v` belongs: it drops the database
volume; `rm -rf ~/selfhost/linkwarden/data`, with `sudo` on Linux; untar the file archive
into ~/selfhost/linkwarden first, since it carries the `.env` the database is built from;
`docker compose up -d postgres`; wait for `docker compose ps` to say healthy; pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U postgres -d postgres`; `docker compose up -d`. The
dump alone gives dead previews, the archive alone files nothing points at.

## 9. Updating later

New versions are listed at https://github.com/linkwarden/linkwarden/releases. Take both
backup artifacts first, then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/linkwarden
docker compose pull
docker compose up -d
docker compose logs --tail 30 linkwarden
```

Prisma runs new migrations on the way up, so watch that log until it stops moving. A
database written by a newer image will not load into an older one; back up first.

## 10. What will probably go wrong

The morning after. I rebooted, opened the browser out of habit, and http://localhost:8085
refused the connection outright, which reads worse than a slow page. Nothing was wrong:
Docker Desktop does not start with the machine unless told to, and
`restart: unless-stopped` only brings the containers back when the daemon returns. Opening
it restored everything, and its start-at-login setting spares the next one.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not add MeiliSearch. A third container and a third secret, for search inside archived
  pages, is not what this installs.
- Do not configure SMTP. Email verification and password reset stay off, survivable here.
- Do not set an AI tagging key. Automatic tagging sends saved page text to a third party,
  which is what this install exists to stop.
