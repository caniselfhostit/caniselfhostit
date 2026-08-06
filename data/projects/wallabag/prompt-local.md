You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install wallabag 2.6.14 under ~/selfhost/wallabag, answering at http://localhost:8109.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
wallabag will answer only at http://localhost:8109, which means this computer wherever it is
read. The phone app, an e-reader and the browser extension on any other machine cannot reach
it. They get a reading list for the browser in front of them: a real thing, and smaller than
the service they are replacing.

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
distribution ID and codename print next, for step 2. wallabag needs 1024 MB of RAM available
and 5 GB free on the home disk, and the image publishes amd64, arm64 and armv7. Every branch
prints free memory, so one floor covers all three; on macOS and Windows it is the host's, out
of which Docker Desktop takes its allocation. If RAM is under 1024 MB or free disk is under
5 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/wallabag/data ~/selfhost/wallabag/images ~/selfhost/wallabag/backups
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 65534:65534 ~/selfhost/wallabag/data ~/selfhost/wallabag/images
fi
ls -la ~/selfhost/wallabag
```

Assert: `ls -la` shows `data`, `images` and `backups`. The image runs php-fpm as `nobody`,
uid 65534, so on Linux the two directories it writes into go to that uid; the fence is a no-op
on macOS and Windows, where Docker Desktop grants that already. Articles land in
`data/db/wallabag.sqlite`, visible in Finder or Explorer.

## 4. Secrets

Two secrets, both generated here: the Symfony application secret and the password replacing
the image's. Print neither, and keep both out of your summary and any log.

```bash
umask 077
cat > ~/selfhost/wallabag/.env <<EOF
SYMFONY__ENV__SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 ~/selfhost/wallabag/.env
umask 022
ls -l ~/selfhost/wallabag/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. The application secret matters because the image ships a default
value for it in its parameter template, so every wallabag that never set one signs its
remember-me cookies with a string published on GitHub. On Windows those mode bits are advisory:
NTFS does not enforce them; the real boundary is the user's Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/wallabag/compose.yml <<'EOF'
# wallabag · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image README ....... https://github.com/wallabag/docker/blob/master/README.md
#   entrypoint ......... https://github.com/wallabag/docker/blob/master/root/entrypoint.sh
#
# One service, every path relative to ~/selfhost/wallabag/, so one file works on
# macOS, Linux and Windows. Both mounts are bind mounts rather than named
# volumes, keeping the SQLite file and the saved images visible in Finder or
# Explorer. Digest read 2026-08-06; amd64, arm64 and armv7 are published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  wallabag:
    image: wallabag/wallabag:2.6.14@sha256:4a527e027e0d59e87c14225ef11e005af3d4890374202ad319ce5e63dfc66709
    container_name: wallabag
    restart: unless-stopped
    env_file: ./.env
    environment:
      # SQLite is the image default and the whole database: one file under
      # data/db, no second container and no dump to schedule.
      SYMFONY__ENV__DATABASE_DRIVER: pdo_sqlite
      # Public sign-up stays off, written here so a reviewer sees the posture.
      SYMFONY__ENV__FOSUSER_REGISTRATION: "false"
      # The issuer name an authenticator app shows for two-factor.
      SYMFONY__ENV__SERVER_NAME: wallabag
      # Nothing terminates TLS here, so the links wallabag builds say http.
      SYMFONY__ENV__DOMAIN_NAME: http://localhost:8109
      # Upstream's default is 128M, which is where long pages start failing.
      PHP_MEMORY_LIMIT: 256M
    volumes:
      - ./data:/var/www/wallabag/data
      - ./images:/var/www/wallabag/web/assets/images
    ports:
      # Loopback only: no other device on the wifi can reach 8109.
      - "127.0.0.1:8109:80"
    # The image already carries a HEALTHCHECK polling /api/info.
EOF
cd ~/selfhost/wallabag && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, two bind mounts.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait on.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto work.
- No firewall rule. Nothing is published beyond loopback, so nothing needs closing.

8109 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/wallabag/compose.yml
```

Assert: one line, `- "127.0.0.1:8109:80"`.

## 7. Start and verify

Read this first. The image creates its first account on first boot, a super admin whose
username and password are both the word wallabag, documented in its README. Nothing outside
this computer can reach it, but the change below is what makes the install the user's. Run the
block in one go.

```bash
cd ~/selfhost/wallabag
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8109/api/info); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
docker compose exec -T wallabag su -c '/var/www/wallabag/bin/console fos:user:change-password wallabag "$ADMIN_PASSWORD" --env=prod' -s /bin/sh nobody
curl -sS http://localhost:8109/api/info
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8109/register
curl -sS http://localhost:8109/login | grep -c 'Log in'
```

Assert, all five, and print what you received. The loop ends on `200`, after a column of `000`
while the first boot rebuilds the Symfony cache. The console prints
`Changed password for user wallabag`. `/api/info` contains `"version":"2.6.14"` and
`"allowed_registration":false`. `/register` prints `301`, a sign-up attempt sent back to the
login page because public registration is off. The last prints at least `1`.

Now prove the shipped credential is dead:

```bash
shipped=wallabag
jar=$(mktemp)
tok=$(curl -sS -c "$jar" http://localhost:8109/login | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)
echo "csrf token length ${#tok}"
curl -sS -b "$jar" -c "$jar" -L -d "_username=$shipped" -d "_password=$shipped" -d "_csrf_token=$tok" http://localhost:8109/login_check | grep -c 'unread/list' || true
rm -f "$jar"
```

Assert: the token length is not `0` and the last line prints `0`. A successful login lands on
the unread list, whose HTML carries `unread/list`, and a rejected one goes back to the login
form; a zero-length token would mean the login failed for a missing token rather than a wrong
password, and would prove nothing. Anything above zero means the password change did not take:
stop and run `docker compose logs --tail 40 wallabag`.
If `port is already allocated` came back earlier, find what holds 8109
(`lsof -nP -iTCP:8109 -sTCP:LISTEN`, or `netstat -ano | findstr :8109` on Windows) and stop
until it is freed. A running container is not success.

The first screen at http://localhost:8109/login is a card with the wallabag logo, `Username`
and `Password` fields, and a button reading `Log in`. The browser tab reads
`Welcome to wallabag!`.

STOP: tell the user to read their password with
`grep ADMIN_PASSWORD ~/selfhost/wallabag/.env`, put it in their password manager, log in at
http://localhost:8109/login as the user `wallabag`, and wait. Do not continue until they
confirm they see an empty article list. There is no password-reset mail here, so that entry is
the only copy.

## 8. First backup and restore

One archive: the SQLite database holding every saved article, the images directory, and the
two files that rebuild the service around it.

```bash
cd ~/selfhost/wallabag
docker compose stop
tar -czf ~/selfhost/wallabag/backups/wallabag-$(date +%F).tar.gz -C ~/selfhost/wallabag data images compose.yml .env
docker compose start
ls -lh ~/selfhost/wallabag/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped for the
copy on purpose: a SQLite file copied mid-write is not a database. Starting it again re-runs
the entrypoint, so wallabag takes a minute or two to answer. That is expected.

The archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is written
`/d/Backups`, not `D:\Backups`. Assert: the user confirms the filename is listed there. If
there is nowhere to put it, say plainly that this install has no backup.

To restore: `cd ~/selfhost/wallabag`, `docker compose down`, `rm -rf data images`, untar the
archive back into ~/selfhost/wallabag, re-run step 3's Linux chown fence, then
`docker compose up -d` and wait for /api/info to answer 200. Those five commands are the whole
disaster plan.

## 9. Updating later

New versions are listed at https://github.com/wallabag/wallabag/releases. Back up first, then
put the new tag and digest on the image line in compose.yml:

```bash
cd ~/selfhost/wallabag
docker compose pull
docker compose up -d
for i in $(seq 1 60); do curl -sf -o /dev/null http://localhost:8109/api/info && break; sleep 5; done
docker compose exec -T wallabag su -c '/var/www/wallabag/bin/console doctrine:migrations:migrate --env=prod --no-interaction' -s /bin/sh nobody
docker compose logs --tail 30 wallabag
```

The loop is there because the container cannot run a console command until it answers. The
migration line is upstream's documented way to move an existing database to a new release, and
is safe when there is nothing to migrate. Confirm the version moved before calling it done.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8109, and got a connection refused that read like a lost
install. Two problems were stacked on each other. Docker Desktop had not started with the
session, and `restart: unless-stopped` only acts once the Docker daemon is up. Then, once it
was running, the entrypoint deleted the Symfony cache and re-ran its dependency install, which
it does on every start, so the page kept timing out for two more minutes after the container
said `Up`. Turn on Docker Desktop's start-at-login setting, then after a reboot run
`cd ~/selfhost/wallabag && docker compose up -d` and give it three minutes.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `SYMFONY__ENV__DOMAIN_NAME` to this machine's LAN address and do not rebind
  8109 to 0.0.0.0 so a phone can reach it. That puts a login form on every network the user
  joins, with no certificate in front.
- Do not change `SYMFONY__ENV__DATABASE_DRIVER` to pdo_mysql or pdo_pgsql. SQLite is the
  choice here and it is what makes the backup in step 8 one file.
