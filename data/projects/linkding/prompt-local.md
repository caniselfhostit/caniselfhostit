You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install linkding 1.45.0 under ~/selfhost/linkding, answering at http://localhost:8118.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install.
linkding answers at http://localhost:8118, which means this computer and nothing else: not the
phone they read on, not a second laptop, and the browser extension works only in a browser
running here. What they get is a private, fast, tag-first index of their own links, on one
machine.

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
distribution ID and codename print next, for step 2. linkding needs 512 MB of RAM available and
5 GB free on the home disk, and the image publishes amd64, arm64 and armv7. Every branch prints
free memory, so one floor covers all three; on macOS and Windows it is the host's, out of which
Docker Desktop's virtual machine takes its allocation. If available RAM is under 512 MB or free
disk is under 5 GB, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/linkding/backups
ls -la ~/selfhost/linkding
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder on purpose: the
image chowns its own data directory to the `www-data` uid on every start, so step 5 keeps the
database in a volume Docker manages. `backups` is a real folder because those are the files the
user has to see and copy.

## 4. Secrets

One secret: the password for the only account this install will have. Generate it here, print
it nowhere, and keep it out of your summary and any log.

```bash
umask 077
cat > ~/selfhost/linkding/.env <<EOF
LD_SUPERUSER_NAME=admin
LD_SUPERUSER_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/linkding/.env
umask 022
ls -l ~/selfhost/linkding/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. Hex rather than base64: Compose reads this same file for
interpolation and would expand a `$` in a value, and the user pastes this password into a
login form.

Upstream documents these two options as an initial superuser created once during container
start-up, and one created with no password cannot use the login form. Tell the user their
password is in ~/selfhost/linkding/.env, that they read it with `grep LD_SUPERUSER_PASSWORD
~/selfhost/linkding/.env`, and that it belongs in their password manager before step 7.
linkding has no sign-up page and no password-reset mail, so those are the only two places it
exists.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/linkding/compose.yml <<'EOF'
# linkding · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ....... https://linkding.link/installation/
#   options reference .... https://linkding.link/options/
#   backups .............. https://linkding.link/backups/
#   archiving ............ https://linkding.link/archiving/
#
# One service on the computer you are sitting at, with paths relative to
# ~/selfhost/linkding/ so one file works on macOS, Linux and Windows. The data
# folder is a named volume rather than a bind mount because the image chowns
# /etc/linkding/data to the www-data uid on every start, and a home-directory
# folder would come back owned by a uid the reader is not; backups stay a
# relative bind so the archives show up in Finder or Explorer. This is the
# plain image, not the -plus variant, which adds Chromium for HTML snapshots
# and wants at least 1 GB of RAM. Digest read from Docker Hub on 2026-08-06;
# the image publishes amd64, arm64 and armv7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  linkding:
    image: sissbruecker/linkding:1.45.0@sha256:61b2eb9eed8e5772a473fb7f1f8923e046cb8cbbeb50e88150afd5ff287d4060
    container_name: linkding
    restart: unless-stopped
    # LD_SUPERUSER_NAME and LD_SUPERUSER_PASSWORD, mode 600, never printed.
    env_file: ./.env
    environment:
      # SQLite is upstream's default and the choice here. Nothing to operate.
      LD_DB_ENGINE: sqlite
      # Left on (the default). The worker files Wayback Machine snapshots
      # only for an account whose owner turned that on.
      LD_DISABLE_BACKGROUND_TASKS: "False"
    volumes:
      # db.sqlite3, plus the assets, favicons and previews folders.
      - linkding-data:/etc/linkding/data
      # Where the backup step writes its zip.
      - ./backups:/backups
    ports:
      # Loopback only: no other device on the wifi can reach 8118.
      - "127.0.0.1:8118:9090"

volumes:
  linkding-data:
EOF
cd ~/selfhost/linkding && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is
no hostname, so nothing to resolve and nothing to wait for. A certificate attests a public name
and nothing here has one; browsers treat http://localhost as a secure context anyway, so pages
needing crypto work. Nothing is published beyond loopback, so no port needs closing.

8118 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/linkding/compose.yml
```

Assert: one line, `- "127.0.0.1:8118:9090"`. It is also why step 4 needs no
`LD_CSRF_TRUSTED_ORIGINS` line: the browser's address and linkding's are the same one.

## 7. Start and verify

The container generates its secret key, migrates the database, turns on WAL mode and creates
the account named in `LD_SUPERUSER_NAME`, all on the way up.

```bash
cd ~/selfhost/linkding
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8118/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://localhost:8118/health; echo
curl -sS http://localhost:8118/login/ | grep -o 'id="main-heading">Login'
docker compose exec -T linkding python manage.py shell -c "from django.contrib.auth import get_user_model; print(get_user_model().objects.count())"
```

Assert all four, and print what you received for each: the loop ends on `200`; the health
response reads `{"version": "1.45.0", "status": "healthy"}`, where `status` is the assert and
the version confirms which image is running; the grep prints `id="main-heading">Login`, the
heading on the first screen; the last command prints `1`, the account step 4 created. If any
of the four misses, stop, run `docker compose logs --tail 40 linkding`, and name the likely
cause: a count of `0` means the `.env` was written after the container first started, so
`docker compose down` then `up -d`. If `port is already allocated` came back, find what holds
8118 with `lsof -nP -iTCP:8118 -sTCP:LISTEN` (`netstat -ano | findstr :8118` on Windows) and
stop until the user frees it. A running container is not success.

STOP: tell the user to read their password with `grep LD_SUPERUSER_PASSWORD
~/selfhost/linkding/.env`, put it in their password manager, open http://localhost:8118, log
in as `admin`, save one bookmark, and wait. Do not continue until they confirm. That address
redirects to /login/ and shows the heading `Login` over `Username` and `Password` boxes and a
`Login` button, with the tab reading `Login - Linkding`. There is no register link and no
route behind one, so the count of `1` above is the whole access-control surface.

```bash
docker compose exec -T linkding python manage.py shell -c "from bookmarks.models import Bookmark; print(Bookmark.objects.count())"
```

Assert: a number greater than 0. Print it. That is a link that went through the browser, the
login form and into the database: the whole product working end to end.

## 8. First backup and restore

Two artifacts. The zip holds the bookmarks: `db.sqlite3` plus the `assets`, `favicons` and
`previews` folders. The config archive holds the two files that rebuild the service around it.

```bash
cd ~/selfhost/linkding
docker compose exec -T linkding python manage.py full_backup /backups/linkding-$(date +%F).zip
tar -C ~/selfhost/linkding -czf ~/selfhost/linkding/backups/linkding-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/linkding/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`full_backup` is upstream's own command and copies the database through SQLite's backup API,
which upstream asks for because a plain `cp` of `db.sqlite3` is not transaction safe. On Linux
the container writes that zip as root: the user can copy it, and needs `sudo` to delete it.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the
disk and the machine fail together. Ask the user for a destination that leaves this computer,
a folder their sync service watches or a USB stick, and copy both there with `cp`. In Git Bash
a Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms both
filenames are listed there. If they have neither, say plainly that this install has no backup.

To restore: `cd ~/selfhost/linkding`, untar the config archive there first if compose.yml or
.env were lost, then `docker compose down -v`, the one place `-v` belongs because it drops the
old database volume on purpose. Unpack the zip into the fresh volume with a one-off container
that has the same mounts and no port, `docker compose run --rm linkding python -m zipfile -e
/backups/linkding-$(date +%F).zip /etc/linkding/data` with the date of the archive being
restored, then `docker compose up -d`. The zip has no `secretkey.txt`, which the container
writes again on start: every session is signed out and the same password signs back in. Those
four commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/sissbruecker/linkding/releases. Take both backups
first, then edit the image line in ~/selfhost/linkding/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/linkding
docker compose pull
docker compose up -d
docker compose logs --tail 30 linkding
```

linkding migrates its own database on the way up. Watch that log until it settles, then re-run
step 7's health check.

## 10. What will probably go wrong

I rebooted this machine, opened the bookmark I had made for my own bookmarks, and got a
connection refused that read like a lost database. It was not: Docker Desktop had not started
with the session, so nothing was listening on 8118. `restart: unless-stopped` acts only once
the Docker daemon is up. Turn on Docker Desktop's start-at-login setting, then after a reboot
run `cd ~/selfhost/linkding && docker compose up -d` before concluding anything is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8118 to 0.0.0.0 so a phone on the same wifi can reach it. That puts everything
  the user reads behind one form on every network they join.
- Do not switch to the `-plus` image, and do not set `LD_DB_ENGINE` to `postgres`. The first
  bundles a Chromium that upstream wants 1 GB of RAM for; the second is another container and a
  database step 8's backup command cannot snapshot.
