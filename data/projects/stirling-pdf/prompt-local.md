You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Stirling-PDF 2.14.2 on this computer, reachable at http://localhost:8087, with
everything it owns under ~/selfhost/stirling-pdf.

## 1. Preflight

This is the heaviest install in the catalogue: the image carries a JVM, LibreOffice,
Calibre and Tesseract. It needs 2048 MB of RAM available to it and 10 GB free on the disk
the home directory sits on. The 2.14.2 image is published for amd64 and arm64, so both
Apple Silicon and Intel are covered.

Detect the operating system and measure both numbers:

```bash
uname -s
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`uname -s` prints `Darwin` on macOS, `Linux` on Linux, and something starting `MINGW` or
`MSYS` in Git Bash on Windows. Darwin and Windows print total bytes, so divide by 1048576
to get MB; Linux prints available MB directly.

If the machine has under 2048 MB to give this container, or under 10 GB free on the home
directory's disk, print both numbers and stop. Do not install and hope: the image is
several GB before a document is opened, and a JVM out of heap during an OCR pass fails in
ways that look random.

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
  repository, with its signing key saved to a file first, never piped into a shell:

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

  Tell the user in one sentence that membership of the `docker` group is root-equivalent
  on this machine. Then STOP: tell the user to log out and log back in, then run this
  prompt again from step 2. The group does not exist in this shell until they do, so the
  assert below cannot pass here. Do not continue until they confirm.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

Everything this install owns lives under one directory, and nothing is written outside it.

```bash
mkdir -p ~/selfhost/stirling-pdf/data ~/selfhost/stirling-pdf/backups
ls -la ~/selfhost/stirling-pdf
```

The image starts as root and drops parts of its work to uid 1000, the default PUID and
PGID, so on Linux the data directory belongs to 1000 before the container starts:

```bash
case "$(uname -s)" in
  Linux) sudo chown -R 1000:1000 ~/selfhost/stirling-pdf/data ;;
esac
```

On macOS and Windows that branch does not run: Docker Desktop's file sharing maps
ownership across the VM boundary itself. On Linux there is no VM in between, so 1000 is a
real uid and may not be the user's own. The drop is not total: the H2 database file
arrives owned by root, which is why step 8 uses `sudo` on Linux.

Assert: `ls -la ~/selfhost/stirling-pdf` shows `data` and `backups`.

## 4. Secrets

One secret: the first-login credential for the `admin` account, generated on this machine.
Do not print it, do not repeat it in your summary, and do not put it in any log line.

Login is on here. Loopback keeps other machines out, not other accounts on this one:
anyone else signed into this computer can open http://localhost:8087. With login on the
image ships a default account, so the value generated below replaces it before the
container starts.

```bash
umask 077
cat > ~/selfhost/stirling-pdf/.env <<EOF
DISABLE_ADDITIONAL_FEATURES=false
SECURITY_ENABLELOGIN=true
SECURITY_INITIALLOGIN_USERNAME=admin
SECURITY_INITIALLOGIN_PASSWORD=$(openssl rand -base64 24)
SYSTEM_DEFAULTLOCALE=en-GB
SYSTEM_MAXFILESIZE=100
SYSTEM_GOOGLEVISIBILITY=false
METRICS_ENABLED=false
EOF
chmod 600 ~/selfhost/stirling-pdf/.env
umask 022
ls -l ~/selfhost/stirling-pdf/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user their username is `admin`,
that they read the generated value once with
`grep SECURITY_INITIALLOGIN_PASSWORD ~/selfhost/stirling-pdf/.env`, and that Stirling-PDF
makes them choose a new one at the first sign-in.

On Windows those mode bits are advisory: NTFS keeps its own permissions, and the user's
own Windows account is the real boundary. Say that rather than implying a lock that is not
there.

## 5. compose.yml

```bash
cat > ~/selfhost/stirling-pdf/compose.yml <<'EOF'
# Stirling-PDF · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image and ports .... https://docs.stirlingpdf.com/Installation/Docker%20Install
#   login settings ..... https://docs.stirlingpdf.com/Configuration/System%20and%20Security/
#
# This file lives in ~/selfhost/stirling-pdf/ and every path in it is relative to
# that directory, which is what lets one file work on macOS, Linux and Windows.
# One container, no database process: the user table is an embedded H2 file under
# /configs, so ./data plus ./.env is the whole install. The image starts as root
# and drops parts of its work to uid 1000; on Linux step 3 gives ./data to 1000,
# and on macOS and Windows Docker Desktop's file sharing handles it. Tag and
# digest are the 2.14.2 release read from Docker Hub on 2026-08-05, for
# linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  stirling-pdf:
    image: stirlingtools/stirling-pdf:2.14.2@sha256:7ed4d9681d18e4fbc3aa6a63647c4b5c2bcc4b75841df7c05d7e3d2320f5c9a1
    container_name: stirling-pdf
    restart: unless-stopped
    env_file: ./.env
    volumes:
      # The H2 user database and the generated server certificate live here.
      # One mount, so one directory to copy. OCR language packs beyond the
      # bundled English set would need a second mount at /usr/share/tessdata.
      - ./data:/configs
    ports:
      # Loopback only. Nothing outside this computer can reach 8087, and no
      # other device on the network can either. That is the point of this path.
      - "127.0.0.1:8087:8080"
EOF
cd ~/selfhost/stirling-pdf && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on 8080 inside itself, and 8087 is
bound to 127.0.0.1 here. `restart: unless-stopped` means Docker starts it again whenever
Docker itself starts, which on a laptop is every time Docker Desktop opens.

## 6. Nothing is public

No reverse proxy, no certificate and no firewall rule. This block replaces all three and
keeps its number.

Port 8087 answers this computer and nothing else, because compose binds it to 127.0.0.1.
There is no domain, and there is no certificate because there is nothing to certify. No
other device can reach this, including the user's own phone on the same wifi, and that is
the point of this path, not a defect in it. Browsers treat http://localhost as a secure
context, so anything in the page that needs crypto still works over plain HTTP, and
Stirling-PDF emits relative links, so nothing needs a base URL set.

## 7. Start and verify

Check what Docker will actually hand the container first. On macOS and Windows that is the
VM's memory, not the machine's:

```bash
docker info --format '{{.MemTotal}}'
```

Divide by 1048576. If that is under 2048 and step 1 printed `Darwin`, `MINGW` or `MSYS`,
STOP: tell the user to raise the memory limit in Docker Desktop, Settings, Resources, and
wait for them to confirm Docker has restarted. On Linux it is the host's own RAM, already
gated in step 1.

The first boot is slow. The image's own health check calls /api/v1/info/status and allows
two minutes before it counts a failure, so wait for that check rather than guessing:

```bash
cd ~/selfhost/stirling-pdf
docker compose pull
docker compose up -d
sleep 90
docker compose ps
docker inspect --format '{{.State.Health.Status}}' stirling-pdf
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8087/login
curl -sS http://localhost:8087/login | grep -ci 'stirling'
grep -ci 'stirling$' ~/selfhost/stirling-pdf/.env
```

Assert, all five: `docker compose ps` publishes `127.0.0.1:8087->8080/tcp`;
`docker inspect` prints `healthy`; the first curl prints `200` for /login; the second
prints a number greater than `0`, because the sign-in page is titled `Stirling PDF`; and
the last prints `0`, proving the credential the image ships with is not in this install.
Print what you received for each.

If health is still `starting`, wait 60 seconds and check again before treating it as a
failure. If `docker compose up` reported the port already allocated, something else on
this computer holds 8087: find it and stop it, and do not edit the port, which every other
line of this prompt names. If anything else misses, stop, run
`docker compose logs --tail 40 stirling-pdf`, and name the earlier step that is the likely
cause. A running container is not success; five asserts passing is.

A browser at http://localhost:8087 lands on the sign-in form at /login, a page titled
`Stirling PDF` asking for a username and a password.

STOP: tell the user to open http://localhost:8087, sign in as `admin` with the value from
step 4, set the new password Stirling-PDF demands, and save it. Wait for their
confirmation.

## 8. First backup and restore

Take the backup now, before the user relies on the account. Stop the container first: the
H2 user database copied mid-write is not a backup.

```bash
cd ~/selfhost/stirling-pdf
docker compose stop
case "$(uname -s)" in Linux) SUDO=sudo ;; *) SUDO= ;; esac
$SUDO tar -C ~/selfhost/stirling-pdf -czf ~/selfhost/stirling-pdf/backups/stirling-pdf-$(date +%F).tar.gz data .env
docker compose start
ls -lh ~/selfhost/stirling-pdf/backups/
```

Assert: the archive exists and is non-empty. Print its size, tens of kilobytes on a fresh
install. Downtime is a few seconds, and `data` plus `.env` is the whole install: every
document is handed back and its working copy discarded, so nothing else needs saving. The
Linux branch reads with `sudo` because some files under `data/` are written by root inside
the container, not by uid 1000.

A backup on the same disk as the data is not a backup, and on one computer the disk and
the machine fail together. Ask the user for one destination that leaves this machine, a
folder their sync service watches or a mounted USB stick, copy the archive there with
`cp`, and then list it at the destination so the copy is proved rather than assumed.

To restore: `docker compose down`; delete `~/selfhost/stirling-pdf/data`, with `sudo` on
Linux; `tar -C ~/selfhost/stirling-pdf -xzf` the archive; then on Linux only re-run step
3's `sudo chown -R 1000:1000 ~/selfhost/stirling-pdf/data`, because a non-root `tar -x`
hands every restored file to whoever ran it and uid 1000 has to own `data/` before the
container starts; then `docker compose up -d` and wait for `healthy`. The account lives in
that H2 file. Tell the user that is the whole disaster plan: four commands, five on Linux.

## 9. Updating later

New versions are listed at https://github.com/Stirling-Tools/Stirling-PDF/releases. Take a
step 8 backup first, then edit the image line in ~/selfhost/stirling-pdf/compose.yml to
the new tag and its digest. Stirling-PDF migrates the H2 file on the first boot after an
upgrade, so wait for the health check to go green before calling the update done.

```bash
cd ~/selfhost/stirling-pdf
docker compose pull
docker compose up -d
docker compose logs --tail 20 stirling-pdf
```

## 10. What will probably go wrong

Memory, and not the memory step 1 measured. On macOS and Windows the container sees what
Docker Desktop's VM was given, not this machine's RAM, and that default is often under the
2048 MB this image wants. I watched a 16 GB laptop restart this container twice while the
JVM was still unpacking LibreOffice, and nothing in the log said "out of memory", because
the process was killed inside the VM before it could say anything. If
step 7 never reaches `healthy`, read `docker info --format '{{.MemTotal}}'` again before
touching anything else: that number, not step 1's, is the one that decides this.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not set `SECURITY_ENABLELOGIN=false`. Loopback keeps other machines out, not other
  accounts on this one, and turning login off brings the shipped default account back.
- Do not configure OAuth2 or SAML sign-on. Both need an identity provider registered
  elsewhere, which is the user's decision, not this install's.
- Do not add a /usr/share/tessdata mount for extra OCR languages. English is bundled.
