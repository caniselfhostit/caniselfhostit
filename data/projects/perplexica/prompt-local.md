You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Vane v1.12.2 and the SearXNG it searches through under ~/selfhost/perplexica,
answering at http://localhost:8148.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install at all. The
project was Perplexica until it was renamed Vane, and 1.12.2 exists only under the new name. It
answers at http://localhost:8148, this computer and nowhere else: their phone cannot open it
and nothing runs while the lid is shut. And Vane is an interface, not a model: it searches with
SearXNG and writes the answer with a provider key they supply on its setup screen, metered per
token and billed to them.

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
distribution ID and codename print next, for step 2. Vane plus SearXNG needs 2048 MB of RAM
available and 5 GB free on the home disk, and both images publish amd64 and arm64. Every branch
prints free memory; on macOS and Windows it is the host's, and Docker Desktop takes its
allocation out of it. If available RAM is under 2048 MB or free disk is under 5 GB, print both
numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/perplexica/data ~/selfhost/perplexica/uploads ~/selfhost/perplexica/searxng ~/selfhost/perplexica/backups
ls -la ~/selfhost/perplexica
```

Assert: four directories, owned by the user. No ownership fix runs here. The Vane image declares
no unprivileged user, so on Linux the files it writes inside `data` belong to root and are read
with `sudo`; Docker Desktop handles that on macOS and Windows.

## 4. Secrets

One secret here. Generate it, print it nowhere, and keep it out of your summary and out of
any log line.

```bash
umask 077
cat > ~/selfhost/perplexica/.env <<EOF
SEARXNG_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/perplexica/.env
umask 022
ls -l ~/selfhost/perplexica/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same on
all three systems. SearXNG otherwise falls back to a key published in the settings file every
copy of the bundled image carries. The server path generates a second secret, the password on
its login box; this path has none, and step 6 is why. This is not a provider API key: that
arrives in the browser in step 7.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

SearXNG answers in HTML only until told otherwise, and Vane asks for JSON. Write that file
first:

```bash
cat > ~/selfhost/perplexica/searxng/settings.yml <<'EOF'
# SearXNG · the search backend here. Authored by caniselfhostit from
# https://docs.searxng.org/admin/settings/ and Vane's own install notes. No
# secret_key here: SEARXNG_SECRET in compose.yml overwrites it with the step 4
# value, so nothing in this file is confidential.
use_default_settings: true

search:
  # SearXNG answers 403 to a format it was not told to serve, and ships html
  # only, so without json every Vane search fails.
  formats:
    - html
    - json

server:
  # The shipped default, stated so an upstream change cannot turn it on.
  limiter: false

engines:
  - name: wolframalpha
    disabled: false
EOF
```

Then the compose file:

```bash
cat > ~/selfhost/perplexica/compose.yml <<'EOF'
# Vane · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   install and images . https://github.com/ItzCrazyKns/Vane/blob/v1.12.2/README.md
#   searxng in docker .. https://docs.searxng.org/admin/installation-docker.html
#   searxng settings ... https://docs.searxng.org/admin/settings/settings_server.html
#
# Perplexica was renamed Vane; 1.12.2 exists only under the new name. Two
# services on the computer you are sitting at, every path relative to
# ~/selfhost/perplexica/, which lets one file work on macOS, Linux and Windows.
# No named volumes: neither image chowns a directory it is handed. The slim
# image has no search engine in it; the full one bundles SearXNG and ships a
# fixed secret_key every copy of it shares. No provider API key is here: Vane
# asks for one on its setup screen and writes it to data/config.json. Digests
# read 2026-08-06, both images multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  searxng:
    image: searxng/searxng:2026.8.4-c63835bd2@sha256:f4c8e59de166ed71f6380c0847c312ca51f0d41996e31d0559163b6b09ecde52
    container_name: vane-searxng
    restart: unless-stopped
    environment:
      # Overwrites server.secret_key in settings.yml with the generated value.
      SEARXNG_SECRET: ${SEARXNG_SECRET}
    volumes:
      # Read only. The image owns /etc/searxng, so nothing is chowned here.
      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/healthz"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 8080 is reachable only from the other container.

  vane:
    image: itzcrazykns1337/vane:slim-v1.12.2@sha256:d2878cf9c91962aa3fc053b59bc9b89adcbdcaeb7ee36b54906e853464b2c190
    container_name: vane
    restart: unless-stopped
    environment:
      # Vane appends /search?format=json to this address on every query.
      SEARXNG_API_URL: http://searxng:8080
    volumes:
      # config.json, the SQLite database of searches, and uploaded files.
      - ./data:/home/vane/data
      - ./uploads:/home/vane/uploads
    ports:
      # Loopback only: no other device on the wifi can reach 8148.
      - "127.0.0.1:8148:3000"
    depends_on:
      searxng:
        condition: service_healthy
EOF
cd ~/selfhost/perplexica && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, three binds.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision.

- No DNS, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No login box. The server path puts one in front of this, because an open Vane on a public
  hostname is a stranger spending the user's money. Here the machine is the boundary.

8148 is bound to 127.0.0.1, this computer only. Not the user's phone, not a laptop on the same
wifi, not anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/perplexica/compose.yml
```

Assert: that prints `1`, the published port `"127.0.0.1:8148:3000"`. SearXNG publishes no host
port, so 8080 cannot appear. One quiet advantage here: searches leave from a home address, not
a datacenter, and the engines SearXNG asks are far less likely to refuse them.

## 7. Start and verify

The Vane image is around a gigabyte, so the first pull takes minutes.

```bash
cd ~/selfhost/perplexica
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8148/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8148/api/config | grep -oE '"setupComplete":[a-z]*|"searxngURL":"[^"]*"'
curl -sS http://localhost:8148/ | grep -c 'Welcome to'
docker compose exec -T searxng wget -qO- 'http://127.0.0.1:8080/search?q=self+hosting&format=json' | grep -c '"query"'
```

Assert all four, and print what you received for each. The loop ends printing `200`. The grep
prints `"setupComplete":false` and the searxng URL. The first grep
prints `1`, the setup screen. The SearXNG grep prints `1`, proving JSON is enabled and step 5's
settings file was read; a `403` means it was not. If any of the four misses, stop, run
`docker compose logs --tail 40 vane` and `docker compose logs --tail 20 searxng`, and name the
likely cause. If `port is already allocated` came back, find what holds 8148 with
`lsof -nP -iTCP:8148 -sTCP:LISTEN` and stop until the user frees it.
A running container is not success.

STOP: tell the user to open http://localhost:8148 and wait. Do not continue until they confirm.
The first screen reads `Welcome to Vane` over `Web search, reimagined`, then the setup wizard
asks for a model provider. Tell them to paste their own provider API key into it, finish the
wizard, and run one search. Do not report success until they confirm an answer came back with
numbered citations. That key is theirs and billed to their account; never ask for it.

## 8. First backup and restore

One archive, and the container stops for it: past searches are a SQLite file, and a copy taken
mid-write is not one.

```bash
cd ~/selfhost/perplexica
docker compose stop vane
tar -C ~/selfhost/perplexica -czf ~/selfhost/perplexica/backups/perplexica-$(date +%F).tar.gz data uploads searxng .env compose.yml
docker compose start vane
ls -lh ~/selfhost/perplexica/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds. On
Linux the `data` files belong to root, so `Cannot open: Permission denied` from `tar` means
running that one line with `sudo`.

The archive holds `data/config.json`, and therefore the provider API key, so it is as sensitive
as a password file. It sits on the same disk as the data, which is not a backup: on a laptop
the disk and the machine fail together. Ask the user for a destination that leaves this
computer, a folder their sync service watches or a USB stick, and copy it there with `cp`. In
Git Bash a Windows drive is `/d/Backups`. Assert: the user confirms the filename is there. If
they have nowhere, say plainly that this has no backup.

To restore: `cd ~/selfhost/perplexica`, `docker compose down`, `rm -rf data uploads`, untar the
archive back into ~/selfhost/perplexica, then `docker compose up -d` and re-run step 7's four
asserts. That is the whole disaster plan.

## 9. Updating later

Vane releases are at https://github.com/ItzCrazyKns/Vane/releases, and a slim tag is a release
tag with `slim-` in front. SearXNG publishes a dated tag most days at
https://hub.docker.com/r/searxng/searxng/tags. Back up first, then edit the `image:` line you
are changing in ~/selfhost/perplexica/compose.yml to its new tag and digest:

```bash
cd ~/selfhost/perplexica
docker compose pull
docker compose up -d
docker compose logs --tail 30 vane
```

Move the two images on their own schedules. Vane migrates its database on the way up, so watch
that log until it settles.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8148, and got a connection error that read
like a lost install. It was not: Docker Desktop had not started with the session, so
nothing was listening on 8148 until it did. `restart: unless-stopped` only acts once the Docker
daemon is up. Turn on start-at-login, and after a reboot run
`cd ~/selfhost/perplexica && docker compose up -d` before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8148 to 0.0.0.0 so a phone on the wifi can reach it. Vane has no login of its
  own, and that puts a key-spending window on every network this machine joins.
- Do not switch to the full Vane image for its bundled SearXNG. That image carries a fixed key
  every copy of it shares.
- Do not put a provider API key in `.env` or compose.yml. It belongs on the setup screen.
