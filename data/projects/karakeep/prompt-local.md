You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Karakeep 0.33.2 under ~/selfhost/karakeep, answering at http://localhost:8182.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Karakeep is a capture-everything inbox and most people capture from a phone. This one
answers at http://localhost:8182, this computer and nothing else, so the iOS and Android apps
cannot reach it. What is left is the browser extension and archives on their own disk.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. Karakeep needs 4096 MB of RAM available and
20 GB free on the home disk, and all three images publish amd64 and arm64. On macOS and Windows
that memory figure is the host's, and Docker Desktop takes its slice out of it. Under either
floor, print both numbers and stop.

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
mkdir -p ~/selfhost/karakeep/data ~/selfhost/karakeep/meili ~/selfhost/karakeep/backups
ls -la ~/selfhost/karakeep
```

Assert: `ls -la` shows `data`, `meili` and `backups`. No ownership fix is needed: both images
that write to disk run as root.

## 4. Secrets

Two secrets. `NEXTAUTH_SECRET` signs the session tokens; `MEILI_MASTER_KEY` is the only
credential the search engine accepts. Upstream documents the generator below for both, base64
for the first and alphanumerics only for the second, and Git Bash ships openssl. Generate both
here and print neither.

```bash
umask 077
cat > ~/selfhost/karakeep/.env <<EOF
NEXTAUTH_URL=http://localhost:8182
DISABLE_SIGNUPS=false
NEXTAUTH_SECRET=$(openssl rand -base64 36)
MEILI_MASTER_KEY=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9')
EOF
chmod 600 ~/selfhost/karakeep/.env
umask 022
ls -l ~/selfhost/karakeep/.env
```

Assert: mode `-rw-------`. On Windows those bits are advisory and the real boundary is the
user's account. Read both with `grep -E 'NEXTAUTH_SECRET|MEILI' ~/selfhost/karakeep/.env`.

## 5. compose.yml

```bash
cat > ~/selfhost/karakeep/compose.yml <<'EOF'
# Karakeep · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.karakeep.app/installation/docker
#   configuration ...... https://docs.karakeep.app/configuration/environment-variables
#   minimal install .... https://docs.karakeep.app/installation/minimal-install
#   image build ........ https://github.com/karakeep-app/karakeep/blob/v0.33.2/docker/Dockerfile
#
# Three services on the computer you are sitting at. Paths are relative to
# ~/selfhost/karakeep/, so one file works on macOS, Linux and Windows, and both
# stay bind mounts so you can open your archives in Finder or Explorer. Both
# images that write to disk run as root in their containers, so no chown is
# needed. `web` is the all-in-one image: app, workers and migration under s6,
# SQLite in /data. `chrome` renders and screenshots pages. `meilisearch` is the
# search engine, without which upstream says search is disabled completely,
# pinned to the 1.41.0 Karakeep is built against rather than the newer line on
# Meilisearch's own page here. Digests read 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  meilisearch:
    image: getmeili/meilisearch:v1.41.0@sha256:860fa4baed04ae1c235de870edab0c8006227546dea1bbb6411fbfc5e27cf1db
    container_name: karakeep-meilisearch
    restart: unless-stopped
    environment:
      # Production mode refuses to start without a master key.
      MEILI_ENV: production
      MEILI_MASTER_KEY: ${MEILI_MASTER_KEY}
      MEILI_NO_ANALYTICS: "true"
    volumes:
      # The index. Rebuilt from the database, so step 8 leaves it out.
      - ./meili:/meili_data
    # No `ports:`: 7700 is reachable only from the web container.

  chrome:
    image: ghcr.io/karakeep-app/karakeep-chrome:151.0.7922.47-r1@sha256:5b19bbb160e9ff60681a3abd97e1c4ec9f64212301410de658c3900ab7ef31e7
    container_name: karakeep-chrome
    restart: unless-stopped
    init: true
    command:
      - --disable-gpu
      - --disable-dev-shm-usage
      - --hide-scrollbars
      - --disable-blink-features=AutomationControlled
      - --window-size=1440,900
    # No `ports:` and no volume: 9222 remote-controls a browser with no
    # credential, and only the web container is on this network.

  web:
    image: ghcr.io/karakeep-app/karakeep:0.33.2@sha256:b069e4307dec06ea06d16989c6861c30a1ff208568be44ed5fb5d422cd3e950c
    container_name: karakeep
    restart: unless-stopped
    env_file: ./.env
    environment:
      MEILI_ADDR: http://meilisearch:7700
      BROWSER_WEB_URL: http://chrome:9222
      # Upstream's compose says DON'T CHANGE THIS. The mount moves.
      DATA_DIR: /data
      # The image ships debug. `info` is the quietest level it defines.
      LOG_LEVEL: info
    volumes:
      # The SQLite database and every archived asset.
      - ./data:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8182.
      - "127.0.0.1:8182:3000"
    # Start ordering only: web connects to both lazily and retries.
    depends_on:
      - meilisearch
      - chrome
EOF
cd ~/selfhost/karakeep && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`, with no warning that `MEILI_MASTER_KEY` is unset. Compose
reads it from the .env beside this file, so run compose from ~/selfhost/karakeep.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. A certificate attests a public name that
nothing here has, and browsers treat http://localhost as secure anyway.

8182 is bound to 127.0.0.1, this computer only: no phone, no laptop on the wifi, nobody on the
internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/karakeep/compose.yml
```

Assert: that prints `1`, the single published port. The other two have no `ports:` line, and
9222 is the one that matters, because it remote-controls a browser with no credential.

## 7. Start and verify

The web image runs the migration, the app and the workers together under s6, so the first boot
writes the schema before it answers. The pull is about a gigabyte, hence the loop.

```bash
cd ~/selfhost/karakeep
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8182/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8182/api/health; echo
curl -sSL http://localhost:8182/signin | grep -c 'Welcome Back'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8182/api/v1/bookmarks
docker compose exec -T web curl -sS -o /dev/null -w '%{http_code}\n' http://meilisearch:7700/indexes
curl -sSL http://localhost:8182/signup | grep -c 'Create Your Account'
```

Assert all six, printing what you received. The loop ends at `200`. The health call prints
`{"status":"ok","message":"Web app is working"}`. The third is above `0`: `Welcome Back` is the
sign-in heading. The REST call prints `401`, and Meilisearch prints `401` from inside the compose
network. The last is above `0`: that is the open door.

On any miss, stop, run `docker compose logs --tail 40 web`, then
`docker compose logs --tail 20 meilisearch`, and name the earlier step. If
`port is already allocated` came back, find what holds 8182 with
`lsof -nP -iTCP:8182 -sTCP:LISTEN` and stop until the user frees it. A running container is not
success.

STOP: tell the user to open http://localhost:8182/signup, create their account with a password
their password manager generates, and wait. Do not continue until they confirm.

Once they confirm, shut the door and prove it is shut:

```bash
cd ~/selfhost/karakeep
sed -i.bak 's/^DISABLE_SIGNUPS=false$/DISABLE_SIGNUPS=true/' .env && rm -f .env.bak
docker compose up -d --force-recreate --no-deps web
sleep 20
docker compose exec -T web printenv DISABLE_SIGNUPS
curl -sSL http://localhost:8182/signup | grep -c 'Create Your Account'
```

Assert both: `printenv` prints `true` from inside the running container, and the grep prints
`0`. `sed -i.bak` works on BSD sed as well as GNU, and the recreate matters because compose reads
`.env` only when it creates a container.

STOP: tell the user to sign in, paste any article URL into the bookmark box, and watch that card
for a minute. Do not continue until they confirm they see a real title rather than a bare URL.

## 8. First backup and restore

One archive: the database and every archived asset, the environment file and the compose file.
The index is left out; Meilisearch rebuilds it with Reindex All Bookmarks.

```bash
cd ~/selfhost/karakeep
docker compose stop
tar -C ~/selfhost/karakeep -czf ~/selfhost/karakeep/backups/karakeep-$(date +%F).tar.gz data .env compose.yml
docker compose start
ls -lh ~/selfhost/karakeep/backups/
```

Assert: the archive exists and is non-empty. Print its size. The containers stop because a
SQLite file copied mid-write is not a backup.

That archive is on the same disk as the data, and on a laptop both fail together. Ask the user
for a destination that leaves this computer, a sync folder or a USB stick, and copy it with
`cp`. Assert: the user confirms it is there.

To restore: `cd ~/selfhost/karakeep`, `docker compose down`, `rm -rf data meili`, untar the
archive there, `mkdir -p meili`, then `docker compose up -d` and reindex. `.env` has to be back
before that first start, or a container created without `MEILI_MASTER_KEY` writes an index the
restored key cannot open. `data` holds every bookmark, highlight and archive.

## 9. Updating later

New versions are listed at https://github.com/karakeep-app/karakeep/releases. The release tag
carries a `v` and the image tag does not, so `v0.34.0` is image tag `0.34.0`. Back up, then edit
the `web` image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/karakeep
docker compose pull
docker compose up -d
docker compose logs --tail 30 web
```

Leave Meilisearch alone. It is pinned to 1.41.0 on purpose: upstream names that as the version
Karakeep is built against and advises against upgrading it alone, because a newer engine refuses
an older index and the recovery is erasing `data.ms` and reindexing everything. After any
update, re-run step 7's health check.

## 10. What will probably go wrong

The machine will sleep in the middle of a batch and you will think the import broke. I pasted
twenty links, closed the lid, opened it an hour later and half of them were still bare URLs.
Nothing had failed: no container runs while the computer is asleep, so the queue stops where it
was and starts again on wake, one link at a time, with a browser that has to boot first. The
other half is memory: Docker Desktop gets a fixed slice of RAM on macOS and Windows, and three
containers with a Chrome in one will find the edge of a small one, after which the crawl worker
dies quietly and the card stays empty. Leave the machine awake for the first import, and raise
that limit before debugging.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8182 to 0.0.0.0 so a phone on the wifi can reach it. That publishes an app which
  fetches arbitrary URLs to every network this machine joins.
- Do not set `OPENAI_API_KEY` or `OLLAMA_BASE_URL`, and do not turn on
  `CRAWLER_FULL_PAGE_ARCHIVE`, `CRAWLER_STORE_PDF` or `CRAWLER_VIDEO_DOWNLOAD`. The first bills
  the user's card, the rest fill their disk.
