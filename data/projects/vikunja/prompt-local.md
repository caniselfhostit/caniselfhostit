You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Vikunja 2.5.0 under ~/selfhost/vikunja, answering at http://localhost:8097.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Vikunja will answer on http://localhost:8097, which means this computer and no other. Their
phone cannot reach it, nor a tablet on the same wifi, nor a CalDAV client anywhere else. What
they get is a to-do list that is theirs, on one desk, awake only while this computer is.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
id -u
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2, and the last line prints the user's numeric
id, which step 3 needs. Vikunja needs 512 MB of RAM available and 5 GB free on the home disk, and
the image publishes amd64 and arm64. Every branch prints free memory, so one floor covers all
three; on macOS and Windows that is the host's, and Docker Desktop's virtual machine takes its
allocation out of it. If available RAM is under 512 MB or free disk is under 5 GB, print both
numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/vikunja/db ~/selfhost/vikunja/files ~/selfhost/vikunja/backups
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "1000" ]; then
  sudo chown 1000 ~/selfhost/vikunja/db ~/selfhost/vikunja/files
fi
ls -la ~/selfhost/vikunja
```

Assert: `ls -la` shows `db`, `files` and `backups`. The container runs as uid 1000, so on Linux
the first two have to belong to that uid and the guarded line above fixes it when the user's own
id is something else. On macOS and Windows, Docker Desktop's file sharing grants the container
access whatever the number on disk says, so that line does nothing there.

## 4. Secrets

One secret: the signing key Vikunja uses for session tokens. Generate it here, do not print it,
and keep it out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/vikunja/.env <<EOF
VIKUNJA_SERVICE_PUBLICURL=http://localhost:8097
VIKUNJA_SERVICE_TIMEZONE=UTC
VIKUNJA_SERVICE_ENABLEREGISTRATION=true
VIKUNJA_SERVICE_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/vikunja/.env
umask 022
ls -l ~/selfhost/vikunja/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same on
all three systems. Upstream documents that without this value a fresh random one is generated at
every start, which signs out every logged-in session on every restart. Tell the user they can read
it back with `grep VIKUNJA_SERVICE_SECRET ~/selfhost/vikunja/.env`, rather than telling them the
value. Registration is open only until step 7 closes it.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is the
user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/vikunja/compose.yml <<'EOF'
# Vikunja · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   installing ......... https://vikunja.io/docs/installing/
#   docker examples .... https://vikunja.io/docs/full-docker-example/
#   config reference ... https://vikunja.io/docs/config-options/
#   what to backup ..... https://vikunja.io/docs/what-to-backup/
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/vikunja/, which lets one file work on macOS, Linux and Windows.
# There is no named volume here: nothing in this stack chowns its own data
# directory, so both mounts stay ordinary bind mounts and your tasks and your
# attachments stay visible in Finder or Explorer.
#
# The image is built FROM scratch and runs as uid 1000 with no group. There is
# no shell in it, which is why this file declares no healthcheck. On Linux that
# uid also has to own ./db and ./files; on macOS and Windows, Docker Desktop's
# file sharing handles it. Step 3 of the prompt covers both.
#
# Tag and digest were read from Docker Hub on 2026-08-05; the manifest list
# publishes linux/amd64 and linux/arm64. Same pin as the server file.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  vikunja:
    image: vikunja/vikunja:2.5.0@sha256:22df4c1bc8843c28d383bc5f52b59e7b601bf5f6560b36b29c0a500833c77fa3
    container_name: vikunja
    restart: unless-stopped
    env_file: ./.env
    environment:
      # SQLite, written out even though it is the image default, because this
      # file is what you read to find out where the data actually is.
      VIKUNJA_DATABASE_TYPE: sqlite
      VIKUNJA_DATABASE_PATH: /db/vikunja.db
      VIKUNJA_FILES_BASEPATH: /app/vikunja/files
      # No outbound mail. Upstream's reminder job only delivers over mail or a
      # webhook, so with this false a due date is something you see when you
      # open the app, not something that arrives. Block 10 says so out loud.
      VIKUNJA_MAILER_ENABLED: "false"
    volumes:
      - ./db:/db
      - ./files:/app/vikunja/files
    ports:
      # Loopback only: no other device on the wifi can reach 8097.
      - "127.0.0.1:8097:3456"
EOF
cd ~/selfhost/vikunja && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, two bind mounts.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8097 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop on
the same wifi, nor anyone on the internet. That is the shape of this path. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/vikunja/compose.yml
```

Assert: one line, `- "127.0.0.1:8097:3456"`. Nothing else publishes a port.

## 7. Start and verify

Vikunja creates its own SQLite schema on the first start. Nothing is seeded and there is no
default account waiting to be found.

```bash
cd ~/selfhost/vikunja
docker compose pull
docker compose up -d
for i in $(seq 1 20); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8097/api/v1/info); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8097/api/v1/info | grep -o '"registration_enabled":[a-z]*'
```

Assert both, and print what you received for each: the loop ends on `200`, and the second command
prints `"registration_enabled":true`. If either misses, stop, run
`docker compose logs --tail 40 vikunja`, and name the likely cause. A log line about opening the
database points at step 3, where the ownership fix belongs; one about the public URL points at
step 4. If `port is already allocated` came back, find what holds 8097
(`lsof -nP -iTCP:8097 -sTCP:LISTEN`, `ss -ltnp | grep 8097` on Linux,
`netstat -ano | findstr :8097` on Windows) and stop until the user frees it.
A running container is not success.

The first screen at http://localhost:8097 is a login form with the heading `Login`, a field
labelled `Username Or Email Address`, and beneath the button the line `Don't have an account yet?`
next to a `Create account` link.

STOP: tell the user to open http://localhost:8097, follow `Create account`, register the one
account they want, and wait. Do not continue until they confirm.

Once they confirm, close registration and restart:

```bash
sed -i.bak 's/^VIKUNJA_SERVICE_ENABLEREGISTRATION=true$/VIKUNJA_SERVICE_ENABLEREGISTRATION=false/' ~/selfhost/vikunja/.env
rm -f ~/selfhost/vikunja/.env.bak
docker compose up -d --force-recreate
sleep 15
curl -sS http://localhost:8097/api/v1/info | grep -o '"registration_enabled":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' http://localhost:8097/api/v1/register
```

Assert both: the first prints `"registration_enabled":false`, and the second prints `404`, which
is what upstream's register handler returns once registration is off. Then have the user reload
the page and confirm the `Create account` link is gone. `sed -i.bak` is spelled that way because
the BSD sed on macOS rejects a bare `-i`.

## 8. First backup and restore

Take the backup now, before the user moves a single task in. The image has no shell, so nothing
here runs inside the container: the archive is made from the directories on disk. Stop the
container first, because copying a SQLite file mid-write is not a backup.

```bash
cd ~/selfhost/vikunja
docker compose stop
tar -C ~/selfhost/vikunja -czf ~/selfhost/vikunja/backups/vikunja-$(date +%F).tar.gz db files .env compose.yml
docker compose start
ls -lh ~/selfhost/vikunja/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms the filename is listed
there. If they have nowhere to put it, say that this install has no backup.

To restore: `docker compose down`, delete `db` and `files`, untar the archive back into
~/selfhost/vikunja, re-run step 3 so the ownership is right again, then `docker compose up -d` and
check step 7's info endpoint. Every task, project, comment and label is in `db/vikunja.db`, every
attachment is a file under `files/`, and the signing key is in `.env`. Those five commands are the
whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/go-vikunja/vikunja/releases. Take a backup first,
then edit the image line in ~/selfhost/vikunja/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/vikunja
docker compose pull
docker compose up -d
docker compose logs --tail 30 vikunja
```

Vikunja migrates its own database on the way up. Watch that log until it settles, then re-run
step 7's info check before the update counts as done.

## 10. What will probably go wrong

On my Linux machine the container exited in under a second and left nothing behind. `docker
compose ps` showed no running service, so I reached for `docker compose exec vikunja sh` to look
inside and got `executable file not found`. That is not a second fault: this image is built from
nothing at all and holds one binary, no shell and no tools, so `docker compose logs` is the only
window there is. The log said it could not open the database file, and the cause was step 3: my
account is uid 1001 on that machine and the container writes as uid 1000. Run the guarded `chown`
line again, then `docker compose up -d`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP. Without it Vikunja delivers no reminders at all, which is worth saying
  out loud, and fixing it needs a mail provider and DNS records this path does not have.
- Do not enable the Todoist migration. It needs a developer app registered in the user's Todoist
  account, and upstream states the Vikunja install has to be publicly reachable for it, which
  this one is not.
- Do not switch the database to PostgreSQL. SQLite is the choice here and the image expects it.
