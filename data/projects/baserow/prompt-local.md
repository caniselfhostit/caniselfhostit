You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Baserow 2.3.3 under ~/selfhost/baserow, answering at http://localhost:8175.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Baserow is a database several people edit at once, and the only address this one has is
http://localhost:8175, which means "this computer" wherever it is read. The user gets the
grids, the forms, the formulas and the API. The colleague they meant to share a table with
gets a connection error, and so does their own phone.

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
distribution ID and codename print next, for step 2. Baserow needs 4096 MB of RAM available and
10 GB free on the home disk; the image publishes amd64 and arm64. That floor is real: one
container runs a PostgreSQL 15 and a Redis next to the Django backend, the Nuxt web frontend and
a Caddy of its own, and upstream asks for 2 vCPU and 4 GB per container even with the database
outside it. On macOS and Windows the number printed is the host's, and Docker Desktop takes its
allocation out of that. If available RAM is under 4096 MB or free disk is under 10 GB, print
both numbers and stop.

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
mkdir -p ~/selfhost/baserow/backups
ls -la ~/selfhost/baserow
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder on purpose. Step
5 keeps the instance's directory in a named Docker volume, because the PostgreSQL inside the
container chowns its cluster to uid 9999 and Windows file sharing will not grant that on a
home-directory bind mount. The archive step 8 writes lands in `backups`, a real folder the user
can open in Finder or Explorer.

## 4. Secrets

Two secrets: the Django secret key and the JWT signing key. The image generates a pair of its
own inside the data volume if none arrive from outside, and values set from outside win, so
generate them here where they land in a file the user keeps. Print neither, and keep both out of
your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/baserow/.env <<EOF
BASEROW_PUBLIC_URL=http://localhost:8175
SECRET_KEY=$(openssl rand -hex 32)
BASEROW_JWT_SIGNING_KEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/baserow/.env
umask 022
ls -l ~/selfhost/baserow/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. `BASEROW_PUBLIC_URL` carries the port because the browser address
does, and Baserow compares it against the address requests arrive on. Tell the user to read the
pair back once with `grep -E 'SECRET_KEY|SIGNING_KEY' ~/selfhost/baserow/.env` and keep both:
the first signs session cookies, the second signs every API token, and a restore without them
logs everybody out.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/baserow/compose.yml <<'EOF'
# Baserow · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://baserow.io/docs/installation%2Finstall-with-docker
#   variable reference . https://baserow.io/docs/installation%2Fconfiguration
#   capacity guidance .. https://baserow.io/docs/installation%2Finstall-on-aws
#   supported versions . https://baserow.io/docs/installation%2Fsupported
#
# One service on the computer you are sitting at, and it is five processes
# wearing one hat: a PostgreSQL 15 and a Redis run inside this container next
# to the Django backend, the Nuxt web frontend and a Caddy of its own. All of
# it lands in /baserow/data, which is a named volume here rather than a
# relative bind mount, because that embedded PostgreSQL chowns its data
# directory to uid 9999 and Windows file sharing cannot grant that chown on a
# home-directory folder. ./backups stays a real folder you can open in Finder
# or Explorer.
#
# BASEROW_PUBLIC_URL carries the port because the browser address does. Nothing
# terminates TLS here, so the inner Caddy stays on :80 and no proxy header is
# claimed. Digest read on 2026-08-07; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  baserow:
    image: baserow/baserow:2.3.3@sha256:41adb3493379403946a493f30873f743bb65b19b5f387d630ec75f41e25d5b5b
    container_name: baserow
    restart: unless-stopped
    env_file: ./.env
    environment:
      # :80 keeps the inner Caddy on plain http and off the ACME path.
      BASEROW_CADDY_ADDRESSES: ":80"
      # One celery worker running both the fast and the slow queue. Upstream
      # names this pair as the way to lower the image's memory use, and the
      # price is that a large export can delay a realtime row update.
      BASEROW_AMOUNT_OF_WORKERS: "1"
      BASEROW_RUN_MINIMAL: "yes"
    volumes:
      - baserow-data:/baserow/data
      - ./backups:/backup
    ports:
      # Loopback only: no other device on the wifi can reach 8175.
      - "127.0.0.1:8175:80"

volumes:
  baserow-data:
EOF
cd ~/selfhost/baserow && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one named volume.

## 6. Nothing is public

No proxy on this host, no certificate, no firewall rule. Each is a decision:

- No DNS, because there is no hostname to resolve.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the editor's crypto still works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8175 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop
on the same wifi, nor anyone on the internet. For a database meant to be shared, that is the
shape of the trade. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/baserow/compose.yml
```

Assert: that prints `1`. The PostgreSQL and the Redis live inside the container and are never
published at all.

## 7. Start and verify

The first boot is slow. The pull is over a gigabyte, then PostgreSQL initialises a cluster,
Django runs every migration from scratch and the built-in templates import in the background.
Upstream's deployment guide asks for a 900-second grace period on a first start, and this loop
allows exactly that.

```bash
cd ~/selfhost/baserow
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8175/api/_health/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8175/api/_health/
curl -sS http://localhost:8175/api/settings/ | grep -o '"show_admin_signup_page":[a-z]*'
```

Assert, all three, and print what you received for each. The loop ends printing `200`. The
health endpoint answers with the two characters `OK` and nothing else. The third command prints
`"show_admin_signup_page":true`, meaning no account exists yet. If any of the three misses,
stop, run `docker compose logs --tail 60 baserow`, and name the likely cause: a container
restarting in a loop is usually Docker Desktop's memory cap, and `port is already allocated`
means something else holds 8175 (`lsof -nP -iTCP:8175 -sTCP:LISTEN`, or
`netstat -ano | findstr :8175` on Windows). A running container is not success.

The first screen at http://localhost:8175 is the sign-up form. Baserow sends the login page
straight to it while no account exists, and it carries the notice `Welcome to Baserow!` above
the line `Please fill the form below to create the admin user.`

STOP: tell the user to open http://localhost:8175, fill that form in, and wait. Do not continue
until they confirm. The first account created on an instance is given staff rights, which is
what makes it the administrator. Tell them to put the password in their password manager as they
type it: there is no mail here, so there is no reset link.

## 8. First backup and restore

One archive, taken with the container stopped, because a tar of a live PostgreSQL is not a
backup. The tar runs inside a throwaway container so the uid 9999 that PostgreSQL owns its
cluster as survives into the archive:

```bash
cd ~/selfhost/baserow
docker compose stop
docker run --rm --volumes-from baserow --entrypoint sh baserow/baserow:2.3.3@sha256:41adb3493379403946a493f30873f743bb65b19b5f387d630ec75f41e25d5b5b -c "tar -czf /backup/baserow-$(date +%F).tar.gz -C /baserow data"
docker compose start
ls -lh ~/selfhost/baserow/backups/
```

Assert: the archive exists and is non-empty. Print its size. On a fresh install with the
templates imported it runs to a few hundred megabytes, and the stop and start cost about a
minute.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder their sync service
watches or a USB stick, and copy it there with `cp`, together with `~/selfhost/baserow/.env`,
which is the only copy of the two keys from step 4. In Git Bash a Windows drive is written
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are listed there. If
they have neither, say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/baserow`, put `.env` and `compose.yml` back if they
are missing, then `docker compose down -v`, which drops the old volume on purpose, then
`docker compose create`, which makes an empty one. Then the same `docker run` line as above with
`tar -xzf` and the archive's filename in place of `tar -czf` and the date, still extracting with
`-C /baserow`. Then `docker compose up -d` and re-run step 7's check. That archive holds a raw
copy of the PostgreSQL data directory, so it restores into this same image and no other. Those
commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/baserow/baserow/releases. Take step 8's backup
first, then edit the image line in ~/selfhost/baserow/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/baserow
docker compose pull
docker compose up -d
docker compose logs --tail 40 baserow
```

Baserow migrates its own database on the way up and prints `Baserow is now available at` when it
has finished. Watch for that line, then re-run step 7's check.

## 10. What will probably go wrong

Docker Desktop's memory cap. I gave this a laptop with 16 GB in it and watched the container
restart in a loop for a quarter of an hour, reading the log for a mistake that was not there.
Docker Desktop was handing its virtual machine 2 GB, and a PostgreSQL, a Redis, a Django and a
Node server do not fit in 2 GB. The number step 1 printed was the laptop's, not Docker's. Open
Docker Desktop, Settings, Resources, give it at least 4 GB, apply and restart, then run step 7
again.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8175 to 0.0.0.0 so a colleague on the wifi can open a table. That publishes a
  database whose sign-up page is open onto every network this computer joins.
- Do not set `BASEROW_CADDY_ADDRESSES` to `:443` or to an https URL. The container would ask
  Let's Encrypt for a certificate that no public name backs.
- Do not configure SMTP, and do not point `DATABASE_URL` or `REDIS_URL` outside the container.
  The embedded pair is the shape of this install.
