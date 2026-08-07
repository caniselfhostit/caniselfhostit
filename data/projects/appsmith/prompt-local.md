You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Appsmith v2.2 under ~/selfhost/appsmith, answering at http://localhost:8143.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Appsmith builds internal tools for other people to use, and here the only address those tools
have is http://localhost:8143, which means "this computer" wherever it is read. The user gets
the builder and the apps; the colleague they meant to hand a form to gets a connection error.

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
distribution ID and codename print next, for step 2. Appsmith needs 8192 MB of RAM available
and 20 GB free on the home disk; the image publishes amd64 and arm64. That floor is real: one
container runs the application, MongoDB, Redis and PostgreSQL together, and upstream's baseline
is 2 vCPU and 8 GB. On macOS and Windows the number printed is the host's, and Docker Desktop's
virtual machine takes its allocation out of that, so a 16 GB laptop capped at 4 GB will not run
this. If available RAM is under 8192 MB or free disk is under 20 GB, print both and stop.

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
mkdir -p ~/selfhost/appsmith/backups
ls -la ~/selfhost/appsmith
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder on purpose: step
5 keeps the instance's directory in a named Docker volume, because the embedded PostgreSQL
chowns its data directory to a uid Windows file sharing will not grant on a bind mount.

## 4. Secrets

Two secrets: the encryption password and the encryption salt. They encrypt every database
password, API key and token the user later hands to a datasource. Generate both here, print
neither, and keep both out of your summary and out of any log.

This file also carries the address that will own the instance. STOP: ask the user which email
address they want to sign in with, and wait. Do not continue until they answer. Take it in
lowercase. It is the one address that can create an account here, because the same file closes
signup for everyone else, and step 7 types it into a form character for character.

Write the file below with that address in place of `you@example.com`:

```bash
umask 077
cat > ~/selfhost/appsmith/.env <<EOF
APPSMITH_ADMIN_EMAILS=you@example.com
APPSMITH_SIGNUP_DISABLED=true
APPSMITH_BASE_URL=http://localhost:8143
APPSMITH_ENCRYPTION_PASSWORD=$(openssl rand -hex 32)
APPSMITH_ENCRYPTION_SALT=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/appsmith/.env
umask 022
ls -l ~/selfhost/appsmith/.env
```

Assert: the file exists with mode `-rw-------`, and the first line carries the address the user
gave rather than the example one. Git Bash ships openssl, so these lines run the same on all
three systems. Upstream generates a weaker pair inside the container when none arrive from
outside, and outside values win. Tell the user to read these once with
`grep ENCRYPTION ~/selfhost/appsmith/.env` and put them in their password manager: a
volume restored without them comes back with every app intact and every datasource unable to
decrypt its own credentials.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/appsmith/compose.yml <<'EOF'
# Appsmith · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.appsmith.com/getting-started/setup/installation-guides/docker
#   variable reference . https://docs.appsmith.com/getting-started/setup/environment-variables
#   capacity planning .. https://docs.appsmith.com/getting-started/setup/infrastructure-sizing
#
# One heavy service: upstream's all-in-one image runs MongoDB, Redis and
# PostgreSQL inside this container under supervisord, which is where the 8 GB
# floor comes from. /appsmith-stacks is a named volume, not a relative bind
# mount, because the embedded PostgreSQL chowns its data directory to its own
# uid and Windows file sharing cannot grant that on a home folder. ./backups
# stays a real folder. Digest read on 2026-08-06; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  appsmith:
    image: appsmith/appsmith-ce:v2.2@sha256:dc17b968c88eebf42b85c2e22b97efb55f2339b2d685e48f804c5f87bdd9d4e5
    container_name: appsmith
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Upstream ships anonymous usage collection turned on. This turns it off.
      APPSMITH_DISABLE_TELEMETRY: "true"
      # The docker.env the container writes for itself lets any site load
      # these apps in an iframe. This narrows it back to this address only.
      APPSMITH_ALLOWED_FRAME_ANCESTORS: "'self'"
    volumes:
      - appsmith-stacks:/appsmith-stacks
      - ./backups:/backup
    ports:
      # Loopback only: no other device on the wifi can reach 8143.
      - "127.0.0.1:8143:80"

volumes:
  appsmith-stacks:
EOF
cd ~/selfhost/appsmith && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS, because there is no hostname to resolve.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the editor's crypto still works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8143 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop
on the same wifi, nor anyone on the internet. For a tool whose apps are meant to be handed to
other people, that is the shape of the trade. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/appsmith/compose.yml
```

Assert: that prints `1`. The three databases inside the container are never published at all.

## 7. Start and verify

The first boot is slow. The pull is about 1.5 GB, then three database engines initialise and
the server migrates before it answers anything. Upstream says up to five minutes; on a laptop
sharing its cores with everything else, longer.

```bash
cd ~/selfhost/appsmith
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8143/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8143/api/v1/health
curl -sS http://localhost:8143/api/v1/tenants/current | grep -o '"isSignupDisabled":[a-z]*'
curl -sS http://localhost:8143/ | grep -c 'Appsmith is starting.'
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The
health response contains `"data":"All systems are up"`, the string the server returns once both
MongoDB and Redis answer it. The third prints `"isSignupDisabled":true`, the security assert
here: signup is shut before any account exists. The fourth prints `0`, meaning the holding page
the container serves while it boots is gone. If any of the four misses, stop, run
`docker compose logs --tail 60 appsmith`, and name the likely cause: a container restarting in
a loop is usually Docker Desktop's memory cap, and `port is already allocated` means something
else holds 8143 (`lsof -nP -iTCP:8143 -sTCP:LISTEN`, or `netstat -ano | findstr :8143` on
Windows). A running container is not success.

If `"isSignupDisabled"` came back `false`, do not create an account: that value is written into
the database on the first boot only. Reset instead, while there is nothing to lose:
`docker compose down -v`, check step 4's `.env` still says `APPSMITH_SIGNUP_DISABLED=true`, then
`docker compose up -d`, and run this block again.

The first screen is the welcome form, headed `Almost there` over `Let's setup your account
first`, with fields for a first name, last name, `Email` and a password typed twice.

STOP: tell the user to open http://localhost:8143, fill that form in using exactly the address
they gave in step 4, and wait. Do not continue until they confirm. Any other address gets an
error beginning `Signup is restricted on this instance of Appsmith`. Tell them to put the
password in their password manager as they type it: there is no mail here, so no reset link.

## 8. First backup and restore

One archive, taken with the container stopped, because a tar of a live MongoDB is not a backup.
The tar runs inside a throwaway container so the uids the embedded PostgreSQL owns its files as
survive into the archive:

```bash
cd ~/selfhost/appsmith
docker compose stop
docker run --rm --volumes-from appsmith --entrypoint sh appsmith/appsmith-ce:v2.2@sha256:dc17b968c88eebf42b85c2e22b97efb55f2339b2d685e48f804c5f87bdd9d4e5 -c "tar -czf /backup/appsmith-$(date +%F).tar.gz -C / appsmith-stacks"
docker compose start
ls -lh ~/selfhost/appsmith/backups/
```

Assert: the archive exists and is non-empty. Print its size. The stop and start cost a few
minutes, while the container brings all three engines back up.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder their sync service
watches or a USB stick, and copy it there with `cp`, together with `~/selfhost/appsmith/.env`,
which holds the keys that decrypt its datasource credentials. In Git Bash a Windows drive is written
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are listed there. If
they have neither, say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/appsmith`, put `.env` and `compose.yml` back if they
are missing, then `docker compose down -v`, which drops the old volume on purpose, then
`docker compose create`, which makes an empty one. Then the same `docker run` line as above,
with `tar -xzf` and the archive's filename in place of `tar -czf` and the date, extracting with
`-C /`. Then `docker compose up -d` and re-run step 7's check. That is the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/appsmithorg/appsmith/releases. Take step 8's
backup first, then edit the image line in ~/selfhost/appsmith/compose.yml:

```bash
cd ~/selfhost/appsmith
docker compose pull
docker compose up -d
docker compose logs --tail 40 appsmith
```

Appsmith migrates its own databases on the way up. Watch that log until it settles, then re-run
step 7's check before calling the update done.

## 10. What will probably go wrong

Docker Desktop's memory cap. I gave this a laptop with 16 GB in it and watched the container
restart in a loop for twenty minutes, reading the log for a mistake that was not there. Docker
Desktop was handing its virtual machine 4 GB, and three database engines and a JVM do not fit
in 4 GB. The number step 1 printed was the laptop's, not Docker's. Open Docker Desktop,
Settings, Resources, give it at least 8 GB, apply and restart, then run step 7 again.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8143 to 0.0.0.0 so a colleague on the wifi can open an app. That publishes an
  internal-tools builder, and its saved database credentials, onto every network this computer
  joins.
- Do not configure SMTP, and do not set `APPSMITH_CUSTOM_DOMAIN`. A custom domain makes the
  container ask Let's Encrypt for a certificate no public name backs.
