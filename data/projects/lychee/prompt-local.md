You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Lychee 7.7.2, with the MariaDB it keeps albums and photo metadata in, under
~/selfhost/lychee, answering at http://localhost:8195.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install. Lychee is a
gallery you hand people a link to, and this one answers at http://localhost:8195, so a link sent
to a client opens nothing. What they get is their own catalogue, with no cap but the disk.

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
and codename print next, for step 2. Lychee plus MariaDB needs 2048 MB of RAM available and 10 GB
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
mkdir -p ~/selfhost/lychee/uploads ~/selfhost/lychee/logs ~/selfhost/lychee/tmp ~/selfhost/lychee/backups
ls -la ~/selfhost/lychee
```

Assert: four directories, owned by the user. `uploads` is the half a database dump cannot
rebuild; `tmp` and `logs` are working space. No ownership fix runs here, and step 5 says why.

## 4. Secrets

Three, all generated here. `APP_KEY` is the Laravel application key and the container refuses to
boot without one decoding to exactly 32 bytes; the others are the `lychee` database user's and
MariaDB root passwords. Lychee ships no account. Print none of the three, in chat, summary or log.

```bash
umask 077
cat > ~/selfhost/lychee/.env <<EOF
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/lychee/.env
umask 022
ls -l ~/selfhost/lychee/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so this runs the same on all three, and
Compose reads the file for the `${...}` substitutions without mounting it. On Windows mode bits
are advisory; the real boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/lychee/compose.yml <<'EOF'
# Lychee · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker guide ..... https://lycheeorg.dev/docs/getting-started/docker/
#   compose template . https://github.com/LycheeOrg/Lychee/blob/v7.7.2/docker-compose.yaml
#   entrypoint ....... https://github.com/LycheeOrg/Lychee/blob/v7.7.2/docker/scripts/entrypoint.sh
#
# Lychee plus the MariaDB holding albums, users, tags and photo metadata.
# MariaDB because upstream's README compose and the DB_CONNECTION default both
# say mysql. Paths are relative to ~/selfhost/lychee/, so one file works on
# macOS, Linux and Windows, and uploads stays a bind mount so the photos show
# up in Finder or Explorer. The database is a named volume: MariaDB chowns its
# data dir to a uid Docker Desktop cannot grant on a home bind mount. Digests
# read from the registries on 2026-08-14.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: lychee-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: lychee
      MARIADB_USER: lychee
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - lychee-dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  lychee:
    image: lycheeorg/lychee:v7.7.2@sha256:daacbba4876b3b73e4d46be1f4858f43cb2256c9c506c0ab7f333a8d9c993c00
    container_name: lychee
    restart: unless-stopped
    environment:
      # No APP_KEY, no boot: the entrypoint checks it decodes to 32 bytes.
      APP_KEY: ${APP_KEY}
      # Every album link and image URL is built from APP_URL, and on this path
      # the loopback address is the only address this gallery has.
      APP_URL: http://localhost:8195
      APP_FORCE_HTTPS: "false"
      APP_ENV: production
      APP_DEBUG: "false"
      TIMEZONE: UTC
      DB_CONNECTION: mysql
      DB_HOST: db
      # The entrypoint waits on this port with nc, so it is never left unset.
      DB_PORT: "3306"
      DB_DATABASE: lychee
      DB_USERNAME: lychee
      DB_PASSWORD: ${DB_PASSWORD}
      # sync: the request that uploads a photo also builds its thumbnails.
      # database would queue that for a worker this file does not run, and
      # Octane cuts a request at 30s by default, that upload's real ceiling.
      QUEUE_CONNECTION: sync
      LYCHEE_MAX_EXECUTION_TIME: "180"
      # No PUID here, unlike the VPS file: the start-up script takes only
      # 33 to 65534, and `id -u` on macOS or Git Bash sits outside that.
    volumes:
      # uploads is the half of the backup a database dump cannot rebuild.
      - ./uploads:/app/public/uploads
      - ./logs:/app/storage/logs
      - ./tmp:/app/storage/tmp
    healthcheck:
      # /up answers 200 before any account exists, which the app root does not.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8000/up || exit 1"]
      start_period: 60s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: no other device on the wifi reaches 8195.
      - "127.0.0.1:8195:8000"
    depends_on:
      db:
        condition: service_healthy

volumes:
  lychee-dbdata:
EOF
cd ~/selfhost/lychee && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, no public name to
attest, nothing beyond loopback to close. Browsers treat http://localhost as a secure context.

8195 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone on the
internet. That is the trade this path makes, and its point. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/lychee/compose.yml
```

Assert: `1`, the published-port line. MariaDB publishes no host port, so 3306 never appears.

## 7. Start and verify

The first start migrates the database and caches config, routes and views.

```bash
cd ~/selfhost/lychee
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8195/up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8195/up | grep -c 'Lychee is up'
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://localhost:8195/
curl -sS http://localhost:8195/install/admin | grep -c 'Set up admin account'
```

Assert all four, printing what you received. The loop ends on `200`. The grep prints above `0`,
`Lychee is up` being the heading the health page renders. The third prints
`307 http://localhost:8195/install/admin`, Lychee sending every page to the setup form until an
administrator exists. The last prints `1`, the form itself. A running container is not success:
on any miss, stop and run `docker compose logs --tail 40 lychee` and `--tail 20 db`, where a
database never reporting healthy or `APP_KEY is not set` is step 4 and `port is already
allocated` is step 10. That form is the only door: the create-admin helper is never run here.

STOP: tell the user to open http://localhost:8195/install/admin, fill in a username and a password
twice, and press Create admin account, and wait. Do not continue until they confirm. That page
carries the browser title `Lychee Installer` and the words `Set up admin account.` and ends on
`Admin account has been created.` It is this gallery's only credential, no mail is relayed so
there is no reset, and it belongs in a password manager first.

Once they confirm, prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8195/install/admin
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8195/
```

Assert both, printing what you received. The first prints `403`: the setup route carries a guard
throwing `Admin User has already been set` once an administrator exists. The second prints `200`,
the gallery rather than a redirect. Anything but `403`, stop and say so rather than report
success. Self-registration is already shut, at `user_registration_enabled` 0.

## 8. First backup and restore

Two artifacts: a dump holding albums, tags, users and photo metadata, and an archive of photos.

```bash
cd ~/selfhost/lychee
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/lychee/backups/lychee-db-$(date +%F).sql.gz
tar -C ~/selfhost/lychee -czf ~/selfhost/lychee/backups/lychee-files-$(date +%F).tar.gz compose.yml .env uploads
ls -lh ~/selfhost/lychee/backups/
```

Assert: both exist, both non-empty, both sizes printed. Nothing goes offline, because
`--single-transaction` snapshots a running InnoDB database, and on Linux the photo files are
world-readable, so `tar` needs no privilege.

Both sit on the same disk as the photos, which is not a backup, and on a laptop the disk and the
machine fail together. Ask for a destination off this computer and copy both there with `cp`; in
Git Bash that is `/d/Backups`, not `D:\Backups`. Assert: both filenames are listed there, or say
plainly that this install has no backup.

To restore: `cd ~/selfhost/lychee`, `docker compose down -v`, `rm -rf uploads`, untar the archive
there so `.env` and the photos are back before anything starts, `docker compose up -d db`, wait
30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`. MariaDB reads `.env` when it initialises an empty volume, and a dump
without the photos leaves albums listing nothing.

## 9. Updating later

Versions are listed at https://github.com/LycheeOrg/Lychee/releases and the tags carrying them at
https://hub.docker.com/r/lycheeorg/lychee/tags. Ignore any `-legacy` tag: the older nginx build,
deprecated upstream. Back up first, then edit the lychee image line to the new tag and digest:

```bash
cd ~/selfhost/lychee
docker compose pull
docker compose up -d
docker compose logs --tail 40 lychee
```

The entrypoint migrates the database on every start, so watch until those lines stop, then re-run
step 7's checks. Sessions live in the container, so this signs the user out.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8195 and got a connection refused that reads like a lost
library. Nothing was lost: Docker Desktop had not started with the session, so nothing listened
on 8195, and `restart: unless-stopped` only acts once the daemon is up. Turn on its
start-at-login setting, and after a reboot run `cd ~/selfhost/lychee && docker compose up -d`
before concluding anything broke. `lsof -nP -iTCP:8195 -sTCP:LISTEN` finds a port already taken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8195 to 0.0.0.0 for a phone. That publishes the gallery to every network joined.
- Do not add the worker container or switch `QUEUE_CONNECTION` to `database`. This prompt backs
  up and checks two services, and that would be a third.
- Do not configure SMTP, OAuth or LDAP. Mail from a sleeping machine is a queue, not a delivery.
