You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install BookStack 26.05.3, with the MariaDB it keeps every page in, under ~/selfhost/bookstack,
answering at http://localhost:8150.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install. BookStack is a
team wiki, and this one answers at http://localhost:8150, which means "this computer" wherever
it is read: a colleague sent that link gets an error, and so does the user's own phone.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
ID and codename print next, for step 2. BookStack plus MariaDB needs 1024 MB of RAM available
and 5 GB free on the home disk, and both images publish amd64 and arm64. On macOS and Windows
that memory figure is the host's, minus Docker Desktop's VM. Under either floor, stop.

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
mkdir -p ~/selfhost/bookstack/config ~/selfhost/bookstack/backups
ls -la ~/selfhost/bookstack
```

Assert: `config` and `backups`, owned by the user. `config` holds uploaded images, attachments
and themes; the pages are rows in MariaDB.

## 4. Secrets

Four secrets, generated here: the application key, the database password, the MariaDB root
password, and the administrator's password. Print none, and keep all four out of your summary
and every log line.

```bash
umask 077
cat > ~/selfhost/bookstack/.env <<EOF
APP_URL=http://localhost:8150
ADMIN_EMAIL=you@example.com
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> ~/selfhost/bookstack/.env
chmod 600 ~/selfhost/bookstack/.env
umask 022
ls -l ~/selfhost/bookstack/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run the same on all three.
`APP_KEY` encrypts whatever BookStack stores encrypted, so this file is the most valuable thing
under ~/selfhost. `ADMIN_EMAIL` is only a sign-in name: ask the user once and put their answer
in this file. On Windows the mode bits are advisory; the boundary is their own account.

## 5. compose.yml

```bash
cat > ~/selfhost/bookstack/compose.yml <<'EOF'
# BookStack · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   installation ... https://www.bookstackapp.com/docs/admin/installation/
#   configuration .. https://github.com/BookStackApp/BookStack/blob/v26.05.3/.env.example.complete
#   image docs ..... https://docs.linuxserver.io/images/docker-bookstack/
#
# BookStack ships no Docker image of its own; its installation page points at
# community docker setups. This uses the LinuxServer.io one, GPL-3.0, unpacking
# BookStack's own 26.05.3 release archive onto their Alpine and nginx base
# image. The application is upstream's, the packaging is not.
#
# Paths are relative to ~/selfhost/bookstack/, so one file works on all three
# systems. The database is a named volume because MariaDB chowns its data
# directory to a uid Docker Desktop cannot grant on a Windows bind mount;
# config/ is a bind mount, owned by PUID/PGID. Digests read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: bookstack-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: bookstack
      MARIADB_USER: bookstack
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - bookstack-dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  bookstack:
    image: lscr.io/linuxserver/bookstack:version-v26.05.3@sha256:7f0af07baa41fd6265f5ec57887564d85be03a326f79cb32f926fe735e5313ff
    container_name: bookstack
    restart: unless-stopped
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: Etc/UTC
      APP_URL: ${APP_URL}
      # Session and at-rest key. The image halts its init without one.
      APP_KEY: ${APP_KEY}
      DB_HOST: db
      DB_PORT: "3306"
      DB_DATABASE: bookstack
      DB_USERNAME: bookstack
      DB_PASSWORD: ${DB_PASSWORD}
      # Neither is a BookStack setting. They let step 7 hand them to the
      # command that replaces the seeded account, off the command line.
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
    volumes:
      - ./config:/config
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1/status || exit 1"]
      start_period: 30s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: no other device on the wifi reaches 8150.
      - "127.0.0.1:8150:80"
    depends_on:
      db:
        condition: service_healthy

volumes:
  bookstack-dbdata:
EOF
cd ~/selfhost/bookstack && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, no public name for
a certificate to attest, nothing published beyond loopback to close. Browsers treat
http://localhost as a secure context anyway, so pages needing crypto still work.

8150 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone on the
internet. That is the point of this path, not a gap in it. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/bookstack/compose.yml
```

Assert: `1`, the published-port line. MariaDB publishes no host port, so 3306 cannot appear.

## 7. Start and verify

Read this first. BookStack's first migration seeds `admin@admin.com` with the password
`password`, a pair the image's install notes publish. That account is real, so run this in one
go.

```bash
cd ~/selfhost/bookstack
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8150/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8150/status
docker compose exec -T --user abc bookstack sh -c 'php /app/www/artisan bookstack:create-admin --initial --no-ansi --name="Site administrator" --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD"'
curl -sS http://localhost:8150/login | grep -c 'list-heading">Log In<'
```

Assert all four, printing what you got. The loop ends on `200`. Status is
`{"database":true,"cache":true,"session":true}`. The console prints
`The default admin user has been updated with the provided details!`, proof it rewrote the
seeded account rather than adding a second one. The last prints `1`.

Now prove the published credential is dead:

```bash
shipped=password
jar=$(mktemp)
tok=$(curl -sS -c "$jar" http://localhost:8150/login | sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' | head -1)
echo "csrf token length ${#tok}"
curl -sS -b "$jar" -c "$jar" -L -d "_token=$tok" -d "email=admin@admin.com" -d "password=$shipped" http://localhost:8150/login | grep -c 'These credentials do not match our records'
rm -f "$jar"
unset shipped
```

Assert: the token length is not `0` and the last line prints `1`, BookStack's wording for a
rejected sign-in and the security assert here. A zero-length token means a missing token, not a
wrong password, so treat it as a failure too. A `0` count means the old pair still works: stop,
and do not report success. On any other miss run `docker compose logs --tail 60 bookstack`: a
database never reporting healthy is step 4, `port is already allocated` is step 10.
A running container is not success.

The first screen at http://localhost:8150/login shows the heading `Log In` above an `Email`
field, a `Password` field and a `Log In` button.

STOP: tell the user to read their password with
`grep ADMIN_PASSWORD ~/selfhost/bookstack/.env`, put it in their password manager, sign in at
http://localhost:8150/login as the address in `ADMIN_EMAIL`, and wait.
Do not continue until they confirm the empty shelves page. Nothing sends reset mail, so that
is the only copy.

## 8. First backup and restore

Two artifacts: a dump holding every shelf, book, chapter, page and revision, and an archive of
the uploads plus the two files that rebuild the service around them, plus `APP_KEY`.

```bash
cd ~/selfhost/bookstack
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/bookstack/backups/bookstack-db-$(date +%F).sql.gz
tar -C ~/selfhost/bookstack -czf ~/selfhost/bookstack/backups/bookstack-config-$(date +%F).tar.gz compose.yml .env config
ls -lh ~/selfhost/bookstack/backups/
```

Assert: both exist, both non-empty, both sizes printed. Nothing goes offline: the tables are
InnoDB, so the dump snapshots consistently while the wiki keeps serving.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`; in Git Bash a Windows drive is `/d/...`.
Assert: both filenames are listed there, or this has no backup.

To restore: untar the config archive into ~/selfhost/bookstack first, so `.env` and `config`
are back before any container starts. MariaDB reads `DB_PASSWORD` from `.env` when it
initialises an empty volume, and `APP_KEY` is the only key that decrypts the dump. Then
`docker compose down -v`, the one place `-v` belongs, `docker compose up -d db`, wait 30s, pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`, sign in, open a page.

## 9. Updating later

Versions are listed at https://github.com/BookStackApp/BookStack/releases and the image tags at
https://github.com/linuxserver/docker-bookstack/tags. Back up first, then edit the image line
in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/bookstack
docker compose pull
docker compose up -d
docker compose logs --tail 40 bookstack
```

The image migrates the schema on every start, so a version bump migrates the database itself.
Watch the log until it settles, then re-run step 7's check.

## 10. What will probably go wrong

Something else already owns 8150. Mine was a dev server I had forgotten about, and
`docker compose up -d` answered `port is already allocated`, which reads like a Docker fault
rather than a neighbour. Find what holds it (`lsof -nP -iTCP:8150 -sTCP:LISTEN`, or
`netstat -ano | findstr :8150` on Windows) and stop until the user frees it. Do not quietly
move BookStack elsewhere: 8150 sits inside `APP_URL` and inside every link the wiki stores, so
changing it later means running BookStack's update-url command over the database.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8150 to 0.0.0.0 so a phone can reach it, and do not point `APP_URL` at this
  machine's LAN address. That puts a wiki with one password on every network the user joins.
- Do not configure SMTP, LDAP, SAML or OIDC. The wiki works without all four, and an identity
  provider replaces the account step 7 secured.
