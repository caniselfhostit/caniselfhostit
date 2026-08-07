You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install code-server 4.131.0 under ~/selfhost/code-server, answering at http://localhost:8137.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. code-server answers on this computer and nowhere else, so the tablet or borrowed laptop they
might have opened this editor on cannot reach it. What they get is a pinned Linux toolchain in a
container beside their own files rather than on top of them.

Detect the OS and measure the machine:

```bash
uname -s
id -u
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. code-server needs 1024 MB of RAM available
and 10 GB free on the home disk; upstream's floor is 1 GB of RAM and 2 CPU cores, and the 10 GB
is the image, the extensions and whatever gets built. On macOS and Windows that memory figure is
the host's, and Docker Desktop takes its share of it. If either is under its floor, print both
numbers and stop.

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

Four directories and one configuration file. The container runs as uid 1000, which is why the
Linux branch hands three of them to that uid.

```bash
cd ~ && mkdir -p selfhost/code-server/config/code-server selfhost/code-server/local selfhost/code-server/project selfhost/code-server/backups
cat > ~/selfhost/code-server/config/code-server/config.yaml <<'EOF'
auth: password
disable-telemetry: true
disable-update-check: true
EOF
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 1000:1000 ~/selfhost/code-server/config ~/selfhost/code-server/local ~/selfhost/code-server/project
fi
ls -la ~/selfhost/code-server
```

Assert: `ls -la` shows `config`, `local`, `project` and `backups`. On macOS and Windows nothing
was chowned: Docker Desktop maps ownership. On Linux those three now belong to uid 1000, and if
step 1 printed anything other than `1000` for `id -u`, say so: those files are edited through
the editor, not the file manager.

Upstream would otherwise write that file itself on first start, with a random password in it.
Writing it first keeps that credential-shaped string off the disk and turns telemetry off before
a request leaves this machine. There is no `password` line: step 4 supplies it.

## 4. Secrets

One secret: the password on the editor. Generate it here. Do not print it, do not put it in your
summary, and keep it out of every log line.

```bash
umask 077
cat > ~/selfhost/code-server/.env <<EOF
PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/code-server/.env
umask 022
ls -l ~/selfhost/code-server/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same on
all three systems. Hex rather than base64, because Docker Compose reads this file for
interpolation and a `$` in the value would be expanded. On Windows those mode bits are advisory:
NTFS does not enforce them, and the real boundary is the user's account.

Tell them `grep PASSWORD ~/selfhost/code-server/.env` reads the value and that it belongs in
their password manager now. code-server deletes the variable from its own environment before
starting anything, so the terminal does not inherit it.

## 5. compose.yml

```bash
cat > ~/selfhost/code-server/compose.yml <<'EOF'
# code-server · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://coder.com/docs/code-server/install
#   faq and config ..... https://coder.com/docs/code-server/FAQ
#   requirements ....... https://coder.com/docs/code-server/requirements
#   release image ...... https://github.com/coder/code-server/blob/v4.131.0/ci/release-image/Dockerfile
#
# One service, and it is a development machine: the editor, the terminal it
# opens, and whatever gets installed from inside it. Paths are relative to
# ~/selfhost/code-server/, so one file works on macOS, Linux and Windows.
#
# The image runs as uid 1000, the `coder` user baked into it, and binds
# code-server to 0.0.0.0:8080. On Linux the three directories below are chowned
# to 1000 during the install; on macOS and Windows Docker Desktop handles that.
# No `user:` line: the entrypoint runs fixuid first. PASSWORD arrives from
# ./.env, mode 600, and code-server deletes it from its own environment before
# starting anything. Telemetry and the update check are off in the config file.
# No Docker socket is mounted.
#
# Tag and digest read from Docker Hub on 2026-08-06; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  code-server:
    image: codercom/code-server:4.131.0@sha256:3623e6362abdec6258472882b06fdeec9d6ce2ad3fda316b3c5d7ed092b89add
    container_name: code-server
    restart: unless-stopped
    # PASSWORD, and nothing else, generated on this computer.
    env_file: ./.env
    volumes:
      # config.yaml lives at config/code-server/config.yaml on this computer.
      - ./config:/home/coder/.config
      # Extensions, editor settings and the machine id.
      - ./local:/home/coder/.local
      # The working tree. Empty until you put code in it.
      - ./project:/home/coder/project
    ports:
      # Loopback only: no other device on the wifi can reach 8137.
      - "127.0.0.1:8137:8080"
    healthcheck:
      # /healthz needs no authentication and never triggers a heartbeat.
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd ~/selfhost/code-server && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, three binds.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the editor's crypto still works.
- No firewall rule. Nothing is published beyond loopback.

8137 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone on the
internet. For something carrying a terminal, that is the whole model. Confirm it:

```bash
grep -n '"127.0.0.1:' ~/selfhost/code-server/compose.yml
```

Assert: one line, `- "127.0.0.1:8137:8080"`.

## 7. Start and verify

```bash
cd ~/selfhost/code-server
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8137/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8137/healthz; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8137/
curl -sS http://localhost:8137/login | grep -o -E '<title>[^<]*</title>|Welcome to code-server|Password was set from .PASSWORD'
```

Assert all four, and print what you received for each. The loop ends printing `200`. The health
response is a small JSON object containing `"lastHeartbeat"`; its `status` reads `expired` on a
fresh instance, which is correct: the heartbeat starts only once a browser holds the editor open.
The bare URL prints `302`, an unauthenticated request sent to the login page, and that is the
security assert. The last prints `<title>code-server login</title>`, `Welcome to code-server` and
`Password was set from $PASSWORD`, the third proving step 4's value reached the container.

If the bare URL prints `200` rather than `302`, stop and do not report success: authentication is
off. If the loop never reaches 200, stop, run `docker compose logs --tail 40 code-server` and
name the likely cause: a container that exits at once is usually step 3 leaving a directory it
cannot write. If `port is already allocated` came back, find what holds 8137 with
`lsof -nP -iTCP:8137 -sTCP:LISTEN` (`netstat -ano | findstr :8137` on Windows) and stop.

STOP: tell the user to read their password with `grep PASSWORD ~/selfhost/code-server/.env`, put
it in their password manager, open http://localhost:8137, sign in, and wait. Do not continue
until they confirm they see the editor. The first screen is one card reading
`Welcome to code-server` above `Please log in below.`, with one `PASSWORD` box, a `SUBMIT` button,
no username.

Once they confirm:

```bash
curl -sS http://localhost:8137/healthz; echo
```

Assert: `status` now reads `alive`. It falls back to `expired` a minute after the last request,
so `alive` means a browser is holding the editor open; if it reads `expired`, have the user
reload the page. Then tell them the folder on the left is `/home/coder/project`, empty until a
`git clone` in the editor's terminal fills it.

## 8. First backup and restore

One archive: the config, extensions and settings, the working tree, compose.yml and .env.

```bash
cd ~/selfhost/code-server
docker compose stop
tar -C ~/selfhost/code-server -czf ~/selfhost/code-server/backups/code-server-$(date +%F).tar.gz config local project compose.yml .env
docker compose start
ls -lh ~/selfhost/code-server/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds; the
container stops because a file caught mid-write is not a backup.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`. Assert: the user confirms the filename is there. If they have
nowhere, say plainly this install has no backup yet.

To restore: `docker compose down`, remove `config`, `local` and `project` under
~/selfhost/code-server, recreate them as in step 3, untar the archive back in, then
`docker compose up -d`. Only those three folders are in it, so a toolchain installed inside the
container is not.

## 9. Updating later

New versions are listed at https://github.com/coder/code-server/releases. The Docker Hub tag
drops the leading `v`, so `v4.132.0` is tag `4.132.0`. Back up first, then edit the image line in
compose.yml to the new tag and digest:

```bash
cd ~/selfhost/code-server
docker compose pull
docker compose up -d
docker compose logs --tail 30 code-server
```

Extensions and settings survive because they live in `local`, not the image. Re-run step 7's
`/healthz` and `302` checks, then reload the browser tab.

## 10. What will probably go wrong

I started a long build in the editor's terminal, closed the lid, and came back to a page saying
the connection was lost and a build stopped partway. Nothing was corrupt. This container is not
on a server: it sleeps when this computer sleeps, and a terminal session inside it survives that
no better than one in a local shell. Reload the tab, and if the editor does not come back run
`cd ~/selfhost/code-server && docker compose up -d`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8137 to 0.0.0.0 so a tablet on the wifi can reach it. That puts a terminal on
  this machine on every network the user joins, behind one password and no TLS.
- Do not mount the Docker socket into this container. That turns the editor's terminal into root
  on this computer, a threat model this prompt does not cover.
- Do not repoint the extension gallery at Microsoft's Visual Studio Marketplace. Their terms
  restrict it to Visual Studio products; this build uses Open VSX.
