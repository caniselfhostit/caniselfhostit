You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Excalidraw, pinned to the image digest in step 5, reachable at
http://localhost:8083, with everything it needs under ~/selfhost/excalidraw.

## 1. Preflight

Say this to the user before anything is installed, because it is what they are getting:
every drawing is saved in the browser on this computer and nowhere else, so nothing syncs
to their phone and nobody else can join a board with them. That is not the price of running
it here. The image upstream publishes is the Excalidraw frontend on its own, an nginx
serving compiled JavaScript with no database, no accounts and no document store, on a
rented server either. Drawing for yourself works. Sharing a live board does not, on any
host.

Find out which OS this is, then measure memory and disk:

```bash
uname -s
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize | awk '{printf "%d MB installed\n", $1/1048576}' ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`uname -s` prints `Darwin` on macOS, `Linux` on Linux, and a string starting `MINGW` or
`MSYS` in Git Bash on Windows. Every branch in step 2 keys off that answer.

Excalidraw needs 256 MB of RAM available and 2 GB free on the disk holding the home
directory. It runs on amd64 and on arm64, so Apple Silicon is covered.

Print both measured numbers. That RAM figure is installed RAM on macOS and Windows and
available RAM on Linux; if it is under 256 MB, or free disk is under 2 GB, say both numbers
and stop. Do not install and hope. The Windows branch prints bytes rather than megabytes,
so divide by 1048576 before comparing it to the floor.

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
  commands are below this list.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Debian or Ubuntu, in full:

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

On Debian or Ubuntu, tell the user in one sentence that membership of the docker group is
root-equivalent on this machine. The group change lands at their next login, so
`docker info` still fails in this shell. STOP: tell the user to log out and back in, then
run this prompt again. It resumes at this step, and the check at the top of it passes.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/excalidraw/data ~/selfhost/excalidraw/backups
chmod 700 ~/selfhost/excalidraw
ls -la ~/selfhost/excalidraw
```

Assert: `ls -la` lists `data` and `backups`, both owned by the user running the command.
Everything for this install lives under ~/selfhost/excalidraw and nothing is written
outside it.

`data` is not mounted into the container. The container has nowhere to put a document, so
there is nothing for it to write; `data` is where the user's exported drawings go in step 8
and it is what the backup archives. No ownership fix is needed on any OS: no bind mount
exists, so the uid the image runs as never touches this disk. On Linux a bind mount would
otherwise need a `chown` to that uid, and on macOS and Windows Docker Desktop's file
sharing owns that problem.

On Windows, `chmod 700` is advisory. NTFS ignores the mode bits Git Bash writes, and the
real boundary on a single-user machine is the user's own Windows account.

## 4. Secrets

There are none. Excalidraw has no accounts, no admin page and no database, so this install
generates no secret and writes no `.env`. Do not invent a token to make the install feel
more finished.

## 5. compose.yml

Write this file exactly as it appears. The pin is a digest because upstream publishes only
a rolling tag for this image, so the digest is the version here.

```bash
cat > ~/selfhost/excalidraw/compose.yml <<'EOF'
# Excalidraw · the deterministic fallback for the local path.
#
# Authored by caniselfhostit from the upstream documentation, not copied from a
# repository:
#   image and port ..... https://hub.docker.com/r/excalidraw/excalidraw
#   docker notes ....... https://docs.excalidraw.com/docs/introduction/development
#   collab server ...... https://github.com/excalidraw/excalidraw-room
#
# This file lives at ~/selfhost/excalidraw/compose.yml on the user's own
# computer. One container, and it is an nginx serving the compiled Excalidraw
# frontend. There is no database, no account system and no server side document
# store, so there is no volume to bind and no .env to read: every drawing lives
# in the browser that drew it. ~/selfhost/excalidraw/data holds the scenes the
# user exports by hand.
#
# Upstream publishes no versioned tag for this image, only a rolling one, so the
# pin is the multi-arch manifest digest read from Docker Hub on 2026-08-05, which
# covers linux/amd64 and linux/arm64. It is the same digest the VPS compose.yml
# carries, and the two files move together or not at all.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  excalidraw:
    image: excalidraw/excalidraw@sha256:f7ee194addd607bf831d2af0f0a34463dd4225e426cf35199ef0b12a803398e9
    container_name: excalidraw
    restart: unless-stopped
    ports:
      # Loopback only. 8083 answers programs on this computer and nothing else,
      # so no other device on the network can reach it, including the user's
      # own phone. That is the posture of this path, not a gap in it.
      - "127.0.0.1:8083:80"
EOF
cd ~/selfhost/excalidraw && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

There is no base URL to configure. The frontend serves relative paths and writes no
absolute links, and the one environment variable that would take a URL points at the
collaboration server this install does not run, so http://localhost:8083 works with the
file as written.

## 6. Nothing is public

There is no Caddy here, no certificate and no firewall rule, and none of that is missing.
Compose publishes `127.0.0.1:8083`, the loopback address, so the port answers programs on
this computer and refuses every packet arriving from the network. There is no domain and
nothing to certify: a name that resolves only here has no public identity a certificate
authority could attest to.

Other devices cannot reach this: not the user's phone on the same wifi, not a laptop in the
next room. On this path that is the design.

Browsers treat http://localhost as a secure context, so page features that need
cryptography still work without TLS. Excalidraw stores drawings that way, which is why this
install works at all without a certificate.

The binding is checkable, not a promise: step 7 runs `docker compose ps` and the ports
column must read `127.0.0.1:8083->80/tcp`. If it reads `0.0.0.0:8083`, the compose
file lost its `127.0.0.1:` prefix and the whiteboard is answering the whole local network.

## 7. Start and verify

```bash
cd ~/selfhost/excalidraw
docker compose pull
docker compose up -d
sleep 10
docker compose ps --format 'table {{.Service}}\t{{.Ports}}'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8083/
curl -sS http://localhost:8083/ | grep -c 'Excalidraw'
```

Assert three things and print what you received for each: the ports column reads
`127.0.0.1:8083->80/tcp`, the first curl prints `200`, and the second prints a number
greater than `0`, because `Excalidraw` appears in the title of the document nginx served.

If any of the three misses, stop, run `docker compose logs --tail 30 excalidraw`, and say
which earlier step is the likely cause. `curl: (7) Failed to connect` with no container
listed means Docker Desktop is not running, which is step 2. A container that exits at
once with `bind: address already in use` means something else on this machine holds 8083.
Find it with `lsof -nP -iTCP:8083 -sTCP:LISTEN` on macOS or Linux, or with
`netstat -ano | findstr :8083` in Git Bash on Windows, and report what holds the port
rather than changing it.

A running container is not success. Three passing asserts are success.

The first screen at http://localhost:8083 is a blank white canvas with the drawing toolbar
across the top. There is no login form and no sign-up link, because there are no accounts.

## 8. First backup and restore

The drawing is not on this disk yet. Print the folder it goes into:

```bash
cd ~/selfhost/excalidraw/data && pwd
```

Read that path out to the user; a save dialog does not understand `~`. In Git Bash run
`pwd -W` too, for the `C:\...` form the dialog wants.

STOP: tell the user to open http://localhost:8083, draw one line, then use the app's own
export to save the scene into that exact folder, and wait. Do not continue until they
confirm the file is there.

That file is the drawing. No command in this prompt can reach browser storage, so an
exported file is the only copy outside one browser profile on one machine.

```bash
cd ~/selfhost/excalidraw
ls -la data
tar -czf ~/selfhost/excalidraw/backups/excalidraw-$(date +%F).tar.gz compose.yml data
ls -lh ~/selfhost/excalidraw/backups/
```

Assert: `data` holds the exported scene, the archive exists, and it is non-empty. Print its
size. Nothing is stopped and nothing goes offline: there is no database to catch mid-write.

A backup on the same disk as the thing it backs up is not a backup, and on one computer the
disk and the machine fail together. STOP: ask the user for a destination that leaves this
computer, a folder a sync service watches or a USB stick they have mounted, and wait for
their answer. No default here leaves the machine, so do not run this block until they have
given you a path for its first line:

```bash
DEST=
mkdir -p "$DEST"
cp ~/selfhost/excalidraw/backups/*.tar.gz "$DEST"/
ls -lh "$DEST"/
```

Assert: the archive is listed at the new path at the same size.

To restore, use the copy that left this machine; the one under `backups/` went with the
disk. Put its path on the first line:

```bash
ARCHIVE=
mkdir -p ~/selfhost/excalidraw
tar -xzf "$ARCHIVE" -C ~/selfhost/excalidraw
cd ~/selfhost/excalidraw && docker compose up -d
```

Then use the app's import to load the scene back out of `data`. Tell the user that is two
restores, the second one holds their work, and exporting is a habit rather than a one-time
step.

## 9. Updating later

There is no release page for this image and no changelog tied to the tag, which is a real
cost of pinning it. Take a backup first, then read the digest upstream publishes today:

```bash
docker pull excalidraw/excalidraw
docker image inspect --format '{{index .RepoDigests 0}}' excalidraw/excalidraw
```

That prints one line ending in `@sha256:` and 64 hex characters. Put that digest into the
`image:` line of ~/selfhost/excalidraw/compose.yml, then:

```bash
cd ~/selfhost/excalidraw
docker compose pull
docker compose up -d
docker compose logs --tail 20 excalidraw
```

Write the digest that was replaced into a note beside the compose file; there is no tag
history to look it up from later. Nothing here holds a drawing, so going back costs a page
load rather than the user's work.

## 10. What will probably go wrong

Docker Desktop, after a reboot. I restarted the Mac I installed this on, opened the
bookmark out of habit, and got a connection-refused page with nothing behind it. A
container cannot start while the Docker VM is still stopped, and Docker Desktop does not
launch at login unless told to, so `restart: unless-stopped` bought me nothing. What made
it worse than a dull wait is where the drawings live. Browser storage is keyed to the
origin http://localhost:8083, so with nothing answering on that port I was looking at an
error page and assuming a week of diagrams had gone with it. They had not. Starting Docker
Desktop, waiting for the whale icon and reloading brought the canvas back. Tell the user to
turn on Docker Desktop's start-at-login setting now, while they are thinking about it.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not install excalidraw-room or wire up live collaboration. That is a second service
  with its own socket transport, and this prompt installs one container.
- Do not add an S3 bucket, a database, or any storage backend. This image has no server
  side storage to point at one, so it would sit empty.
- Do not set analytics or telemetry environment variables. The published image ships
  without them, which is one of the reasons to run it.
