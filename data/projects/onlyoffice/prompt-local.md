You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install ONLYOFFICE Docs 9.4.0 under ~/selfhost/onlyoffice, answering at http://localhost:8157.

## 1. Preflight

Say this before step 2 runs; it decides whether they want this install at all.
ONLYOFFICE Docs is an editing engine, not a place to keep files: on its own it edits nothing,
it renders and saves documents another application hands it. On this path that application has
to be on this same computer: the editor answers at http://localhost:8157, which means "this
machine" wherever it is read, and nobody else can open a document with them.

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
distribution ID and codename print next, for step 2. Upstream asks for 4 GB of RAM and 40 GB
of free disk, on amd64 or arm64, and both are published. Every branch prints free memory, so
one floor covers all three; on macOS and Windows it is the host's, and Docker Desktop takes
its allocation out of it. If available RAM is under 4096 MB or free disk is
under 40 GB, print both numbers and stop. Do not install and hope: a machine short of memory
here fails during the first conversion, not at startup.

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
mkdir -p ~/selfhost/onlyoffice/backups
ls -la ~/selfhost/onlyoffice
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder and no
ownership fix on any of the three systems: the container chowns its state directories to its
own account at every start, so step 5 keeps them in volumes Docker manages.

## 4. Secrets

One secret: every request between this editor and the application using it is signed with it.
Generate it here, print it nowhere, and keep it out of your summary and any log line. Hex
rather than base64: the user pastes it into a web form elsewhere, and hex survives that trip
without escaping.

```bash
umask 077
cat > ~/selfhost/onlyoffice/.env <<EOF
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/onlyoffice/.env
umask 022
ls -l ~/selfhost/onlyoffice/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same
on all three. Upstream turns token validation on by default and, with this variable unset,
invents a fresh random secret at every start, so every integration breaks quietly after a
restart. The user reads it with `grep JWT_SECRET ~/selfhost/onlyoffice/.env`; step 7 needs it.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/onlyoffice/compose.yml <<'EOF'
# ONLYOFFICE Docs · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://helpcenter.onlyoffice.com/docs/installation/docs-community-install-docker.aspx
#   image reference .... https://github.com/ONLYOFFICE/Docker-DocumentServer/blob/master/README.md
#   entrypoint ......... https://github.com/ONLYOFFICE/Docker-DocumentServer/blob/master/run-document-server.sh
#
# One service, same tag, digest and port as the server file, and no database
# service: the 9.4.0 change log records the database and RabbitMQ dependencies
# removed after the back-end was consolidated into a single process.
#
# The three state directories are named volumes, not relative bind mounts,
# the one difference from the server file: the entrypoint chowns all three to
# the ds user it runs its services as, and Docker Desktop cannot grant that
# chown on a home-directory bind mount on Windows. Nothing you would open in
# Finder is in them, only runtime config, logs, and a cache of open documents.
#
# Digest read on 2026-08-07; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  documentserver:
    image: onlyoffice/documentserver:9.4.0@sha256:e3da62a847b9a5d51a11f73cfea1d9c13c3be3809614490d4edddcf01dcf919b
    container_name: onlyoffice-documentserver
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Token validation is on by default, and with no secret set the
      # entrypoint invents a random one at every start, which silently breaks
      # every integration on restart. The secret arrives from .env instead.
      JWT_ENABLED: "true"
    volumes:
      - onlyoffice-data:/var/www/onlyoffice/Data
      - onlyoffice-lib:/var/lib/onlyoffice
      - onlyoffice-logs:/var/log/onlyoffice
    ports:
      # Loopback only: no other device on the wifi can reach 8157.
      - "127.0.0.1:8157:80"
    healthcheck:
      # /healthcheck answers 200 with the body `false` when something is
      # down, so the status code alone is not a test.
      test: ["CMD-SHELL", "curl -fsS http://localhost/healthcheck | grep -q true"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s
    # SIGTERM runs the shutdown script, which needs time to finish anything
    # mid-conversion. Upstream's compose allows the same 60 seconds.
    stop_grace_period: 60s

volumes:
  onlyoffice-data:
  onlyoffice-lib:
  onlyoffice-logs:
EOF
cd ~/selfhost/onlyoffice && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`: one service, one published port, three named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8157 is bound to 127.0.0.1: this computer, not the user's phone, not a laptop on the same
wifi. That is the point of this path, not a defect. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/onlyoffice/compose.yml
```

Assert: that prints `1`, the published-port line. Nothing else is published.

## 7. Start and verify

The image is over a gigabyte compressed, so the pull takes minutes, and the first start
regenerates the font list before the editors answer.

```bash
cd ~/selfhost/onlyoffice
docker compose pull
docker compose up -d
for i in $(seq 1 40); do body=$(curl -sS http://localhost:8157/healthcheck || true); echo "$i $body"; [ "$body" = "true" ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8157/welcome/
curl -sS http://localhost:8157/welcome/ | grep -c 'ONLYOFFICE Docs Community Edition installed'
curl -sS -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{"async":false,"filetype":"docx","key":"selfhostcheck","outputtype":"pdf","url":"https://example.com/none.docx"}' http://localhost:8157/converter
```

Assert all four, and print what you received for each: the loop ends on `true`, upstream's
answer for editors that are ready; the welcome page returns `200`; the grep prints at least
`1`; the unsigned conversion request prints `{"error":-8}`, upstream's documented code for an
invalid token, and that is the security assert here: it proves the editor refuses work not
signed with the secret from step 4. If any of the four misses, stop, run
`docker compose logs --tail 40 documentserver`, and name the likely cause: an empty reply in
the first minutes is a container still starting; anything other than `-8` means step 4 or step
5 did not deliver the secret. If `port is already allocated` came back, find what holds 8157
(`lsof -nP -iTCP:8157 -sTCP:LISTEN`, or `netstat -ano | findstr :8157` on Windows) and stop
until the user frees it. A running container is not success.

The first screen is http://localhost:8157/welcome/, whose heading reads
`ONLYOFFICE Docs Community Edition installed`. http://localhost:8157/ redirects there.

STOP: tell the user nothing is editing a document yet, hand them these steps, and wait. In
their Nextcloud: install the app named `ONLYOFFICE` from Apps, open
`/settings/admin/onlyoffice`, put `http://localhost:8157/` in the Document Editing Service
address field, then read the secret with `grep JWT_SECRET ~/selfhost/onlyoffice/.env` and paste
it into the Secret key field there. Step 10 is about how that address goes wrong; read it
to them first. Do not continue until they confirm, or say they will connect it later.

## 8. First backup and restore

One archive of two files, because the documents are somewhere else and those two rebuild the
service completely: the volumes hold cache and logs, and are meant to be thrown away. The
irreplaceable part is the secret. Change it and every application pointed at this editor stops
opening documents until the new value is pasted into its settings.

```bash
cd ~/selfhost/onlyoffice
tar -czf backups/onlyoffice-config-$(date +%F).tar.gz compose.yml .env
ls -lh backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped.

That archive sits on the same disk as everything else, which is not a backup: on a laptop disk
and machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy it there with `cp`. In
Git Bash a Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms
the filename is listed there; if they have neither, say plainly that this install has no
backup.

Prove the restore now, while nothing is at stake:

```bash
cd ~/selfhost/onlyoffice
docker compose down -v
tar -xzf backups/onlyoffice-config-$(date +%F).tar.gz
docker compose up -d
```

Then re-run step 7's health-check loop. Assert: it ends on `true` again. `-v` belongs here on
purpose: dropping the three volumes is the point. Tell the user that is the whole disaster
plan, and that anything open in an editor at that moment is lost, though the document itself is
not.

## 9. Updating later

New versions are listed at https://github.com/ONLYOFFICE/DocumentServer/releases. Back up
first, then edit the image line in ~/selfhost/onlyoffice/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/onlyoffice
docker compose pull
docker compose up -d
docker compose logs --tail 30 documentserver
```

Watch that log until it settles, then re-run step 7's four asserts before calling it done.

## 10. What will probably go wrong

The address will work in the browser and fail in the application anyway. I put
http://localhost:8157/ into Nextcloud's ONLYOFFICE settings, watched the editor load in my own
browser, and got an error from Nextcloud saying the document service was unreachable. Both were
true: my browser was on this machine, so localhost was this machine, but Nextcloud's server
fetches from that address too, and if Nextcloud is in a container then localhost is that
container, where nothing listens. The fix is to run that application outside a container, or
put both on one Docker network and use the service name.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not set `ALLOW_PRIVATE_IP_ADDRESS` or `USE_UNAUTHORIZED_STORAGE`. They let this editor
  fetch from private addresses and hosts with bad certificates: a tempting fix for step 10, and
  a tool for reaching things it should not reach.
- Do not enable the bundled example application with `EXAMPLE_ENABLED`. It is an
  unauthenticated file upload page, disabled by default for that reason.
- Do not install Nextcloud here. This prompt installs the editor.
