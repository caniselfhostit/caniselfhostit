You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Meilisearch 1.52.0 under ~/selfhost/meilisearch, answering at http://localhost:8203.

## 1. Preflight

Say this to the user before anything installs. This is a search API on this computer only:
http://localhost:8203 is unreachable from a phone or another laptop. What they get is an
engine their local app can index and query while they develop, not a shared production API.
There is no browser sign-in to finish.

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
distribution ID and codename print next, for step 2. Meilisearch needs 1024 MB of RAM available
and 10 GB free on the home disk, and the image publishes amd64 and arm64. Every branch prints
free memory; on macOS and Windows Docker Desktop takes its allocation out of the host figure.
If available RAM is under 1024 MB or free disk is under 10 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/meilisearch/data ~/selfhost/meilisearch/backups
ls -la ~/selfhost/meilisearch
```

Assert: `data` and `backups` exist. Index files land under `data/` after documents are added.

## 4. Secrets

One secret: the master key. Generate it here. Do not print it into chat.

```bash
umask 077
cat > ~/selfhost/meilisearch/.env <<EOF
MEILI_MASTER_KEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/meilisearch/.env
umask 022
ls -l ~/selfhost/meilisearch/.env
```

Assert: mode `-rw-------` (advisory on Windows NTFS). Tell the user to read it with
`grep MEILI_MASTER_KEY ~/selfhost/meilisearch/.env` when they wire an app. Never put the
master key in a browser; use a search-scoped key from `/keys` for frontends.

## 5. compose.yml

```bash
cat > ~/selfhost/meilisearch/compose.yml <<'EOF'
# Meilisearch · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker .............. https://www.meilisearch.com/docs/guides/misc/docker
#   security ............ https://www.meilisearch.com/docs/learn/security/basic_security
#   configuration ....... https://www.meilisearch.com/docs/resources/self_hosting/configuration/reference
#   license ............. https://github.com/meilisearch/meilisearch/blob/v1.52.0/LICENSE
#
# One container on the computer you are sitting at. Paths are relative to
# ~/selfhost/meilisearch/. MEILI_MASTER_KEY comes from ./.env. Tag and digest
# are the v1.52.0 release read from Docker Hub on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  meilisearch:
    image: getmeili/meilisearch:v1.52.0@sha256:d36e713e8f89483af1ab0d72011bbd503f5ab100b68ccbfad51c39e3f0a0567d
    container_name: meilisearch
    restart: unless-stopped
    env_file: ./.env
    environment:
      MEILI_ENV: production
      MEILI_NO_ANALYTICS: "true"
    volumes:
      - ./data:/meili_data
    ports:
      # Loopback only: no other device on the wifi can reach 8203.
      - "127.0.0.1:8203:7700"
EOF
cd ~/selfhost/meilisearch && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Firewall

Nothing to open. Confirm loopback binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/meilisearch/compose.yml
```

Assert: that prints `1`. Do not rebind to `0.0.0.0`.

## 7. Start and verify

```bash
cd ~/selfhost/meilisearch
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8203/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8203/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8203/indexes
MASTER=$(grep MEILI_MASTER_KEY ~/selfhost/meilisearch/.env | cut -d= -f2-)
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${MASTER}" http://localhost:8203/indexes
curl -sS -H "Authorization: Bearer ${MASTER}" http://localhost:8203/keys | head -c 400; echo
unset MASTER
```

Assert: health is 200; unauthenticated `/indexes` is `401`; authenticated `/indexes` is `200`;
`/keys` returns JSON listing default keys. Print the codes, not the master key. If the 401 is
missing, the master key did not load: check `.env` and recreate it from step 4.

STOP: tell the user there is no sign-in UI, that apps talk HTTP with Bearer tokens, and that
they should store the master key offline and create a search key via `/keys` for any browser
code. Do not continue until they confirm.

Sample index handoff:

```bash
MASTER=$(grep MEILI_MASTER_KEY ~/selfhost/meilisearch/.env | cut -d= -f2-)
curl -sS -X POST http://localhost:8203/indexes \
  -H "Authorization: Bearer ${MASTER}" \
  -H 'Content-Type: application/json' \
  --data-binary '{"uid":"movies","primaryKey":"id"}'
curl -sS -X POST 'http://localhost:8203/indexes/movies/documents' \
  -H "Authorization: Bearer ${MASTER}" \
  -H 'Content-Type: application/json' \
  --data-binary '[{"id":1,"title":"Carol"},{"id":2,"title":"Wonder Woman"}]'
unset MASTER
```

## 8. First backup and restore

```bash
cd ~/selfhost/meilisearch
docker compose stop
tar -C ~/selfhost/meilisearch -czf ~/selfhost/meilisearch/backups/meilisearch-$(date +%F).tar.gz data .env compose.yml
docker compose start
ls -lh ~/selfhost/meilisearch/backups/
```

Assert: the archive exists and is non-empty. Print its size. It holds the master key; treat it
as secret. Ask the user for a destination that leaves this computer and copy it with `cp`.

To restore: `docker compose down`, remove `data`, untar into ~/selfhost/meilisearch, then
`docker compose up -d`. `data/` is the indexes; `.env` is the master key; they travel together.

## 9. Updating later

New versions are at https://github.com/meilisearch/meilisearch/releases. Take a backup first,
then edit the image line in ~/selfhost/meilisearch/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/meilisearch
docker compose pull
docker compose up -d
docker compose logs --tail 30 meilisearch
```

Re-run step 7's health and 401 checks before calling the update done.

## 10. What will probably go wrong

You will wire the master key into a React demo because it is the only credential you have and
search starts working. Anyone who opens the page then holds a key that can wipe indexes.
Create a search-scoped key from `/keys` for the browser and keep the master key on the server
side only. If you already pasted it into client code, rotate the master key in `.env` and
restart.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8203 to 0.0.0.0.
- Do not leave `MEILI_MASTER_KEY` empty.
