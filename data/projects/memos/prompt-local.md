You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Memos 0.30.0 under ~/selfhost/memos, answering at http://localhost:8131.

## 1. Preflight

Say all three of these to the user before step 2 runs; together they decide whether they want
this install at all. Memos is a capture stream: short markdown notes with tags, newest first,
read and written in a browser. On this path it answers only at http://localhost:8131, so the
phone they would reach for at the moment worth writing down cannot open it, and neither can a
laptop on the same wifi. And nothing here is end-to-end encrypted: every entry is a row in a
SQLite file on this disk, which is a different promise from a journal that syncs encrypted to a
company's servers, not a smaller one.

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
distribution ID and codename print next, for step 2. Memos needs 512 MB of RAM available and
5 GB free on the home disk, and the image publishes amd64 and arm64. Every branch prints free
memory, so one floor covers all three; on macOS and Windows that is the host's, and Docker
Desktop takes its share out of it. If available RAM is under 512 MB or free disk is under 5 GB,
print both numbers and stop. Do not install and hope.

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

Three folders and one configuration file. That file is the security decision here, so it is
written before the container has ever run.

```bash
mkdir -p ~/selfhost/memos/data ~/selfhost/memos/config ~/selfhost/memos/backups
cat > ~/selfhost/memos/config/memos-instance-setting-general.json <<'EOF'
{
  "key": "GENERAL",
  "generalSetting": {
    "disallowUserRegistration": true
  }
}
EOF
chmod 644 ~/selfhost/memos/config/memos-instance-setting-general.json
ls -la ~/selfhost/memos ~/selfhost/memos/config
```

Assert: `ls -la` shows `data`, `config` and `backups`, and the JSON file at mode `644`. No
ownership fix runs here: the image entrypoint starts as root, hands its data directory to uid
10001 and re-execs as that user, which is why step 5 pins no `user:`. On Linux that leaves
`data` owned by 10001, which step 8 accounts for.

## 4. Secrets

No secret is generated for this install and there is no `.env` file. Memos keeps its session key
inside its database, and the only credential a human ever types is the administrator account
created in a browser at step 7. That is why this block has nothing to run.

Step 3 replaces the usual scramble. Most first-run installs leave registration open between the
container starting and a human claiming the account. Here `disallowUserRegistration` is on before
the first request arrives, and the first account still gets through, because an instance with
zero users takes the setup path rather than the registration path. Step 7 asserts both halves.
Adding a second person later means creating the account for them as administrator.

## 5. compose.yml

```bash
cat > ~/selfhost/memos/compose.yml <<'EOF'
# Memos · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker compose ....... https://www.usememos.com/docs/deploy/docker-compose
#   configuration ........ https://www.usememos.com/docs/configuration/environment-variables
#   security ............. https://www.usememos.com/docs/configuration/security
#   provisioning ......... https://github.com/usememos/memos/blob/v0.30.0/docs/configuration-provisioning.md
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/memos/, so one file works on macOS, Linux and Windows and you can
# open data/ in Finder or Explorer. No named volume and no `user:` line: the
# image entrypoint starts as root, hands /var/opt/memos to uid 10001 and
# re-execs as that user, which on Linux leaves ./data owned by 10001, so a
# host-side backup may need sudo. MEMOS_INSTANCE_URL is absent because upstream
# treats an instance without one as private. The read-only /etc/secrets bind
# carries one deployment configuration file, written in step 3, that turns
# self-registration off before the first request is served. Digest read
# 2026-08-06; amd64, arm64 and arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  memos:
    image: neosmemo/memos:0.30.0@sha256:71a5b4738d1bed96e92112004054f0888e92791b64eb78afd79077c96e6f9327
    container_name: memos
    restart: unless-stopped
    environment:
      MEMOS_PORT: "5230"
      MEMOS_DATA: /var/opt/memos
      MEMOS_DRIVER: sqlite
      # No MEMOS_INSTANCE_URL here. Empty means private, and private means an
      # anonymous visitor gets the sign-in page and nothing else.
    volumes:
      # memos_prod.db plus the assets/ folder that attachments land in.
      - ./data:/var/opt/memos
      # Deployment configuration, read once at start-up and never written to.
      - type: bind
        source: ./config
        target: /etc/secrets
        read_only: true
    ports:
      # Loopback only: no other device on the wifi can reach 8131.
      - "127.0.0.1:8131:5230"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:5230/healthz"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd ~/selfhost/memos && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one folder you can open.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the sign-in form works without one.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8131 is bound to 127.0.0.1, this computer only. For a journal that is the sharp edge of this
path: the phone in a pocket cannot add an entry. That is the trade, not a fault. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/memos/compose.yml
```

Assert: two lines, the container's own health check and the published port
`- "127.0.0.1:8131:5230"` on this machine.

## 7. Start and verify

```bash
cd ~/selfhost/memos
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8131/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8131/healthz; echo
curl -sS http://localhost:8131/api/v1/instance/profile; echo
curl -sS http://localhost:8131/api/v1/instance/settings/GENERAL; echo
```

Assert all four, printing what you received for each: the loop ends on `200`; the health endpoint
answers `Service ready.`; the profile JSON contains `"version":"0.30.0"` and `"needsSetup":true`;
the settings JSON contains `"disallowUserRegistration":true`. Those last two are the security
assert here: registration is shut before any account exists. If the loop never reaches 200, stop,
run `docker compose logs --tail 40 memos`, and name the likely cause: a container that exits at
once is usually step 3, because a malformed file under that mount makes Memos refuse to start
rather than ignore it. If `port is already allocated` came back, find what holds 8131 with
`lsof -nP -iTCP:8131 -sTCP:LISTEN`, or `netstat -ano | findstr :8131` on Windows, and stop until
it is free. A running container is not success.

STOP: tell the user to open http://localhost:8131/auth/signup, create their account, put the
password in their password manager, and wait. Do not continue until they confirm. That exact path
matters: the sign-in page at http://localhost:8131 carries no sign-up link, because step 3 turned
registration off. The screen at /auth/signup reads `Set up your instance` above
`Create the administrator account for this instance.`, with a `First run` badge and a
`Create admin account` button.

Once they confirm:

```bash
curl -sS http://localhost:8131/api/v1/instance/profile; echo
```

Assert: the response now contains `"admin":` and no longer contains `"needsSetup":true`. That is
the setup path closed behind them. If it still prints `"needsSetup":true`, the account was not
created; do not go on.

## 8. First backup and restore

One archive: the database, the photos, the deployment configuration and the compose file. Take
it before the user writes anything they would miss.

```bash
cd ~/selfhost/memos
docker compose stop
tar -C ~/selfhost/memos -czf ~/selfhost/memos/backups/memos-$(date +%F).tar.gz data config compose.yml
docker compose start
ls -lh ~/selfhost/memos/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container stops on purpose for
about five seconds, because a SQLite database copied mid-write is not a backup. On Linux the
container took ownership of `data` at first start, so if tar reports `Permission denied`, rerun
the line with `sudo` and then `sudo chown "$USER" ~/selfhost/memos/backups/*.tar.gz`.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder a sync service
watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is `/d/Backups`,
not `D:\Backups`. Assert: the user confirms the filename is listed there. If they have nowhere,
say plainly that this install has no backup.

To restore: `cd ~/selfhost/memos`, `docker compose down`, `rm -rf data` (with `sudo` on Linux,
for the reason above), untar the archive back in, then `docker compose up -d`. Entries, tags and
accounts live in `data/memos_prod.db`, and photos are ordinary files under `data/assets`, so one
photo can be pulled out of the archive without restoring anything. That is the disaster plan.

## 9. Updating later

New versions are listed at https://github.com/usememos/memos/releases. Back up first, then edit
the image line in ~/selfhost/memos/compose.yml to the new tag and digest. The Docker Hub tag
drops the leading `v`: release `v0.31.0` is image tag `0.31.0`.

```bash
cd ~/selfhost/memos
docker compose pull
docker compose up -d
docker compose logs --tail 30 memos
```

Memos migrates its own database on the way up. Watch that log until it settles, then re-run
step 7's checks before calling this done.

## 10. What will probably go wrong

I wrote three entries on a Tuesday, shut the laptop, opened it on Wednesday, and got a browser
error page at http://localhost:8131 that read like the database was gone. Nothing was gone.
Docker Desktop had not started with the session, so nothing was listening on 8131, and
`restart: unless-stopped` does nothing until the Docker daemon is up. Turn on Docker Desktop's
start-at-login setting, and after any reboot run `cd ~/selfhost/memos && docker compose up -d`
before concluding a single entry is lost.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not set `MEMOS_INSTANCE_URL` and do not rebind 8131 to 0.0.0.0 so a phone on the same wifi
  can reach it. Together those put somebody's journal on every network this computer joins.
- Do not switch `MEMOS_DRIVER` to postgres or mysql. SQLite is the choice here, and it is what
  makes this one container and one folder to copy.
- Do not configure SMTP, an S3 bucket or an AI provider in the instance settings. Each is an
  account somewhere else, and the file written in step 3 owns the general settings group only.
