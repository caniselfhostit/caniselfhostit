You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install KitchenOwl 0.7.10 under ~/selfhost/kitchenowl, answering at http://localhost:8167.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
KitchenOwl earns its keep when the phone in the supermarket ticks off the item the laptop at
home added ten minutes ago. Here there is one address, http://localhost:8167, and it means
"this computer" wherever it is typed, so the phone in their pocket cannot open it and the app
on it has nothing to point at. They get a private grocery list on one desk.

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
distribution ID and codename print next, for step 2. KitchenOwl needs 1024 MB of RAM available
and 5 GB free on the home disk, and the image publishes amd64 and arm64. Every branch prints
free memory, so one floor covers all three; on macOS and Windows it is the host's, and Docker
Desktop takes its allocation out of that. Under either floor, print both numbers and stop.

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
mkdir -p ~/selfhost/kitchenowl/data ~/selfhost/kitchenowl/backups
ls -la ~/selfhost/kitchenowl
```

Assert: `ls -la` shows `data` and `backups`, both owned by the user. Everything KitchenOwl keeps
goes under `data`: the SQLite file holding the shopping lists, recipes, meal plans and expenses,
and an `upload` directory of photos. The container runs as root and writes there itself, so
there is no ownership fix on any of the three systems and no named volume hiding the files.

## 4. Secrets

One secret: the JWT signing key. Upstream's sample compose file sets it to a fixed placeholder
printed on the same documentation page, so an install that leaves the default alone can have
its session tokens minted by anyone who read that page. Generate it here, print it never, and
keep it out of your summary and every log line.

```bash
umask 077
cat > ~/selfhost/kitchenowl/.env <<EOF
FRONT_URL=http://localhost:8167
JWT_SECRET_KEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/kitchenowl/.env
umask 022
ls -l ~/selfhost/kitchenowl/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. `FRONT_URL` is the origin upstream documents for the CORS header and
has to match the address the app is opened at exactly, scheme and port included.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/kitchenowl/compose.yml <<'EOF'
# KitchenOwl · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   self-hosting ....... https://docs.kitchenowl.org/v0.7.10/self-hosting/
#   variable reference . https://docs.kitchenowl.org/v0.7.10/self-hosting/advanced/
#   image .............. https://github.com/TomBursch/kitchenowl/blob/v0.7.10/Dockerfile
#
# One service on the computer you are sitting at. Every path is relative to
# ~/selfhost/kitchenowl/, which lets one file work on macOS, Linux and Windows
# and keeps the shopping lists a folder you can open in Finder or Explorer. The
# container process runs as root and writes into /data itself, so the relative
# bind mount needs no named volume and no ownership fix on any of the three.
# The database driver defaults to sqlite and the file lands in ./data next to
# the uploaded photos. The image declares its own HEALTHCHECK against the
# /api/health route. FRONT_URL is http://localhost:8167, which is an address
# this computer answers and no other device does. Digest read from Docker Hub
# on 2026-08-07; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  kitchenowl:
    image: tombursch/kitchenowl:v0.7.10@sha256:bd821a41b8cb27fd7fcf429acd1fc67e9f889485a2cd1193d68c2d804a8e1bef
    container_name: kitchenowl
    restart: unless-stopped
    # FRONT_URL and the signing key come from ./.env, mode 600. The image
    # carries a signing-key default that upstream prints in its own sample, so
    # this file is only safe with that file in place.
    env_file: ./.env
    environment:
      # Nobody can create an account from the sign-in screen.
      OPEN_REGISTRATION: "false"
      # Onboarding stays available until one account exists, then the server
      # closes it on its own: the endpoint counts users and refuses at one.
      DISABLE_ONBOARDING: "false"
    volumes:
      - ./data:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8167.
      - "127.0.0.1:8167:8080"
EOF
cd ~/selfhost/kitchenowl && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount. There is no
database container: SQLite rides inside the same image, and it is the driver upstream defaults
to.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8167 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. For a grocery list built around a household that is the trade,
and it is the point of this path rather than a fault in it.

```bash
grep -c '"127.0.0.1:' ~/selfhost/kitchenowl/compose.yml
```

Assert: that prints `1`. One published port in the file, and it is the loopback one.

## 7. Start and verify

The container migrates its database and imports a default item list on the way up, so the first
start is slower than the ones after it. Nothing here is reachable from another machine, but
until an account exists the onboarding endpoint hands the owner account to whoever posts to it,
so finish this block in one sitting.

```bash
cd ~/selfhost/kitchenowl
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8167/api/health/8M4F88S8ooi4sMbLBfkkV7ctWwgibW6V); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8167/api/health/8M4F88S8ooi4sMbLBfkkV7ctWwgibW6V
curl -sS http://localhost:8167/api/onboarding
curl -sS http://localhost:8167/ | grep -o '<title>[^<]*</title>'
```

Assert all four, printing what you got for each: the loop ends on `200`; the health JSON has a
`msg` field reading `OK` and no `open_registration` field, which is how the server reports that
public signups are off; the onboarding call answers with `onboarding` set to `true`; the last
prints `<title>KitchenOwl</title>`. If any misses, stop, run
`docker compose logs --tail 40 kitchenowl`, and name the cause: a container still working
through migrations wants more time, one restarting in a loop points at an empty `.env` from
step 4, and `port is already allocated` means something else here already holds 8167. A running
container is not success.

The first screen at http://localhost:8167 shows the heading `Let's create a user` above a
`Start` button, with a `Switch server` link under it. It shows because no account exists.

STOP: tell the user to open http://localhost:8167 now, press `Start`, and create their
account with a username, a name and a password they choose themselves. Wait.
Do not continue until they confirm. That first account is the owner: the server creates
it with admin rights and then refuses to create a second one this way.

Once they confirm, prove the door is shut:

```bash
curl -sS http://localhost:8167/api/onboarding
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8167/api/auth/signup
```

Assert both: the first answers with `onboarding` set to `false`, and the second prints `404`.
With public registration off the server publishes no signup route at all, so a missing one is
the correct answer rather than a routing fault. If `onboarding` still reads `true`, the account
was not created and the owner slot is unclaimed, so stop and say so plainly.

## 8. First backup and restore

Two artifacts: a data archive with the SQLite database and the photo uploads, and a config
archive with the two files that rebuild the service around them. The container stops for the
first, because a SQLite file copied while it is being written is not a backup.

```bash
cd ~/selfhost/kitchenowl
docker compose stop
tar -C ~/selfhost/kitchenowl -czf ~/selfhost/kitchenowl/backups/kitchenowl-data-$(date +%F).tar.gz data
docker compose start
tar -C ~/selfhost/kitchenowl -czf ~/selfhost/kitchenowl/backups/kitchenowl-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/kitchenowl/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Downtime is seconds.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is written
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are listed there. If
they have neither, say plainly that this install has no backup.

To restore: `cd ~/selfhost/kitchenowl`, `docker compose down`, delete `data`, unpack the archive
in its place with `tar -xzf backups/kitchenowl-data-<date>.tar.gz -C ~/selfhost/kitchenowl`,
untar the config archive the same way, then `docker compose up -d`. Tell the user what matters
at 2am: the signing key is in `.env` rather than the database, so restoring the data without
that file signs every open tab out, and restoring both signs nobody out.

## 9. Updating later

New versions are listed at https://github.com/TomBursch/kitchenowl/releases. Take both backups
first, then edit the image line in ~/selfhost/kitchenowl/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/kitchenowl
docker compose pull
docker compose up -d
docker compose logs --tail 30 kitchenowl
```

KitchenOwl migrates its own database on the way up, so watch that log until it settles, then
re-run step 7's health check before calling this done.

## 10. What will probably go wrong

I closed the laptop lid with a half-written shopping list on screen, opened it an hour later,
and the page refused to take a new item while still showing the old ones. It was not a lost
database. Docker Desktop suspends its virtual machine when the computer sleeps, the live
connection the page holds open dies with it, and the tab goes on rendering what it already had.
Reload the tab first; if it still hangs, run `cd ~/selfhost/kitchenowl && docker compose ps` and
give the container a minute.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8167 to 0.0.0.0 so the phone in the kitchen can reach it. That puts a household
  grocery list, its photos and its expense records on every network this machine joins.
- Do not set `OPEN_REGISTRATION`, and do not configure OIDC, Google or Apple sign-in. This
  install has one account on one computer.
- Do not switch the database driver to PostgreSQL, configure SMTP, or set
  `KITCHENOWL_MCP_ENABLED`. This install is one container with one file of data.
