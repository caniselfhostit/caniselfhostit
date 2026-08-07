You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Piwigo 16.4.0, with the MariaDB it keeps albums and photo metadata in, under
~/selfhost/piwigo, answering at http://localhost:8159.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install. Piwigo is a gallery
you publish, and this one answers at http://localhost:8159, which means "this computer" wherever it
is read: an album link sent to family opens nothing. They get a private catalogue of their own
library, with albums, tags and search.

Detect the OS and measure:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the ID
and codename print next, for step 2. Piwigo plus MariaDB needs 1024 MB of RAM available and 10 GB
free on the home disk, and both images publish amd64 and arm64. Under either floor, stop.

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
mkdir -p ~/selfhost/piwigo/gallery ~/selfhost/piwigo/backups
ls -la ~/selfhost/piwigo
```

Assert: `gallery` and `backups`, owned by the user. `gallery` is the whole of Piwigo on disk: the
PHP tree the image copies in, the config the installer writes under `local/config`, and every photo
uploaded after.

## 4. Secrets

Two secrets: the `piwigo` database user's password and the MariaDB root password. Piwigo ships no
account and no admin token; the webmaster is created in the browser in step 7. Print neither
value, and keep both out of your summary and every log line.

```bash
umask 077
cat > ~/selfhost/piwigo/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
printf 'PIWIGO_UID=%s\nPIWIGO_GID=%s\n' "$(id -u)" "$(id -g)" >> ~/selfhost/piwigo/.env
chmod 600 ~/selfhost/piwigo/.env
umask 022
ls -l ~/selfhost/piwigo/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run the same on all three, and
`DB_PASSWORD` is read back once in step 7. On Windows the mode bits are advisory and the boundary
is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/piwigo/compose.yml <<'EOF'
# Piwigo · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ... https://piwigo.org/guides/install/docker
#   image README ..... https://github.com/Piwigo/piwigo-docker/blob/v16.4a/README.md
#   image init ....... https://github.com/Piwigo/piwigo-docker/blob/v16.4a/config/init-script.sh
#
# The image is the Piwigo project's own, built from github.com/Piwigo/piwigo-docker:
# Alpine with nginx and php-fpm, tagged 16.4.0a for Piwigo 16.4.0. Paths are
# relative to ~/selfhost/piwigo/, so one file works on all three systems. The
# database is a named volume because MariaDB chowns its data directory to a uid
# Docker Desktop cannot grant on a home bind mount. Digests read 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: piwigo-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: piwigo
      MARIADB_USER: piwigo
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - piwigo-dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  piwigo:
    image: piwigo/piwigo:16.4.0a@sha256:0ec6f159a3f972338b64e299d56ac37c442dd26cbeec39320d76ea826b5e0b84
    container_name: piwigo
    restart: unless-stopped
    environment:
      # The image's init reads TZ with `set -u`, so it is never left unset.
      TZ: Etc/UTC
      # On macOS and Windows the image cannot set an ACL on a bind mount and
      # falls back to chmod, warning as it does; that is expected.
      PIWIGO_UID: "${PIWIGO_UID}"
      PIWIGO_GID: "${PIWIGO_GID}"
    volumes:
      # The release the image ships, the config the installer writes, the photos.
      - ./gallery:/var/www/html/piwigo
    healthcheck:
      # / answers 302 to install.php before the installer runs and 200 after.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1/ || exit 1"]
      start_period: 60s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: no other device on the wifi reaches 8159.
      - "127.0.0.1:8159:80"
    depends_on:
      db:
        condition: service_healthy

volumes:
  piwigo-dbdata:
EOF
cd ~/selfhost/piwigo && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, no public name to
attest, nothing published beyond loopback to close. Browsers treat http://localhost as a secure
context anyway, so pages needing crypto still work.

8159 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone on the
internet. That is the trade this path makes, and the point of it. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/piwigo/compose.yml
```

Assert: `1`, the published-port line. MariaDB publishes no host port, so 3306 cannot appear.

## 7. Start and verify

The first start copies about 60 MB of PHP into gallery/ and chowns every file. Give it a minute.

```bash
cd ~/selfhost/piwigo
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8159/install.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8159/install.php | grep -c 'Start Install'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8159/
```

Assert all three, printing what you received. The loop ends on `200`, the grep prints `1`, and the
last prints `302`, because Piwigo sends every page to install.php until the installer has run. On a
miss, stop and run `docker compose logs --tail 40 piwigo` and `docker compose logs --tail 20 db`: a
database never reporting healthy is step 4, `port is already allocated` is step 10. A running
container is not success.

The first screen at http://localhost:8159/install.php shows the heading
`Version 16.4.0 - Installation` above three boxes, `Basic configuration`, `Database configuration`
and `Admin configuration`, and a `Start Install` button.

STOP: tell the user to open http://localhost:8159/install.php, fill the form and press Start
Install, and wait. Do not continue until they confirm. Give them these values and nothing else.
Host `db`, User `piwigo`, Database name `piwigo`, prefix `piwigo_` left alone. The password they
fetch with `grep DB_PASSWORD ~/selfhost/piwigo/.env`, into the database box, not the admin box. In
the admin box they pick their own username, password and email; that is this gallery's only
credential, so it goes in their password manager first. Have them untick
`Send my connection settings by email`, because nothing here relays mail.

Once they confirm, close the door the installer leaves open and prove it is shut:

```bash
cd ~/selfhost/piwigo
docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' <<'EOF'
UPDATE piwigo_config SET value = 'false' WHERE param = 'allow_user_registration';
EOF
curl -sS http://localhost:8159/install.php
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8159/register.php
curl -sS 'http://localhost:8159/ws.php?format=json&method=pwg.getVersion'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8159/
```

Assert all four, printing what you received. install.php answers exactly
`Piwigo is already installed`, so that URL is no longer a setup form. register.php answers `403`:
Piwigo ships with open sign-up on and this install does not want it. The web API returns
`{"stat":"ok","result":"16.4.0"}`, PHP talking to MariaDB and back. The last prints `200`.

## 8. First backup and restore

Two artifacts: a dump holding albums, tags, users, permissions and photo metadata, and an archive
of the photos plus the config that rebuilds the service around them.

```bash
cd ~/selfhost/piwigo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/piwigo/backups/piwigo-db-$(date +%F).sql.gz
tar --exclude='gallery/_data' -C ~/selfhost/piwigo -czf ~/selfhost/piwigo/backups/piwigo-files-$(date +%F).tar.gz compose.yml .env gallery
ls -lh ~/selfhost/piwigo/backups/
```

Assert: both exist, both non-empty, both sizes printed. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database. `gallery/_data` is left out because
Piwigo rebuilds those resized copies from the originals on demand, and on a real library they are
the largest disposable thing in the tree.

Both archives sit on the same disk as the photos, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or an external drive, and copy both there with `cp`; in Git Bash a Windows drive is `/d/...`.
Assert: both filenames are listed there, or this install has no backup.

To restore: untar the file archive into ~/selfhost/piwigo first, so `.env` and the gallery are back
before any container starts. MariaDB reads `DB_PASSWORD` from `.env` when it initialises an empty
volume, and `gallery/local/config/database.inc.php` tells Piwigo it is installed. Then
`docker compose down -v`, `docker compose up -d db`, wait 30 seconds, pipe `gunzip -c` on the
`.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d` and open an album.

## 9. Updating later

Versions are listed at https://github.com/Piwigo/Piwigo/releases and the image tags at
https://hub.docker.com/r/piwigo/piwigo/tags. Back up first, then edit the piwigo image line to the
new tag and digest:

```bash
cd ~/selfhost/piwigo
docker compose pull
docker compose up -d
docker compose logs --tail 40 piwigo
```

The image compares the version it ships against the one in gallery/ and copies the newer files
over, so the log prints `Updating to piwigo version` and the number. Re-run step 7's check.

## 10. What will probably go wrong

I closed the lid, came back next morning, opened http://localhost:8159 and got a connection error
that reads like a lost library. Nothing was lost: Docker Desktop had not started with the session,
so nothing was listening on 8159, and `restart: unless-stopped` acts only once the daemon is up.
Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/piwigo && docker compose up -d` before concluding anything is broken. The other
candidate is 8159 already taken: `lsof -nP -iTCP:8159 -sTCP:LISTEN` finds it.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8159 to 0.0.0.0 so a phone can reach it. Piwigo's shipped default lets a visitor
  browse without an account, so that publishes the gallery to every network the user joins.
- Do not turn registration back on, and do not configure SMTP. Mail from a laptop that sleeps is
  a queue rather than a delivery.
- Do not install plugins or themes yet. Each writes into the directory the image overwrites on
  upgrade.
