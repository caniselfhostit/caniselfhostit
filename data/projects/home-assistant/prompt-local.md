You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Home Assistant 2026.7.4 under ~/selfhost/home-assistant, answering at
http://localhost:8107.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Home Assistant will answer at http://localhost:8107, which means this computer and nothing
else, so their phone cannot reach it and the companion app cannot connect to it. Every
automation they write runs only while this machine is awake, so a laptop that closes at night
is a house that stops automating at night. And because the container sits behind Docker's
bridge rather than on the home network, the discovery that finds a Hue bridge or a Sonos
speaker on its own will not fire; integrations they add by typing an address or signing into a
cloud account still work. What they get today is a real Home Assistant to learn on, keep
history in, and move to a small always-on machine later.

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
distribution ID and codename print next, for step 2. Home Assistant needs 1024 MB of RAM
available and 5 GB free on the home disk, and the 2026.7.4 image is published for amd64 and
arm64. On macOS and Windows the figure printed is the host's, and Docker Desktop's virtual
machine takes its allocation out of it. If available RAM is under 1024 MB or free disk is under
5 GB, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/home-assistant/config ~/selfhost/home-assistant/backups
ls -la ~/selfhost/home-assistant
```

Assert: `ls -la` shows `config` and `backups`, both owned by the user. Nothing else is created
here. Home Assistant writes its own `configuration.yaml` into `config` on the first start, and
this path leaves it alone: there is no reverse proxy on this machine, so there is nothing the
file has to be told about before anything can reach it.

On Linux the container runs as root, so the files it writes into `config` will belong to root
on this machine and reading them takes `sudo`. On macOS and Windows, Docker Desktop's file
sharing handles that and the files stay the user's.

## 4. Secrets

Nothing is generated here and there is no `.env` file. Home Assistant's only credential is the
owner account, and the user creates it in a browser at step 7, so this block runs no commands.

Say two things to the user. First: between the container starting and that account existing,
the onboarding form is open to anyone with a session on this computer, and the first person
through it owns the house, which is why step 7 makes that window short and stops there.
Second, on Windows: mode bits on NTFS are advisory, so no `chmod` protects anything here; the
user's own Windows account is the real boundary on a single-user machine, and everything this
install writes sits in their home directory.

## 5. compose.yml

```bash
cat > ~/selfhost/home-assistant/compose.yml <<'EOF'
# Home Assistant · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   container install .. https://www.home-assistant.io/installation/linux/
#   http integration ... https://www.home-assistant.io/integrations/http/
#   remote access ...... https://www.home-assistant.io/docs/configuration/remote/
#
# One container on the computer you are sitting at. Every path is relative to
# ~/selfhost/home-assistant/, which lets one file work on macOS, Linux and
# Windows. There is no named volume here: nothing in this install chowns its
# own data directory, so ./config stays a bind mount and you can open it in
# Finder or Explorer. Upstream's example sets network_mode: host and
# privileged: true to reach devices on the local network; this file keeps the
# bridge and one loopback port, because host networking would put Home
# Assistant on every network this machine joins and does nothing at all under
# Docker Desktop, where the container runs inside a virtual machine. Same
# 2026.7.4 tag and digest as the server file, read from ghcr.io on 2026-08-06,
# published for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:2026.7.4@sha256:5a531753cea96444200158fc2b0ac7ccd739291ec50414877b396de6e0bb29b3
    container_name: homeassistant
    restart: unless-stopped
    environment:
      # This labels the container's log timestamps. Home Assistant's own time
      # zone is a separate setting, chosen during onboarding.
      TZ: UTC
    volumes:
      # The image runs as root, so on Linux the files under ./config belong to
      # root on the host. Docker Desktop handles that for macOS and Windows.
      - ./config:/config
    ports:
      # Loopback only: no other device on the wifi can reach 8107, and 8123 is
      # the port Home Assistant listens on inside the container.
      - "127.0.0.1:8107:8123"
EOF
cd ~/selfhost/home-assistant && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8107 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a tablet
on the same wifi, nor anyone on the internet. For a home dashboard that is the sharpest edge of
this path, and it is the shape of the trade rather than a defect in it. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/home-assistant/compose.yml
```

Assert: one line, `- "127.0.0.1:8107:8123"`.

## 7. Start and verify

The first start is slow. Home Assistant installs the Python requirements for the integrations
it loads by default before it serves anything. The loop below waits for it.

```bash
cd ~/selfhost/home-assistant
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8107/api/onboarding); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8107/api/onboarding
echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8107/api/
```

Assert all three, and print what you received for each: the loop ends on `200`; the onboarding
response contains `"step":"user","done":false`; the last command prints `401`, because that
endpoint needs a token and refusing without one is the security assert here. If the loop never
reaches `200`, run `docker compose logs --tail 40 homeassistant` and read it: on the first boot
the log is a long list of packages being installed, which is the container working rather than
failing. If `port is already allocated` came back, find what holds 8107
(`lsof -nP -iTCP:8107 -sTCP:LISTEN`, `ss -ltnp | grep 8107` on Linux,
`netstat -ano | findstr :8107` on Windows) and stop until the user frees it. A running
container is not success.

The first screen at http://localhost:8107 shows the heading `Welcome!` and a button reading
`Create my smart home`. Until someone submits that form, anyone with a session on this
computer can.

STOP: tell the user to open http://localhost:8107 now, create the owner account, and save the
password in their password manager. Wait until they confirm.

Then prove it closed:

```bash
curl -sS http://localhost:8107/api/onboarding
echo
```

Assert: the response now contains `"step":"user","done":true`. Both asserts must pass before
you report success.

## 8. First backup and restore

Take the backup now, before the user adds a single device. Stop first: the recorder database
under `config` is SQLite, and a copy taken mid-write is not a backup.

```bash
cd ~/selfhost/home-assistant
docker compose stop
tar -C ~/selfhost/home-assistant -czf ~/selfhost/home-assistant/backups/home-assistant-$(date +%F).tar.gz config compose.yml
docker compose start
ls -lh ~/selfhost/home-assistant/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds. On
Linux this needs `sudo tar` if the container has already written root-owned files into
`config`; run it again with `sudo` and the archive belongs to root, which is fine.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`; confirm the destination exists before
copying. Assert: the user confirms the filename is listed there. If they have nowhere to put
it, say plainly that this install has no backup.

To restore: `docker compose down`, `rm -rf ~/selfhost/home-assistant/config`,
`tar -C ~/selfhost/home-assistant -xzf` the archive, then `docker compose up -d`. Those four
commands are the whole disaster plan, and on Linux the middle two take `sudo` for the same
reason the backup did. The part that matters most is the `.storage` directory
inside `config`: it holds the owner account and the token for every integration ever linked,
and losing it means linking all of them again by hand.

## 9. Updating later

New versions are listed at https://github.com/home-assistant/core/releases. Take a backup
first, then edit the image line in ~/selfhost/home-assistant/compose.yml to the new tag and
digest:

```bash
cd ~/selfhost/home-assistant
docker compose pull
docker compose up -d
docker compose logs --tail 30 homeassistant
```

Home Assistant migrates its own storage on the way up, so watch that log until it settles, then
re-run step 7's check before calling the update done.

## 10. What will probably go wrong

I closed the laptop at eleven, opened it at seven, and the automation that was supposed to turn
the lamps off at midnight had never run. Nothing was broken and nothing recovered it, because
Home Assistant was not running: the machine was asleep, and a schedule that passes while the
container is stopped is a schedule that does not fire. `restart: unless-stopped` only acts once
the Docker daemon is up, so the same thing happens after a reboot until Docker Desktop starts.
Turn on its start-at-login setting, and treat any automation that has to happen at a fixed time
as the reason to move this to a machine that stays on.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8107 to 0.0.0.0 or set `network_mode: host` so a phone or a device-discovery
  scan can reach it. Host networking does nothing under Docker Desktop, where the container is
  inside a virtual machine, and on Linux it puts a half-configured Home Assistant on every
  network this laptop joins.
- Do not install HACS or any add-on. Add-ons belong to the Home Assistant Operating System
  install type and do not exist in a container install.
- Do not configure the Alexa or Google Assistant integrations. Both need a public address that
  this install does not have.
