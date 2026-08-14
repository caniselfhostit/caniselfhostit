You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Mixpost Lite 2.6.0, with the MySQL and Redis it needs, under ~/selfhost/mixpost,
answering at http://localhost:8197.

## 1. Preflight

Say this before step 2; it decides whether the user wants this install at all. Everything
answers at http://localhost:8197, so a post scheduled for 9am goes out only if the machine
is awake at 9am, and the callback URL Mixpost hands a developer portal is a localhost
address that X and Meta refuse. Mastodon needs no app in a company's portal, so it is the
provider this path can connect.

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux
the ID and codename print next, for step 2. This stack needs 2048 MB of RAM available and
10 GB free on the home disk, and all three images are amd64 and arm64. If either is under
that, print both numbers and stop.

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
mkdir -p ~/selfhost/mixpost/backups ~/selfhost/mixpost/storage ~/selfhost/mixpost/logs
ls -la ~/selfhost/mixpost
```

Assert: three directories, all owned by the user. MySQL and Redis keep their data in volumes
Docker manages, so nothing here needs an ownership fix. On Linux the container chowns
`storage` and `logs` to www-data at first start; mode 755 keeps them readable to you, which
step 8 relies on. On macOS and Windows, Docker Desktop owns that problem.

## 4. Secrets

Four, all generated here. Print none of them, and keep them out of your summary and any log
line.

```bash
umask 077
cat > ~/selfhost/mixpost/.env <<EOF
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/mixpost/.env
umask 022
ls -l ~/selfhost/mixpost/.env
```

Assert: mode `-rw-------`. `APP_KEY` is a Laravel key for AES-256-CBC, 32 random bytes in
base64, and it encrypts every stored provider secret and social token. `ADMIN_PASSWORD`
reaches no container: step 7 sets it on the account the image creates. Compose reads this
file from the working directory, so run everything from ~/selfhost/mixpost. On Windows the
mode bits are advisory and the boundary is the user's account.

## 5. compose.yml

```bash
cat > ~/selfhost/mixpost/compose.yml <<'EOF'
# Mixpost Lite · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ...... https://docs.mixpost.app/lite/installation/docker
#   variable reference .. https://docs.mixpost.app/lite/configuration/environment-variables
#   troubleshooting ..... https://docs.mixpost.app/troubleshooting
#
# Three services, every path relative to ~/selfhost/mixpost/ so one file works
# on macOS, Linux and Windows. MySQL and Redis get named volumes, because they
# chown their data directory to a uid of their own and Docker Desktop cannot
# grant that on a Windows bind mount; the media library and the log stay
# relative binds. Nothing terminates TLS here, so no trusted-proxy file is
# needed. mysql is pinned on the 8.4 LTS line, not the mysql/mysql-server
# repository upstream names, whose newest tag is 8.0.32 from January 2023.
# Digests read 2026-08-14, all amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: mixpost

services:
  mysql:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    restart: unless-stopped
    environment:
      # The image will not initialise without a root variable; nothing
      # connects as root here.
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: mixpost
      MYSQL_USER: mixpost
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - mixpost-mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", 'mysqladmin ping -h 127.0.0.1 -u "$$MYSQL_USER" -p"$$MYSQL_PASSWORD" --silent']
      interval: 10s
      retries: 18
    # No `ports:` at all: 3306 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - mixpost-redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  mixpost:
    image: inovector/mixpost:v2.6.0@sha256:90cf94cec73dcaf87989d30b0de7a84b0625ff06797ba61c8ecb54e8fe1e10c4
    restart: unless-stopped
    environment:
      APP_NAME: Mixpost
      # Every stored provider secret and social token is encrypted with this.
      APP_KEY: ${APP_KEY}
      APP_DEBUG: "false"
      APP_URL: "http://localhost:8197"
      DB_HOST: mysql
      DB_PORT: "3306"
      DB_DATABASE: mixpost
      DB_USERNAME: mixpost
      DB_PASSWORD: ${DB_PASSWORD}
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      MIXPOST_DISK: public
    volumes:
      - ./storage:/var/www/html/storage/app
      - ./logs:/var/www/html/storage/logs
    ports:
      # Loopback only: no other device on the wifi can reach 8197.
      - "127.0.0.1:8197:80"
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  mixpost-mysql:
  mixpost-redis:
EOF
cd ~/selfhost/mixpost && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK` and nothing else. An unset-variable warning means step 4 did not write
.env into ~/selfhost/mixpost.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. There is no hostname to resolve and a
certificate attests a public name nothing here has; browsers treat http://localhost as
secure anyway.

```bash
grep -c '"127.0.0.1:' ~/selfhost/mixpost/compose.yml
```

Assert: `1`. That line is `- "127.0.0.1:8197:80"`: not the user's phone, not a laptop on the
same wifi, not anyone on the internet. MySQL and Redis publish no host port. Outbound calls
still work: a loopback binding governs what arrives, not what the container can call.

## 7. Start and verify

MySQL initialises its data directory, then Mixpost waits for it and runs every migration, so
the first start is the slow one.

```bash
cd ~/selfhost/mixpost
docker compose pull
docker compose up -d
for i in $(seq 1 42); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8197/mixpost/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8197/mixpost/login | grep -c 'Log in'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8197/horizon
curl -sS -o /dev/null -w '%{redirect_url}\n' http://localhost:8197/mixpost
```

Assert all four, printing what you received. The loop ends on `200`. The grep prints `1`,
the sign-in button. `/horizon` prints `403`: the queue dashboard this image mounts refuses
anyone not signed in. The last prints `http://localhost:8197/mixpost/login`. On any miss,
stop and run `docker compose logs --tail 40 mixpost`; a MySQL container stuck below healthy
points at step 4, and `port is already allocated` means something else holds 8197
(`lsof -nP -iTCP:8197 -sTCP:LISTEN`, or `netstat -ano | findstr :8197` on Windows).

Now close the door the image leaves open. `start.sh` in the container creates
`admin@example.com` whenever that row is missing, with the password upstream prints in its
install guide. Sign in with it once, replace it, prove the published one is dead:

```bash
cd ~/selfhost/mixpost
umask 077
B=http://localhost:8197
tok() { sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p'; }
printf '%s' "$(grep '^ADMIN_PASSWORD' .env | cut -d= -f2-)" > .newpw
rm -f .jar
T=$(curl -sS -c .jar $B/mixpost/login | tok)
curl -sS -b .jar -c .jar -o /dev/null -w 'seeded %{redirect_url}\n' -X POST $B/mixpost/login --data-urlencode "_token=$T" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme'
T=$(curl -sS -b .jar -c .jar $B/mixpost/profile | tok)
curl -sS -b .jar -c .jar -o /dev/null -w 'rotate %{http_code}\n' -X PUT $B/mixpost/profile/password --data-urlencode "_token=$T" --data-urlencode 'current_password=changeme' --data-urlencode 'password@.newpw' --data-urlencode 'password_confirmation@.newpw'
rm -f .jar
T=$(curl -sS -c .jar $B/mixpost/login | tok)
curl -sS -b .jar -c .jar -o /dev/null -w 'published %{redirect_url}\n' -X POST $B/mixpost/login --data-urlencode "_token=$T" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme'
rm -f .jar .newpw
umask 022
```

Assert three lines. `seeded http://localhost:8197/mixpost` is the published password
working, the door being closed. `rotate 302`. `published
http://localhost:8197/mixpost/login` is that credential bounced back, the closure. If the
third still ends in `/mixpost`, stop and have the user change it in the browser at once.

STOP: tell the user to open http://localhost:8197/mixpost/login and sign in as
`admin@example.com`, with the password from `grep ADMIN_PASSWORD ~/selfhost/mixpost/.env`.
Do not continue until they confirm they see the dashboard. Tell them not to change that
email address: the container recreates it with the published password whenever it is gone.

## 8. First backup and restore

Two artifacts. The dump holds the accounts, posts, calendar and encrypted provider
credentials; the archive holds what rebuilds the service around it, and `APP_KEY` in `.env`
is what decrypts them.

```bash
cd ~/selfhost/mixpost
docker compose exec -T mysql sh -c 'exec mysqldump -u mixpost -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces mixpost' | gzip > ~/selfhost/mixpost/backups/mixpost-db-$(date +%F).sql.gz
tar -C ~/selfhost/mixpost -czf ~/selfhost/mixpost/backups/mixpost-files-$(date +%F).tar.gz compose.yml .env storage logs
ls -lh ~/selfhost/mixpost/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops:
`--single-transaction` snapshots InnoDB consistently, and `--no-tablespaces` is there
because the app user has no PROCESS privilege. Redis is in neither: it holds a queue this
install rebuilds.

Both sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination off this computer, a sync folder or a USB stick,
and copy both there with `cp`; in Git Bash a Windows drive is written `/d/Backups`. Assert:
the user confirms both are listed there.

To restore, in this order. `cd ~/selfhost/mixpost`, untar the archive there first so
compose.yml and .env are back before any container starts: MySQL takes its password from
.env the moment it initialises an empty volume. Then `docker compose down -v`,
`docker compose up -d mysql`, wait 60 seconds, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u mixpost -p"$MYSQL_PASSWORD" mixpost'`,
then `docker compose up -d`.

## 9. Updating later

Releases are listed at https://github.com/inovector/mixpost/releases and the image tags at
https://hub.docker.com/r/inovector/mixpost/tags. Read both: the repository is the Laravel
package, the image is that package inside an application skeleton. 2.6.0 of 2026-03-16 is
the newest of either as of 2026-08-14, and the date of the last commit on main. Back up,
then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/mixpost
docker compose pull
docker compose up -d
docker compose logs --tail 30 mixpost
```

The container migrates its own database on the way up, so watch that log until it settles,
then re-run step 7's four checks.

## 10. What will probably go wrong

I scheduled a post for the next morning, closed the lid, and found it still in the calendar
the following afternoon. Nothing was broken: a scheduled post is a queued job a cron inside
the container releases, and a sleeping machine runs no containers, so the time passed with
nobody to notice. Docker Desktop failing to start after a reboot looks identical. Run
`docker compose ps` before concluding anything, and treat this install as somewhere to draft
and stage, not something that publishes while you are away from the desk.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not connect a social account, and do not create developer apps for the user. Mixpost
  Lite publishes to Facebook Pages, X and Mastodon, and the callback here is a localhost
  address the first two refuse.
- Do not change the account's email address, and do not add a second user. Step 7 says why.
- Do not set `MIXPOST_DISK` to s3 or add any `AWS_` variable. The media library is a folder
  in the user's home directory and step 8 backs it up.
