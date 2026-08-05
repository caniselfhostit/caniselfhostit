You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install DocuSeal 3.1.7 on this computer, reachable at http://localhost:8089, with
everything it owns under ~/selfhost/docuseal.

## 1. Preflight

Say this to the user before anything is installed, and do not soften it. Every signing
link DocuSeal generates here points at localhost, so it opens on this computer only. A
person emailed a signature request cannot open it. This install is for filling and signing
the user's own documents; if they want to send agreements to other people, stop here and
tell them the server path does that.

Detect the operating system and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size of/ {p=$8} /Pages (free|inactive)/ {f+=$NF} END {print f*p/1048576 " MB available"}' ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024)" ;;
esac
df -h ~
```

`uname -s` prints `Darwin` on macOS, `Linux` on Linux, and something starting `MINGW` or
`MSYS` in Git Bash on Windows. Every branch below keys off that answer. Each branch prints
the MB available right now, not the memory the machine shipped with.

DocuSeal renders PDFs, so it needs 2048 MB of RAM available to it and 10 GB free on the
home directory's disk. The 3.1.7 image is published for amd64 and arm64, so Intel, Apple
Silicon and x86-64 Windows are covered. Under either floor, print both numbers and stop.
Do not install and hope.

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

  Tell the user, in one sentence, that membership of the `docker` group is root-equivalent
  on this machine, and that the group change lands at their next login: log out and back
  in before continuing.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

Everything this install owns lives under one directory, and nothing is written outside it.

```bash
mkdir -p ~/selfhost/docuseal/data ~/selfhost/docuseal/backups
ls -la ~/selfhost/docuseal
```

The image creates a `docuseal` account with uid 2000 and runs as it, so on Linux the data
directory must belong to 2000 or Rails cannot create its database:

```bash
case "$(uname -s)" in
  Linux) sudo chown -R 2000:2000 ~/selfhost/docuseal/data ;;
esac
```

On macOS and Windows that branch does not run and does not apply: the container lives in
Docker Desktop's VM, whose file sharing maps ownership across the boundary itself.

Assert: `ls -la ~/selfhost/docuseal` shows `data` and `backups`, and on Linux `data` is
owned by `2000`.

## 4. Secrets

One secret is generated here: `SECRET_KEY_BASE`. Do not print it, do not repeat it in your
summary, and do not put it in any log line.

```bash
umask 077
cat > ~/selfhost/docuseal/.env <<EOF
SECRET_KEY_BASE=$(openssl rand -hex 64)
HOST=localhost:8089
EOF
chmod 600 ~/selfhost/docuseal/.env
umask 022
ls -l ~/selfhost/docuseal/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so this block is the same everywhere.

On Windows those mode bits are advisory: NTFS keeps its own permissions. The real boundary
there is the user's own Windows account, which on a single-user machine is the whole
boundary. Say that to the user; do not imply otherwise.

`HOST` carries the port because DocuSeal builds absolute links from it, and a link that
omits `:8089` arrives nowhere. The server install also sets `FORCE_SSL`; this file leaves
it out: a redirect to https on a machine with no certificate never loads.

Tell the user: `SECRET_KEY_BASE` is what the record encryption keys derive from, so
changing it later makes every stored signature unreadable. Step 8 backs it up with the
database, and those two belong together. They read it with
`grep SECRET_KEY_BASE ~/selfhost/docuseal/.env`.

## 5. compose.yml

```bash
cat > ~/selfhost/docuseal/compose.yml <<'EOF'
# DocuSeal · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image, port, /data .. https://github.com/docusealco/docuseal/blob/master/README.md
#   database selection .. https://github.com/docusealco/docuseal/blob/master/config/database.yml
#   HOST and FORCE_SSL .. https://github.com/docusealco/docuseal/blob/master/config/environments/production.rb
#
# Every host path here is relative to ~/selfhost/docuseal/, where this file
# lives, which is what lets one file work on macOS, Linux and Windows.
# One container. With DATABASE_URL unset the app uses SQLite at $WORKDIR/db.sqlite3,
# and the image already sets WORKDIR=/data/docuseal, so the single mount below
# holds the database, the uploaded documents and the signed PDFs. The image runs
# as uid 2000; on Linux that ownership is set by hand in step 3, and on macOS and
# Windows Docker Desktop's file sharing handles it. No FORCE_SSL in the .env this
# reads: there is no certificate here to redirect to. Tag and digest are the
# 3.1.7 release read from Docker Hub on 2026-08-05, for linux/amd64 and
# linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  docuseal:
    image: docuseal/docuseal:3.1.7@sha256:a8ce45fc96cb0b8670021ba781966591a1d09efb70882c920a465e87e4fea800
    container_name: docuseal
    restart: unless-stopped
    env_file: ./.env
    volumes:
      # Database, attachments and signed documents, all in one directory.
      - ./data:/data/docuseal
    ports:
      # Loopback only. Nothing outside this computer can reach 8089, not the
      # router and not the user's own phone on the same wifi. That is the point
      # of this path.
      - "127.0.0.1:8089:3000"
EOF
cd ~/selfhost/docuseal && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on 3000 inside itself; 8089 is
bound to 127.0.0.1.

## 6. Nothing is public

No reverse proxy, no certificate and no firewall rule. This block replaces all three and
keeps its number so the two paths stay in step.

Port 8089 answers this computer and nothing else, because compose binds it to 127.0.0.1.
There is no domain, and no certificate because there is nothing to certify. No other
device can reach this, including the user's own phone on the same wifi, and that is the
point of this path, not a defect in it. Browsers treat http://localhost as a secure
context, so the in-page cryptography a signing form needs still works over plain HTTP.

Acceptance criterion, checked in step 7: the published port reads
`127.0.0.1:8089->3000/tcp`, never `0.0.0.0:8089`.

## 7. Start and verify

On macOS and Windows the container gets the VM's memory, not the machine's:

```bash
docker info --format '{{.MemTotal}}'
```

Divide by 1048576. Under 2048, STOP: on macOS and Windows have the user raise Docker
Desktop's memory limit in Settings, Resources and wait for them to confirm Docker
restarted. On Linux there is no such setting: that number is the machine's own memory,
which step 1 already measured.

Rails migrates as it boots, so the first start is the slow one. Do not follow redirects
here: the redirect is the signal.

```bash
cd ~/selfhost/docuseal
docker compose pull
docker compose up -d
sleep 60
docker compose ps
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8089/up
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8089/setup
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://localhost:8089
```

Assert, all four, printing what you received for each: `docker compose ps` publishes
`127.0.0.1:8089->3000/tcp`; `/up` prints `200`; `/setup` prints `200`; the last line
prints `302` with a redirect_url ending in `/setup`. `/up` is the Rails health route and
answers only once the app has booted, and `/setup` answers `200` exactly while no user
exists.

If `docker compose up` said the port is already allocated, something else on this computer
holds 8089: find it and stop it. Do not edit the port; every other line of this prompt
names 8089. If anything else misses, wait 60 seconds, check once more, then stop and run
`docker compose logs --tail 40 docuseal`: a permission error on `/data/docuseal` is step 3
on Linux, and a container that vanished ran out of memory. A running container is not
success; four asserts passing is.

The first screen at http://localhost:8089 redirects to the setup form, which asks for a
name, an email address and a password for the first account.

STOP: tell the user to open http://localhost:8089/setup in a browser and create that first
account, and wait for them to confirm they are signed in.

Then prove the setup form closed itself:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8089/setup
```

Assert: this prints `302`, not `200`. DocuSeal redirects /setup to the sign-in page once a
user exists. A `200` means the account was never created, and the next person to sit at
this computer would own every document put here afterwards.

## 8. First backup and restore

Take the backup now, before the first real document. Stop the container first: SQLite
copied mid-write is not a backup.

```bash
cd ~/selfhost/docuseal
docker compose stop
case "$(uname -s)" in
  Linux) sudo tar -czf backups/docuseal-$(date +%F).tar.gz data .env compose.yml ;;
  *) tar -czf backups/docuseal-$(date +%F).tar.gz data .env compose.yml ;;
esac
docker compose start
case "$(uname -s)" in Linux) sudo chown "$(id -u):$(id -g)" backups/*.tar.gz ;; esac
ls -lh backups/
```

Assert: the archive exists and is non-empty. Print its size, a few hundred kilobytes on a
fresh install. On Linux the files under `data` belong to uid 2000, which is why tar runs
under sudo there and the archive is chowned back after.

`data`, `.env` and `compose.yml` travel together: the documents and the database are under
`data`, the key that decrypts the encrypted columns derives from `SECRET_KEY_BASE` in
`.env`, and `compose.yml` names the pinned image that reads both. Data without the key is
unreadable.

A backup on the same disk as the data is not a backup, and on one computer the disk and
the machine fail together.

STOP: ask the user for one destination that leaves this computer, a folder their sync
service watches or a mounted USB stick, and wait for the path. Copy the archive there with
`cp`, then list it at the destination so the copy is proved. A signed agreement is
something somebody else relies on: this archive should survive a fire.

To restore: `cd ~/selfhost/docuseal`, `docker compose down`, `rm -rf data`, `tar -xzf` the
archive from `backups/`, then `docker compose up -d`. On Linux prefix the `rm` and the
`tar` with `sudo`, so the uid 2000 ownership comes back with the files. The archive
carries `compose.yml`, so a replacement machine does not repeat steps 3 to 5. Those five
commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/docusealco/docuseal/releases. Take a backup
with the step 8 block first, then edit the image line in ~/selfhost/docuseal/compose.yml
to the new tag and its digest. Rails migrates on the next boot, so read the log until it
settles.

```bash
cd ~/selfhost/docuseal
docker compose pull
docker compose up -d
docker compose logs --tail 20 docuseal
```

## 10. What will probably go wrong

The morning after the first reboot, the bookmark fails. `restart: unless-stopped` is a
promise Docker keeps, and on macOS and Windows Docker is not running until somebody opens
Docker Desktop, so there is nothing there to keep it. I went to http://localhost:8089, got
a page saying the site could not be reached, and spent ten minutes rereading the compose
file before noticing the whale icon was gone. Run `docker info` first; if it fails, start
Docker Desktop, wait for it to say running, then
`cd ~/selfhost/docuseal && docker compose up -d`. On Linux the daemon starts with the
machine and this does not happen.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP. An invitation from here carries a link to
  http://localhost:8089, which opens nowhere else: a working relay delivers a dead link.
- Do not add PostgreSQL. SQLite is why this is one container with one directory to copy.
- Do not change `SECRET_KEY_BASE` after the first boot. Rotating it makes every stored
  signature unreadable.
