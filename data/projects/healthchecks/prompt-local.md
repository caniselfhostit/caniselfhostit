You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Healthchecks v4.3 on this computer, reachable at http://localhost:8088, with everything
it owns under ~/selfhost/healthchecks/.

## 1. Preflight

Say this to the user before anything is installed, without softening it: nothing outside this
computer can reach a localhost ping URL, so this instance can only watch cron jobs that run on
this same machine, and the jobs on their servers will have to report somewhere else.

Healthchecks signs people in by emailing a link, so an SMTP relay is a precondition. Ask once,
then stop asking: the address the account will use, a relay hostname they have, its port, and
their username on it. Not the credential; a STOP in step 4 has them type that. No relay, no
install.

Now measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize | awk '{print $1/1048576 " MB of RAM installed"}' ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" | awk '{print $1/1048576 " MB of RAM installed"}' ;;
esac
df -h ~
```

`uname -s` prints `Darwin`, `Linux`, or `MINGW`/`MSYS` in Git Bash on Windows; every branch
below turns on that answer, and step 3 adds a Windows rule. The RAM lines print MB: on Linux
what is free now, on macOS and Windows what is installed.

Healthchecks needs 1024 MB of RAM and 5 GB free on the home disk, on amd64 or arm64. Stop if
Linux shows under 1024 MB available, if macOS or Windows shows under 2048 MB installed, or if
`Avail` is under 5 GB. Do not install and hope.

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
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they confirm.
  Either way, then STOP: tell the user to open Docker Desktop once, accept its terms, and wait
  for the whale icon to say it is running. Do not continue until they confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and install
  it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may ask for a
  reboot; if it does, STOP and tell the user to reboot and come back, this prompt resumes at
  this step. Then STOP: have the user open Docker Desktop, accept its terms, and confirm it
  says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt repository,
  saving the signing key to a file first, never piping it into a shell:

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

  Adding the user to the docker group is root-equivalent on this machine; say that to the user
  in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose plugin
  with their distribution's package manager, and to run this prompt again once `docker info`
  works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not continue
without both.

## 3. Layout

STOP on Windows, before anything is created. SQLite write locks are not honoured across a
Windows drive Docker Desktop shares in, and uWSGI writes this file from several processes, so a
`/mnt/c` path corrupts it silently. Windows runs this inside WSL 2 instead: tell the user to run
`wsl --install -d Ubuntu` in PowerShell, choose the UNIX username and password its first launch
asks for, turn Ubuntu on under Docker Desktop, Settings, Resources, WSL integration, then open
Claude Code in that Ubuntu window and paste this prompt there. Nothing is created in Git Bash.

```bash
mkdir -p ~/selfhost/healthchecks/data ~/selfhost/healthchecks/backups
cd ~/selfhost/healthchecks
chmod 750 . data backups
ls -la
```

Assert: `ls -la` lists `data` and `backups` at `drwxr-x---`, and nothing is written outside that
folder; `backups` carries that mode because step 8's archive holds `.env`. Keep it on this
computer's own disk: no sync-service folder, no network drive.

On Linux the bind mount must belong to the uid the container writes as. The image hands /data
to a system account `hc`, so ask it:

```bash
cd ~/selfhost/healthchecks
if [ "$(uname -s)" = "Linux" ]; then
  HCUID=$(docker run --rm healthchecks/healthchecks:v4.3@sha256:cd7bcd94350818b3944f82eb5995f48bdeab8c8627977578a569ffa73f56f56f id -u hc)
  echo "hc uid: [$HCUID]"
  case "$HCUID" in
    ''|*[!0-9]*) echo "STOP: the image answered with no uid" ;;
    *) sudo chown -R "$HCUID:$(id -g)" data ;;
  esac
  ls -la
fi
```

Assert on Linux: `hc uid:` holds a number, `999` on this image, and `data` then belongs to it
with the user's own group. If `STOP:` printed, print what `docker run` said and stop: an empty
uid turns that chown into a group-only change that exits 0 and fixes nothing. macOS needs none
of it, Docker Desktop maps the mount to the uid the container asks for; Windows is on this
branch by now.

## 4. Secrets

One secret is generated here: the Django `SECRET_KEY`. Do not print it, repeat it in your
summary, or log it. Replace `you@example.com`, `smtp.example.net`, `587` and `relay-username`
with the four step 1 answers; `DEFAULT_FROM_EMAIL` and `EMAIL_HOST_USER` are not always one
string.

```bash
cd ~/selfhost/healthchecks
umask 077
cat > .env <<EOF
SECRET_KEY=$(openssl rand -base64 48)
SITE_ROOT=http://localhost:8088
SITE_NAME=Checks
ALLOWED_HOSTS=localhost,127.0.0.1
DB=sqlite
DB_NAME=/data/hc.sqlite
REGISTRATION_OPEN=True
DEFAULT_FROM_EMAIL=you@example.com
EMAIL_HOST=smtp.example.net
EMAIL_PORT=587
EMAIL_HOST_USER=relay-username
EMAIL_USE_TLS=True
EOF
chmod 600 .env
ls -l .env
```

Assert: mode `-rw-------`. `SITE_ROOT` is the base URL every absolute link is built from, so
every ping URL begins http://localhost:8088, the mechanism behind step 1's warning. Say this
once: copied onto a Windows drive, step 8's archive included, that mode means nothing; the
user's Windows account is the real boundary.

STOP: tell the user to open a second window of the shell they are in, Terminal on macOS or
Linux and a second Ubuntu window on Windows, and run the block below there, so the credential
never enters this session. Its last line waits with no prompt and echoes nothing: they type the
credential and press Return. It reads from that terminal, so nothing may be pasted after it.

```bash
cd ~/selfhost/healthchecks
umask 077
printf 'EMAIL_HOST_PASSWORD=' >> .env
read -rs && printf '%s\n' "$REPLY" >> .env && unset REPLY && chmod 600 .env
```

Then check it from this session:

```bash
awk -F= '/^EMAIL_HOST_PASSWORD/ {print "recorded, length " length($2)}' ~/selfhost/healthchecks/.env
```

Assert: a length greater than 0, and ask the user whether it matches their credential. Nothing
printed means the line is missing.

## 5. compose.yml

```bash
cat > ~/selfhost/healthchecks/compose.yml <<'EOF'
# Healthchecks · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image and runtime notes . https://github.com/healthchecks/healthchecks/blob/master/docker/README.md
#   configuration ........... https://healthchecks.io/docs/self_hosted_configuration/
#
# One container, no database process: the instance is one file at /data/hc.sqlite
# and uWSGI migrates on boot and keeps sendalerts alive, so there is no cron job.
# Tag and digest are the v4.3 release read from Docker Hub on 2026-08-05, amd64
# and arm64. Paths are relative to this file.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  healthchecks:
    image: healthchecks/healthchecks:v4.3@sha256:cd7bcd94350818b3944f82eb5995f48bdeab8c8627977578a569ffa73f56f56f
    container_name: healthchecks
    restart: unless-stopped
    env_file: ./.env
    volumes:
      # Owned by the hc uid on Linux, hence step 3. SQLite needs real POSIX locks,
      # so this is a bind mount on a local Linux, macOS or WSL 2 filesystem only.
      - ./data:/data
    ports:
      # Loopback only: nothing outside this computer can reach 8088.
      - "127.0.0.1:8088:8000"
EOF
cd ~/selfhost/healthchecks && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. The container serves on 8000 inside itself; 8088 is bound to 127.0.0.1.

## 6. Nothing is public

Port 8088 is bound to 127.0.0.1, so no other device reaches it, the user's own phone included:
the shape of this path, not a defect. No DNS record and no certificate, there being nothing to
certify, and browsers treat `http://localhost` as a secure context, so page code needing crypto
works without TLS. No firewall rule: nothing from another machine reaches loopback, and mail
only goes out, through step 4's relay.

## 7. Start and verify

uWSGI migrates as it boots, so the first start writes hc.sqlite and is the slow one.

```bash
cd ~/selfhost/healthchecks
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8088/api/v3/status/
curl -sS http://localhost:8088/accounts/login/ | grep -c 'Log In to Checks'
curl -sS http://localhost:8088/accounts/login/ | grep -c 'id="signup-modal"'
```

Assert: the first prints `200` and the other two a number greater than 0; print all three. That
first URL is the image's own health check: 200 only when the database connection is alive. A
running container is not success. If any misses, stop, pull
`docker compose logs --tail 40 healthchecks`, and name the earlier step: a 500 on Linux is
usually step 3's ownership block; `database is locked` means `data` sits where locks are not
real.

The first screen at http://localhost:8088 is a log-in form headed `Log In to Checks`, with an
`Email Me a Link` button and a `Sign Up` link in the corner.

STOP: tell the user to open http://localhost:8088 in a browser on this computer, click
`Sign Up`, and enter the address from step 1. They read that mail here, not on their phone: the
sign-in link comes from `SITE_ROOT`, so it opens on this machine only. `/accounts/signup/`
answers POST only. Wait until they confirm they are signed in; if no mail arrives, check step
4's relay values first.

Once confirmed, close registration:

```bash
cd ~/selfhost/healthchecks
sed -i.bak 's/^REGISTRATION_OPEN=True$/REGISTRATION_OPEN=False/' .env
rm -f .env.bak
chmod 600 .env
docker compose up -d --force-recreate
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8088/api/v3/status/
curl -sS http://localhost:8088/accounts/login/ | grep -c 'id="signup-modal"' || true
```

Assert: the first prints `200`, the second `0`; print both. That `0` is the security assert:
`signup-modal` is the id of the sign-up form itself, so it counts the form gone, not wording
near it, and `grep -c` exits 1 counting nothing, hence `|| true`. The `.bak` holds the same
secrets, so it goes. Both asserts pass before you report success.

## 8. First backup and restore

Take the backup now, before the user adds a check, container stopped: a SQLite file copied
mid-write is not a backup.

```bash
cd ~/selfhost/healthchecks
docker compose stop
tar -czf backups/healthchecks-$(date +%F).tar.gz data .env
docker compose start
ls -lh backups/
```

Assert: the archive exists and is non-empty; print its size, a few hundred kilobytes fresh.
`data` plus `.env` is the whole install, relay credential included. If tar reports a permission
error on Linux, re-run step 3's ownership block.

That archive shares a disk with the data it protects; the two fail together. Ask the user
once for a folder that leaves this machine and `cp` the archive there: a sync service's folder,
iCloud Drive or Dropbox, or a USB stick, /Volumes/NAME on macOS, /media/NAME on Linux, /mnt/d
in the Ubuntu window. `ls -lh` the copy and print it. Do not finish until it exists in two
places.

To restore, from inside ~/selfhost/healthchecks: `docker compose down`, then `sudo rm -rf data`
on Linux and in the Ubuntu window or `rm -rf data` on macOS, which never chowned, then
`tar -xzf backups/<the archive>`, then step 3's two blocks again on Linux, then
`docker compose up -d`. Without that sudo the delete and the unpack are both refused: step 3
gave `data` to the hc uid at mode 750, which the user can read, hence the plain tar above, and
cannot write. Ping URLs live in `data/hc.sqlite`, so the ones in crontabs keep working.

## 9. Updating later

New versions are listed at https://github.com/healthchecks/healthchecks/releases. Back up
first, then edit compose.yml's image line to the new tag and digest. uWSGI migrates on the next
boot, so read the log until it settles.

```bash
cd ~/selfhost/healthchecks
docker compose pull
docker compose up -d
docker compose logs --tail 20 healthchecks
```

## 10. What will probably go wrong

The machine will sleep, and a monitor cannot tell sleeping apart from broken. I closed a laptop
lid at eleven and opened it at eight to a column of DOWN alerts for a nightly job that was never
late: the computer was off, so the job had not run and the check went overdue for it. Tell the
user that, and to set every check's grace period wider than the longest stretch this computer
sleeps.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not switch the database to PostgreSQL. SQLite is why this is one folder to copy.
- Do not set `SMTPD_PORT` or open an inbound mail listener. This install only sends.
- Do not add a cron job for alerts. uWSGI keeps `sendalerts` running already.
