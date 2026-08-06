You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Grist 1.7.17 under ~/selfhost/grist, answering at http://localhost:8101.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. The base will live at http://localhost:8101, which means this computer wherever it is
read, so a colleague they want to share a table with cannot open it and neither can their own
phone. What they get is a spreadsheet-database for one person, on one machine, that nobody
bills them for.

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
distribution ID and codename print next, for step 2. Grist needs 1024 MB of RAM available and
5 GB free on the home disk, and the image publishes amd64 and arm64. Every branch prints free
memory, so one floor covers all three; on macOS and Windows it is the host's, and Docker
Desktop's virtual machine takes its allocation out of it. If available RAM is under 1024 MB or
free disk is under 5 GB, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/grist/persist ~/selfhost/grist/backups
ls -la ~/selfhost/grist
```

Assert: `ls -la` shows `persist` and `backups`, both owned by the user. Do not chown either of
them. On Linux the Grist container starts as root, chowns everything under /persist to its own
unprivileged user and then drops to it, so anything set here is replaced on the first start;
on macOS and Windows, Docker Desktop's file sharing owns that question instead. Documents land
in `persist/docs` as `.grist` SQLite files and the account table is `persist/home.sqlite3`,
both visible in Finder or Explorer.

## 4. Secrets

One secret here. Generate it, print it nowhere, and keep it out of your summary and out of any
log line.

```bash
umask 077
cat > ~/selfhost/grist/.env <<EOF
GRIST_SESSION_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/grist/.env
umask 022
ls -l ~/selfhost/grist/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same
on all three systems. Grist falls back to a session key whose value is published in its own
source when this variable is unset, which is the reason to generate one even here. The server
path for this app generates a second secret, the password on the login box in front of it;
this path has no login box, because step 6 is why it does not need one.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/grist/compose.yml <<'EOF'
# Grist · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   self-managed ....... https://support.getgrist.com/self-managed/
#   env var reference .. https://github.com/gristlabs/grist-core/blob/v1.7.17/README.md
#   upstream examples .. https://github.com/gristlabs/grist-core/tree/v1.7.17/docker-compose-examples
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/grist/, which lets one file work on macOS, Linux and Windows.
# ./persist stays a bind mount rather than a named volume, because upstream's
# own documented command mounts a home directory there and because a reader
# should be able to see their .grist files in Finder or Explorer. Nothing here
# is reachable from another device, so there is no proxy to authenticate at and
# no forward-auth header: GRIST_DEFAULT_EMAIL is the single identity Grist
# attributes edits to, which is the mode upstream documents for a machine with
# no sign-in configured. Digest read from Docker Hub on 2026-08-06; the image
# publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  grist:
    image: gristlabs/grist-oss:1.7.17@sha256:b87ec1c3b62ca99f872611a9aa71ca33ee5fef9f40e0921e0beed878e5083473
    container_name: grist
    restart: unless-stopped
    environment:
      # Read from ./.env, which is mode 600 and holds the one generated secret.
      GRIST_SESSION_SECRET: ${GRIST_SESSION_SECRET}
      # The address edits are attributed to. Upstream's own default, kept
      # because nothing off this computer can reach the port below.
      GRIST_DEFAULT_EMAIL: you@example.com
      APP_HOME_URL: http://localhost:8101
      # One team site, so no /o/<team> prefix turns up in any URL.
      GRIST_SINGLE_ORG: grist
      # Skip the first-run Quick setup gate, which would otherwise ask for a
      # boot key pasted out of the container log.
      GRIST_IN_SERVICE: "true"
    volumes:
      # The image chowns everything under /persist to its own user on start,
      # then drops out of root, so this directory is left alone after step 3.
      - ./persist:/persist
    ports:
      # Loopback only: no other device on the wifi can reach 8101.
      - "127.0.0.1:8101:8484"
EOF
cd ~/selfhost/grist && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and no sign-in screen. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.
- No login. This is the honest part, and the user should hear it in plain words: Grist has no
  password login of its own, so on a server this app has to be put behind one. Here the
  boundary is the loopback binding instead. Anyone sitting at this unlocked computer can open
  the base, exactly as they could open a spreadsheet file.

8101 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop
on the same wifi, nor anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/grist/compose.yml
```

Assert: one line, `- "127.0.0.1:8101:8484"`. If it ever reads `0.0.0.0:8101`, this install has
no boundary left at all.

## 7. Start and verify

```bash
cd ~/selfhost/grist
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' 'http://localhost:8101/status?db=1'); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS 'http://localhost:8101/status?db=1'
ls -la ~/selfhost/grist/persist
```

Assert all three, and print what you received for each: the loop ends on `200`; the status
response contains `is alive` and `db ok`; the listing shows `docs` and `home.sqlite3`, which
is Grist having written its own files into the bind mount. If any of the three misses, stop,
run `docker compose logs --tail 40 grist`, and name the likely cause. `Invalid permissions,
cannot write '/persist'` points at step 3, where the folder was created or chowned by hand. If
`port is already allocated` came back, find what holds 8101
(`lsof -nP -iTCP:8101 -sTCP:LISTEN`, `ss -ltnp | grep 8101` on Linux,
`netstat -ano | findstr :8101` on Windows) and stop until the user frees it. A running
container is not success.

STOP: tell the user to open http://localhost:8101, create one document and put a number in a
cell, and wait. Do not continue until they confirm. The first screen shows
`Create empty document`. The document has to actually open, because that is the part that uses
the WebSocket, and a home page that lists nothing proves less than one cell that saves.

## 8. First backup and restore

One archive. Stop the container first: the documents are SQLite files, and a copy taken
mid-write is not a backup.

```bash
cd ~/selfhost/grist
docker compose stop
tar -C ~/selfhost/grist -czf ~/selfhost/grist/backups/grist-$(date +%F).tar.gz persist .env compose.yml
docker compose start
ls -lh ~/selfhost/grist/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the
disk and the machine fail together. Ask the user for a destination that leaves this computer,
a folder their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`; confirm the destination exists before
copying. Assert: the user confirms the filename is listed there. If they have neither, say
plainly that this install has no backup.

To restore: `cd ~/selfhost/grist`, `docker compose down`, `rm -rf ~/selfhost/grist/persist`,
untar the archive back into ~/selfhost/grist, then `docker compose up -d` and re-run the three
asserts from step 7. Open a document and check the cell is still there. That is the whole
disaster plan, and it is worth doing once today while the only thing at risk is a test number.

## 9. Updating later

New versions are listed at https://github.com/gristlabs/grist-core/releases. Take the backup
first, then edit the image line in ~/selfhost/grist/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/grist
docker compose pull
docker compose up -d
docker compose logs --tail 30 grist
```

Grist migrates its own SQLite files on the way up, so watch that log until it settles, then
re-run step 7's asserts before calling the update done.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8101 out of habit, got a connection refused, and spent a
minute convinced the documents were gone. They were not: Docker Desktop had not started with
the session, so nothing was listening on 8101, and `restart: unless-stopped` only acts once
the Docker daemon itself is up. The `.grist` files were sitting in `persist/docs` the whole
time. Turn on Docker Desktop's start-at-login setting, and after any reboot run
`cd ~/selfhost/grist && docker compose up -d` before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8101 to 0.0.0.0 so a phone or a colleague can reach it. Grist has no password
  login of its own, so that one edit turns this into an open database on every network the
  machine joins.
- Do not configure OIDC, SAML or forward-auth headers. There is no proxy here to set a header,
  and a login system with nothing in front of it is worse than none.
- Do not set `ASSISTANT_API_KEY` or `OPENAI_API_KEY`. The formula assistant is a paid account
  somewhere else, and this install asks the user for no accounts at all.
