You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Crawl4AI 0.9.2 under ~/selfhost/crawl4ai, answering at http://localhost:8198.

## 1. Preflight

Say three things to the user before anything installs. One: this is a crawling API on this
computer only. http://localhost:8198 is unreachable from a phone or another laptop; they get an
endpoint their own scripts can call while they work, not a shared service, and there is no
sign-in to finish. Two: the token is not a nicety. The entrypoint binds the server to
container loopback whenever no credential is configured, so an install without a token publishes
a port that answers nothing. Step 4 generates it. Three: what they crawl is their responsibility.
The crawler does not consult robots.txt unless a request asks it to, and nothing here enforces a
site's terms of service.

Crawls also leave from this machine's own address rather than a datacenter range, which far less
of the web treats as hostile. The crawled site sees the household's address, which cuts both
ways.

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
distribution ID and codename print next, for step 2. Crawl4AI needs 4096 MB of RAM available and
15 GB free on the home disk, because the image carries a real Chromium. It publishes amd64 and
arm64, so Apple Silicon is fine. If available RAM is under 4096 MB or free disk is under 15 GB,
print both numbers and stop. On macOS and Windows, Docker Desktop takes its memory out of the
host figure and its default allocation is often under 4 GB: if the container is killed mid-crawl,
raise the memory limit in Docker Desktop's settings.

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
mkdir -p ~/selfhost/crawl4ai/backups
ls -la ~/selfhost/crawl4ai
```

Assert: `backups` exists. There is no `data` directory, which is deliberate: this compose file
mounts nothing. The crawl cache, the artifact store and the in-container Redis are disposable,
and a home bind mount would land on a uid the image does not run as.

## 4. Secrets

One secret: `CRAWL4AI_API_TOKEN`. Generate it here. Do not print it into chat.

```bash
umask 077
cat > ~/selfhost/crawl4ai/.env <<EOF
CRAWL4AI_API_TOKEN=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/crawl4ai/.env
umask 022
ls -l ~/selfhost/crawl4ai/.env
```

Assert: mode `-rw-------`. On Windows those mode bits are advisory; the file is still protected
by the user's own account, and on a single-user machine that is the real boundary. Tell the user
they read it back with `grep CRAWL4AI_API_TOKEN ~/selfhost/crawl4ai/.env`, and that it is
admin-scoped: there is no read-only key, and anyone holding it can make this computer fetch any
URL it can reach, including the home network.

## 5. compose.yml

```bash
cat > ~/selfhost/crawl4ai/compose.yml <<'EOF'
# Crawl4AI · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker guide ........ https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/README.md
#   server config ....... https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/config.yml
#   bind and auth ....... https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/entrypoint.sh
#   license ............. https://github.com/unclecode/crawl4ai/blob/v0.9.2/LICENSE
#
# One container on the computer you are sitting at. The image bakes Chromium in
# through Playwright and runs its own Redis on container loopback, so there is
# no second service and no database. CRAWL4AI_API_TOKEN comes from ./.env and is
# not optional: entrypoint.sh binds gunicorn to container loopback when no
# credential is set, and the published port would then reach nothing at all.
# GUNICORN_BIND is written out so the bind does not depend on IPv6 existing
# inside the container. Tag and digest are the 0.9.2 release read from Docker
# Hub on 2026-08-14; the manifest list carries linux/amd64 and linux/arm64.
#
# Nothing is mounted on purpose: the crawl cache, the artifact store and the
# Redis working directory live inside the container and are meant to be thrown
# away, and a home-directory bind mount would land on a uid the image does not
# run as anyway.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  crawl4ai:
    image: unclecode/crawl4ai:0.9.2@sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690
    container_name: crawl4ai
    restart: unless-stopped
    env_file: ./.env
    environment:
      # entrypoint.sh honours GUNICORN_BIND only when a credential is present.
      GUNICORN_BIND: "0.0.0.0:11235"
    # Chromium wants shared memory. Without this it dies on heavy pages.
    shm_size: "1gb"
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    pids_limit: 512
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11235/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    ports:
      # Loopback only: no other device on the wifi can reach 8198.
      - "127.0.0.1:8198:11235"
EOF
cd ~/selfhost/crawl4ai && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, no volumes, no database.

## 6. Nothing is public

Nothing to open, and nothing to certify. Everything binds to loopback: no domain, no certificate
because there is nothing to certify, and no other device can reach this, including the user's own
phone. That is the point of this path, not a defect. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/crawl4ai/compose.yml
```

Assert: that prints `1`. Do not rebind to `0.0.0.0` and do not forward a router port at it. An
open crawling API on a home line will fetch any URL a stranger names.

## 7. Start and verify

The first start pulls about 1.5 GB and launches Chromium, so allow a couple of minutes.

```bash
cd ~/selfhost/crawl4ai
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8198/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8198/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8198/md -H 'Content-Type: application/json' --data-binary '{"url":"https://example.com","f":"raw"}'
TOKEN=$(grep CRAWL4AI_API_TOKEN ~/selfhost/crawl4ai/.env | cut -d= -f2-)
curl -sS -X POST http://localhost:8198/md -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' --data-binary '{"url":"https://example.com","f":"raw"}' | head -c 300; echo
unset TOKEN
curl -sSL http://localhost:8198/playground/ | grep -c '<title>Crawl4AI Playground</title>'
```

Assert all five and print what each returned, never the token. The health loop ends on `200` and
the body contains `"status":"ok"`. The unauthenticated POST to `/md` prints `401`: that is the
security assert in this block. The authenticated POST returns JSON whose `markdown` field contains
`Example Domain`; `"f":"raw"` asks for the direct conversion, because the default readability
filter can prune a page this small down to nothing. The last command prints `1`.

If any assert misses, stop and run `docker compose logs --tail 40 crawl4ai`. A log line about
binding loopback only means `.env` did not load, which is step 4 or step 5. If `port is already
allocated` came back, find what holds 8198 (`lsof -nP -iTCP:8198 -sTCP:LISTEN` on macOS,
`ss -ltnp | grep 8198` on Linux, `netstat -ano | findstr :8198` on Windows) and stop.
A running container is not success.

STOP: tell the user to open http://localhost:8198/playground/, paste the token from
`grep CRAWL4AI_API_TOKEN ~/selfhost/crawl4ai/.env` into the token bar at the top right, press
Set, and confirm they can run one crawl from that page. Do not continue until they confirm. That
token lives in the tab's session storage only, so closing the tab clears it.

Once they confirm, run the core loop from the shell, which is what a script does:

```bash
TOKEN=$(grep CRAWL4AI_API_TOKEN ~/selfhost/crawl4ai/.env | cut -d= -f2-)
curl -sS -X POST http://localhost:8198/crawl \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary '{"urls":["https://example.com"],"crawler_config":{"type":"CrawlerRunConfig","params":{"check_robots_txt":true}}}' \
  | head -c 600; echo
unset TOKEN
```

Assert: the response starts `{"success":true` and the results array carries the crawled page.
That is the product: a URL in, structured JSON with a markdown field out. `check_robots_txt` is
there on purpose, because it defaults to false and the polite setting should be visible.

## 8. First backup and restore

There is no application state to archive. This service mounts no volumes, so the backup is the
two files that rebuild it: the token and the compose file. Say that, rather than letting the user
think an archive protects crawls.

```bash
cd ~/selfhost/crawl4ai
tar -C ~/selfhost/crawl4ai -czf ~/selfhost/crawl4ai/backups/crawl4ai-$(date +%F).tar.gz .env compose.yml
ls -lh ~/selfhost/crawl4ai/backups/
```

Assert: the archive exists and is non-empty. Print its size. It holds the API token, so treat it
as secret. A backup on the same disk is not a backup, and on a laptop the disk and the machine
fail together: ask for a destination off this computer, a synced folder or a USB stick, and copy
it there with `cp`.

To restore: recreate `~/selfhost/crawl4ai/backups`, untar the archive into `~/selfhost/crawl4ai`,
then `docker compose up -d` and re-run step 7's checks. Restoring `.env` before the first start
matters: a container that starts without the token binds loopback and answers nothing.

## 9. Updating later

New versions are listed at https://github.com/unclecode/crawl4ai/releases. The release tag
carries a leading `v` and the image tag does not, so release `v0.9.3` is image tag `0.9.3`. Back
up first, then edit the image line in ~/selfhost/crawl4ai/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/crawl4ai
docker compose pull
docker compose up -d
docker compose logs --tail 30 crawl4ai
```

Watch that log until it settles, then re-run step 7's health check, the unauthenticated 401 and
one real crawl. This project moves quickly and its server API has changed shape between minor
versions, so read the release notes.

## 10. What will probably go wrong

The container will look fine and answer nothing. I had a green `docker ps`, a clean log and a
connection reset on 8198, and I spent ten minutes blaming Docker Desktop before reading the
container's second line of output: no token, so it had bound its server to loopback inside the
container where a published port cannot reach it. Correct behaviour, and it looks exactly like a
broken install. If step 7 returns nothing rather than a 401, check `.env` first.

Two smaller ones. Docker Desktop does not start itself after a reboot on most machines, so the
morning after the install this endpoint is gone until the whale icon is back. And a crawl on a
laptop that sleeps does not pause politely, it fails: keep the lid open for the long ones.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not set `CRAWL4AI_HOOKS_ENABLED` or `CRAWL4AI_EXECUTE_JS_ENABLED`. Upstream's own source
  calls them an arbitrary-code and SSRF surface and ships them off.
- Do not add an LLM provider API key. This install runs the readability filter, which needs no
  model, and a key here is a bill the crawler can run up.
