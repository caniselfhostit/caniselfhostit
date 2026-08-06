You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Apache CouchDB 3.5.2.1 under ~/selfhost/obsidian-livesync, answering at
http://localhost:8120, as the sync server the Obsidian Self-hosted LiveSync plugin replicates
into.

## 1. Preflight

Say both of these to the user before step 2 runs. http://localhost:8120 means this computer and
nowhere else, so what they get is a versioned copy of every note in a database they own, not a
phone that syncs. And the server is the only half this prompt does: the plugin goes in by hand,
inside Obsidian, which is closed-source software this prompt never touches.

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
distribution ID and codename print next, for step 2. CouchDB needs 1024 MB of RAM available and
5 GB free on the home disk, and the image publishes amd64 and arm64. On macOS and Windows the
memory figure is the host's, out of which Docker Desktop's virtual machine takes its allocation.
If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/obsidian-livesync/backups
ls -la ~/selfhost/obsidian-livesync
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: step 5 keeps the
database in a volume Docker manages, so nothing needs a chown.

## 4. Secrets

Two secrets, generated here. Print neither, and keep both out of your summary and out of any log
line.

```bash
umask 077
cat > ~/selfhost/obsidian-livesync/.env <<EOF
COUCHDB_USER=livesync
COUCHDB_PASSWORD=$(openssl rand -hex 32)
COUCHDB_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/obsidian-livesync/.env
umask 022
ls -l ~/selfhost/obsidian-livesync/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three. `COUCHDB_PASSWORD` is the administrator password the user types into the
plugin; `COUCHDB_SECRET` signs session cookies, and unset CouchDB invents one at each boot inside
the container, which this install does not keep. On Windows those mode bits are advisory and the
boundary is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/obsidian-livesync/compose.yml <<'EOF'
# Obsidian LiveSync · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   couchdb setup ... https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md
#   settings ........ https://github.com/vrtmrz/obsidian-livesync/blob/main/utils/couchdb/provision.ts
#   couchdb config .. https://docs.couchdb.org/en/stable/config/http.html
#
# One service. Every path is relative to ~/selfhost/obsidian-livesync/, so one
# file works on macOS, Linux and Windows.
#
# The database is a named volume, not a bind mount: the container runs as uid
# 5984, and making a home-directory bind mount writable by that uid needs root
# on Linux and cannot be expressed at all through Docker Desktop's Windows file
# sharing. A fresh volume inherits the image's own 5984 ownership instead.
#
# The `configs` block is the set of settings upstream's provisioning tool PUTs
# into /_node/_local/_config, written as a config file so nothing needs Deno.
#
# Digest read from Docker Hub on 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  couchdb:
    image: couchdb:3.5.2.1@sha256:b80216f643e99d31df318c740dbc556ac08b56444030ed1d5e6d7b0d4e625213
    container_name: obsidian-livesync-couchdb
    restart: unless-stopped
    user: "5984:5984"
    env_file: ./.env
    configs:
      - source: livesync-ini
        target: /opt/couchdb/etc/local.d/10-livesync.ini
    volumes:
      - couchdb-data:/opt/couchdb/data
    ports:
      # Loopback only: no other device on the wifi can reach 8120.
      - "127.0.0.1:8120:5984"

configs:
  livesync-ini:
    content: |
      [couchdb]
      ; Creates _users and _replicator at startup: the single-node equivalent
      ; of the /_cluster_setup call.
      single_node = true
      ; A note and its attachments are one document, and CouchDB defaults to
      ; 8000000 bytes.
      max_document_size = 50000000

      [chttpd]
      ; Nothing anonymous reaches anything but /_up, the health endpoint.
      require_valid_user = true
      require_valid_user_except_for_up = true
      ; The CouchDB default, restated: the limit above is reachable only
      ; while this one stays above it.
      max_http_request_size = 4294967296
      enable_cors = true

      [cors]
      credentials = true
      ; Obsidian desktop, then mobile under Capacitor. CouchDB rejects a
      ; wildcard origin while credentials are on.
      origins = app://obsidian.md,capacitor://localhost,http://localhost

volumes:
  couchdb-data:
EOF
cd ~/selfhost/obsidian-livesync && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. An error naming `content` means the compose plugin predates
v2.23.1; update Docker Desktop and run this step again.

## 6. Nothing is public

No reverse proxy and no certificate: there is no public name to certify, browsers treat
http://localhost as a secure context anyway, and upstream states plain HTTP suits a trusted local
connection from a desktop device. No firewall rule either, because nothing is published beyond
loopback: 8120 is bound to 127.0.0.1, and the user's phone is locked out like everyone else's.
Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/obsidian-livesync/compose.yml
```

Assert: one line, `- "127.0.0.1:8120:5984"`.

## 7. Start and verify

```bash
cd ~/selfhost/obsidian-livesync
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8120/_up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8120/_up
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8120/
```

Assert all three and print what you received for each. The loop ends printing `200`, the next
line prints exactly `{"status":"ok"}`, and the last prints `401`, the security assert here: the
root refuses a request with no credential while `/_up` does not. If any misses, stop, run
`docker compose logs --tail 40 couchdb`. If `port is already allocated` came back, find what
holds 8120 (`lsof -nP -iTCP:8120 -sTCP:LISTEN`, or `netstat -ano | findstr :8120` on Windows) and
stop until the user frees it. A running container is not success.

The plugin creates the database itself in the next step.

STOP: tell the user to read their credentials with
`grep -E 'COUCHDB_USER|COUCHDB_PASSWORD' ~/selfhost/obsidian-livesync/.env`, put both in their
password manager, and wait. Do not continue until they confirm.

STOP: tell the user to set up Obsidian, and wait. Do not continue until they confirm. Steps, in
this order. Back up the vault, then turn off Obsidian Sync, iCloud and every other tool writing
to it, because two synchronisers on one vault duplicate and corrupt notes. In Obsidian: Settings,
Community plugins, turn off Restricted mode, Browse, install and enable `Self-hosted LiveSync`.
Select the `Welcome to Self-hosted LiveSync` notice, choose `I am setting this up for the first
time`, confirm. On `Connection Method` choose `Configure a remote manually`. On
`End-to-End Encryption`, enable it and enter a passphrase they wrote down first: it never reaches
the database and nothing here can recover it. Choose `CouchDB`, enter `http://localhost:8120`,
the credentials from the previous step, and the database name `obsidiannotes`. Select
`Create or connect to database and continue`, then `Restart and Initialise Server`, then
`I Understand, Overwrite Server`, then `Use this device's settings`. Wait for the progress
indicators to clear, then create one note.

Once they confirm, prove the note arrived:

```bash
cd ~/selfhost/obsidian-livesync
set -a; . ./.env; set +a
printf 'user = "%s:%s"\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" | curl -sS -K - http://localhost:8120/obsidiannotes
unset COUCHDB_USER COUCHDB_PASSWORD COUCHDB_SECRET
```

Assert: the response contains `"db_name":"obsidiannotes"` and a `doc_count` above 0. If it is
still 0 the plugin never connected: have them reopen its settings and read the error there.

## 8. First backup and restore

Two artifacts under backups/: the database, streamed out of its volume by `docker cp`, and the
two files that rebuild the service around it.

```bash
cd ~/selfhost/obsidian-livesync
docker compose stop
docker cp -a obsidian-livesync-couchdb:/opt/couchdb/data - | gzip > backups/livesync-data-$(date +%F).tar.gz
tar -C ~/selfhost/obsidian-livesync -czf backups/livesync-config-$(date +%F).tar.gz compose.yml .env
docker compose start
ls -lh backups/
```

Assert: both files exist and are non-empty. Print both sizes. The service stops for the copy
because a copy of a database mid-write is not a backup; downtime is about ten seconds.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination off this computer, a folder their sync service watches
or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both files are listed there.

To restore: untar the config archive into ~/selfhost/obsidian-livesync so compose.yml and .env
are back first, then `docker compose down -v`, the one place `-v` belongs because it drops the
old volume on purpose, then `docker compose create`, then
`gunzip -c backups/<the data archive> | docker cp -a - obsidian-livesync-couchdb:/opt/couchdb`,
then `docker compose up -d` and step 7's `/_up` check. With end-to-end encryption on, every
document in that archive is ciphertext and the passphrase is not in it, so a restored database
without it is a folder of noise. It belongs in the same password manager entry as the CouchDB
password.

## 9. Updating later

New images are listed at https://hub.docker.com/_/couchdb, with release notes at
https://docs.couchdb.org/en/stable/whatsnew/index.html. Back up first, then edit the image line
in the compose file to the new tag and digest:

```bash
cd ~/selfhost/obsidian-livesync
docker compose pull
docker compose up -d
docker compose logs --tail 30 couchdb
```

Re-run step 7's `/_up` check before calling this done. The plugin updates separately, inside
Obsidian, and nothing here pins it.

## 10. What will probably go wrong

I rebooted, opened Obsidian, and watched LiveSync report that it could not reach the database.
Nothing was broken: Docker Desktop had not started with the session, so nothing was listening on
8120 and every edit queued locally until it did. `restart: unless-stopped` only acts once the
Docker daemon is up. Turn on Docker Desktop's start-at-login setting, and after a reboot run
`docker compose up -d` here before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8120 to 0.0.0.0 so a phone can reach it. That puts a database holding every note
  on every network the user joins, and Obsidian on a phone refuses plain HTTP anyway.
- Do not run upstream's `couchdb-init.sh` or its Deno setup-URI generator. Every setting they
  apply is in the compose file, with its source recorded there.
- Do not enable Customisation Sync or Hidden File Sync in the plugin.
