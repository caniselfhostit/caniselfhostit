You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install IT Tools 2024.10.22-7ca5933 under ~/selfhost/it-tools, answering at
http://localhost:8209.

## 1. Preflight

Why this path still matters: paste a JWT into a random "jwt debugger" website and you handed a
session to someone else's logs. The same tool running at localhost keeps the bytes on this
machine. That is the whole product value. There is still no multi-device sync, no team library and
no launcher integration; Raycast Pro is a different job.

If Docker Desktop was already installed but not running, step 2's `docker info` fails with a
connection error rather than "command not found". Start Docker Desktop and wait until it reports
running, then re-run `docker info` before continuing.

After step 7, bookmark http://localhost:8209/ in the browser profile you actually use for work.
A tool chest you never open is a container burning a little RAM for nothing. If you later want
the same UI on a VPS for phone access, use the server path on this page instead of rebinding the
local port.



Say this to the user before step 2 runs. This is a local utility chest: encoders, converters and
generators that run in the browser against code you host, so secrets need not go to a random
website. There is no account and no sync. The pinned tag `2024.10.22-7ca5933` was published
2024-10-22 (about 21 months before the 2026-08-07 check); release cadence is slow.

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

IT Tools needs 256 MB of RAM available and 2 GB free on the home disk. The image publishes amd64
and arm64. If available RAM is under 256 MB or free disk is under 2 GB, print both numbers and
stop. Do not install and hope.

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
mkdir -p ~/selfhost/it-tools/backups
ls -la ~/selfhost/it-tools
```

Assert: `backups` exists. There is no `data/` directory: the app is stateless on the server side.

## 4. Secrets

No secret is generated and there is no `.env` file. IT Tools has no accounts. On this local path
the UI is loopback-only, so the public-by-design risk of the VPS path does not apply the same
way. Still do not invent a login step.

## 5. compose.yml

```bash
cat > ~/selfhost/it-tools/compose.yml <<'EOF'
# IT Tools · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker run ......... https://github.com/CorentinTh/it-tools#self-host
#
# One service on the computer you are sitting at. Stateless static UI. Tag
# 2024.10.22-7ca5933 published 2024-10-22; digest read from Docker Hub on
# 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  it-tools:
    image: corentinth/it-tools:2024.10.22-7ca5933@sha256:8b8128748339583ca951af03dfe02a9a4d7363f61a216226fc28030731a5a61f
    container_name: it-tools
    restart: unless-stopped
    ports:
      # Loopback only: no other device on the wifi can reach 8209.
      - "127.0.0.1:8209:80"
EOF
cd ~/selfhost/it-tools && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, no volumes, no env file.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. 8209 is bound to 127.0.0.1 only. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/it-tools/compose.yml
```

Assert: that count is exactly `1`. The user's phone cannot reach it on the wifi unless they
rebind the port, which is out of scope.

## 7. Start and verify

```bash
cd ~/selfhost/it-tools
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8209/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sSL http://localhost:8209/ | grep -ciE 'it-tools|IT Tools|token|encode|hash|Base64'
docker compose ps
```

Assert: loop ends with `200` and the body grep count is greater than `0`. If the port is already
allocated, find what holds 8209 and stop until it is free. There is no sign-in step.

STOP: tell the user to open http://localhost:8209/, try one tool, and confirm the UI loads
without a login. Do not continue until they confirm.

## 8. First backup and restore

Stateless backup: compose only. No Caddyfile on this path, no data directory.

```bash
cd ~/selfhost/it-tools
tar -C ~/selfhost/it-tools -czf ~/selfhost/it-tools/backups/it-tools-$(date +%F).tar.gz compose.yml
ls -lh ~/selfhost/it-tools/backups/
```

Assert: archive exists and is non-empty. Print its size. Copy it off this computer if you care
about preserving the pin. To restore: untar `compose.yml`, `docker compose up -d`. There is no
user content on disk to lose.

## 9. Updating later

Releases: https://github.com/CorentinTh/it-tools/releases. This pin is from 2024-10-22; check for
a newer stable identity before assuming you are current. Backup compose, edit the image line to
the new tag and digest:

```bash
cd ~/selfhost/it-tools
docker compose pull
docker compose up -d
docker compose logs --tail 20 it-tools
```

Re-run step 7's checks. Do not float to `nightly` from this prompt without an explicit decision.

## 10. What will probably go wrong

You will assume the tools are "always the newest" because the container is healthy. The pin can
be more than a year old and still serve a fine UI. Check releases when a tool misbehaves or when
you care about a fix. Second: rebinding 8209 to all interfaces "so the phone can use it" puts a
password-free utility chest on every network this laptop joins. Keep loopback unless you have a plan.

Third: corporate proxies that break Docker pulls will fail step 7 before the UI ever loads. Fix
the proxy or pull on a network that can reach Docker Hub, then retry. Fourth: an old pin with a
known XSS in a client-side tool is still code that runs in your browser; when a new release
exists, prefer moving the pin over living on nostalgia.



## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS on this path.
- Do not rebind 8209 to 0.0.0.0.
- Do not invent accounts or a first-run wizard.
- Do not switch the image to `latest` or `nightly` without a deliberate pin decision.
