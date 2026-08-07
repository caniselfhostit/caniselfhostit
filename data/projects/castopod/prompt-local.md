You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Castopod 1.15.5, with the MariaDB and Redis it needs, under ~/selfhost/castopod,
answering at http://localhost:8135.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all. The
feed URL Castopod publishes here begins with http://localhost:8135, which means "this computer"
wherever it is read, so Apple Podcasts cannot fetch it, a co-host cannot, and neither can the
user's phone. What they get is a real archive of the show that only this computer opens.

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
distribution ID and codename print next, for step 2. Castopod, MariaDB and Redis need 2048 MB of
RAM available and 10 GB free on the home disk, and the audio is what eats the disk. All three
images publish amd64 and arm64. On macOS and Windows that memory figure is the host's, and
Docker Desktop takes its allocation out of it. If available RAM is under 2048 MB or free disk is
under 10 GB, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/castopod/backups
ls -la ~/selfhost/castopod
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` or `media` folder: step
5 keeps all three data sets in volumes Docker manages, because MariaDB chowns its directory to
its own uid and the image ships /app/public/media owned by its own user. Step 8 copies the audio
back out through the container.

## 4. Secrets

Four secrets: the database password, the MariaDB root password, the Redis password and the
analytics salt. Generate all four here, print none, keep them out of your summary and logs.

```bash
umask 077
cat > ~/selfhost/castopod/.env <<EOF
CP_BASEURL=http://localhost:8135/
DB_PASSWORD=$(openssl rand -hex 32)
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
CP_ANALYTICS_SALT=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/castopod/.env
umask 022
ls -l ~/selfhost/castopod/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. The salt is 64 characters, the length upstream's generator produces,
and it is not an encryption key: Castopod hashes it with the date, the listener's IP and their
user agent so one download counted twice counts once. On Windows the mode bits are advisory.

## 5. compose.yml

```bash
cat > ~/selfhost/castopod/compose.yml <<'EOF'
# Castopod · the deterministic fallback for the local path. Authored by
# caniselfhostit from https://docs.castopod.org/getting-started/docker.html,
# not copied from a repository. Differences from the VPS file, and only these:
# all three data mounts are named volumes, because MariaDB and the Castopod
# image each chown their own directory to a uid a home-directory bind mount
# cannot grant on Windows; and CP_DISABLE_HTTPS is 1, because Castopod
# redirects to https by default, a loop in front of http://localhost.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.
services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: castopod-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: castopod
      MARIADB_USER: castopod
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - castopod-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:`: 3306 stays inside the compose network.

  cache:
    image: redis:8.4.5-alpine@sha256:bd4a0d37e7cd830117ffec9329052b4a1887afa060c265e1768f82b177ff6f43
    container_name: castopod-redis
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - castopod-cache:/data

  castopod:
    image: castopod/castopod:1.15.5@sha256:4e4f0440520f45257bfeac7be4347defd20048b4efef8f53d73ec9ed3a4f7966
    container_name: castopod
    restart: unless-stopped
    environment:
      CP_BASEURL: ${CP_BASEURL}
      CP_ANALYTICS_SALT: ${CP_ANALYTICS_SALT}
      CP_DISABLE_HTTPS: "1"
      CP_DATABASE_HOSTNAME: db
      CP_DATABASE_NAME: castopod
      CP_DATABASE_USERNAME: castopod
      CP_DATABASE_PASSWORD: ${DB_PASSWORD}
      CP_REDIS_HOST: cache
      CP_REDIS_PASSWORD: ${REDIS_PASSWORD}
    volumes:
      - castopod-media:/app/public/media
    healthcheck:
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/health"]
      start_period: 60s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: no other device on the wifi can reach 8135.
      - "127.0.0.1:8135:8080"
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_started

volumes:
  castopod-db:
  castopod-media:
  castopod-cache:
EOF
cd ~/selfhost/castopod && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one port, three named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one, and browsers treat
  http://localhost as a secure context anyway. That is why the compose file sets
  `CP_DISABLE_HTTPS`: Castopod redirects to https by default, and with nothing in front that is
  a loop rather than a protection.
- No firewall rule. Nothing is published beyond loopback.

8135 is bound to 127.0.0.1, this computer only. No phone, no laptop on the same wifi, no
fediverse server. Confirm it:

```bash
grep -n '"127.0.0.1:' ~/selfhost/castopod/compose.yml
```

Assert: one line, `- "127.0.0.1:8135:8080"`. MariaDB and Redis publish no host port.

## 7. Start and verify

On first start the container writes its config, runs every migration, then starts the web server
and its cron. That log prints the whole configuration, so filter it:
`docker compose logs --tail 40 castopod | grep -viE 'password|salt'`.

```bash
cd ~/selfhost/castopod
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8135/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8135/health
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8135/cp-install
curl -sS http://localhost:8135/cp-install | grep -c 'Create your Super Admin account'
```

Assert all four, printing what you received. The loop ends on `200`. The health body contains
`"code":200`, which upstream returns only when the database, the cache and the media directory
all answered. The third prints `200`, the fourth `1`. If any miss, stop, run the filtered log
command above and `docker compose logs --tail 20 db`: a database that never reports healthy is
step 4. If `port is already allocated` came back, find what holds 8135
(`lsof -nP -iTCP:8135 -sTCP:LISTEN`, or `netstat -ano | findstr :8135` on Windows) and stop
until it is freed. A running container is not success.

The first screen at http://localhost:8135/cp-install shows `4/4` beside the heading
`Create your Super Admin account`, with Username, Email and Password fields.

STOP: tell the user to open http://localhost:8135/cp-install, create their account with a
password of at least 8 characters that is not a dictionary word, put it in their password
manager, and wait. Do not continue until they confirm they are signed in. Self-registration is
off, so that account is the only way in.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8135/cp-install
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from cp_users where is_owner = 1" "$MARIADB_DATABASE"'
```

Assert both. The first prints `404`: once an owner exists the installer refuses everyone else,
the security assert here. The second prints `1`, one owner.

## 8. First backup and restore

Three artifacts: a dump with the shows, episodes and download history, the audio, and the config
archive that rebuilds the service around them.

```bash
cd ~/selfhost/castopod
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > backups/castopod-db-$(date +%F).sql.gz
docker compose exec -T castopod tar -C /app/public/media -czf - . > backups/castopod-media-$(date +%F).tar.gz
tar -C ~/selfhost/castopod -czf backups/castopod-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/castopod/backups/
```

Assert: all three exist, all three non-empty, all three sizes printed. Nothing is stopped;
`mariadb-dump` snapshots a running database consistently. The media archive grows: kilobytes
today, the largest file on this disk after a year of episodes.

All three sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB
stick, and copy all three there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms all three filenames are there, or say plainly that this
install has no backup.

To restore: `cd ~/selfhost/castopod`, untar the config archive there first, because MariaDB
takes `DB_PASSWORD` from .env the moment it initialises an empty volume. Then
`docker compose down -v`, the one place `-v` belongs because it drops the old volumes on
purpose, `docker compose up -d db`, wait 30 seconds for healthy, pipe `gunzip -c` on the
`.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
`docker compose up -d`, then
`docker compose exec -T castopod tar -C /app/public/media -xzf - < backups/castopod-media-<date>.tar.gz`.
Open one episode and play it. That is the disaster plan.

## 9. Updating later

New versions are at https://code.castopod.org/adaures/castopod/-/releases, mirrored at
https://github.com/ad-aures/castopod/tags. Back up first, then edit the castopod image line in
compose.yml to the new tag and digest:

```bash
cd ~/selfhost/castopod
docker compose pull
docker compose up -d
docker compose logs --tail 40 castopod | grep -viE 'password|salt'
```

The container migrates on every start. Watch that log until it settles, then re-run step 7's
health check.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8135, got a connection error, and spent ten
minutes convinced the database had been eaten. It had not: Docker Desktop had not started with
the session, so nothing was listening on 8135. `restart: unless-stopped` acts only once the
Docker daemon is up. Turn on start-at-login, then after a reboot run
`cd ~/selfhost/castopod && docker compose up -d` before concluding anything broke.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `CP_BASEURL` to this machine's LAN address and do not rebind 8135 to 0.0.0.0 so
  a phone can reach it. That publishes an admin login on every network the user joins.
- Do not configure SMTP, and do not set `CP_MEDIA_FILE_MANAGER` or any `CP_MEDIA_S3_` variable.
  Each is a different install with a different bill.
