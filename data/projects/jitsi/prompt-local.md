You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Jitsi Meet stable-11146-1, all four of its services, under ~/selfhost/jitsi, answering
at http://localhost:8114.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. A meeting room here is reachable from this computer and nowhere else: no colleague and not
even their own phone can join. What they get is a real Jitsi to learn and test with two browser
windows, not a room they can invite anyone into.

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
distribution ID and codename print next, for step 2. Jitsi Meet needs 2048 MB of RAM available
and 10 GB free on the home disk, and all four images publish amd64 and arm64. On macOS and
Windows that memory is the host's, out of which Docker Desktop's virtual machine takes its
allocation. If either number is under its floor, print both and stop. Do not install and hope.

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
mkdir -p ~/selfhost/jitsi/backups ~/selfhost/jitsi/config/web ~/selfhost/jitsi/config/prosody ~/selfhost/jitsi/config/jicofo ~/selfhost/jitsi/config/jvb
ls -la ~/selfhost/jitsi
```

Assert: `ls -la` shows `backups` and `config`, owned by the user. No ownership fix runs here:
the containers only read the `config` tree, and the one directory they write to is a Docker
volume in step 5 rather than a folder.

## 4. Secrets

Three: the XMPP password Jicofo signs in with, the one the video bridge signs in with, and the
moderator password step 7 registers. Generate all three here, print none, and keep them out of
your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/jitsi/.env <<EOF
JICOFO_AUTH_PASSWORD=$(openssl rand -hex 32)
JVB_AUTH_PASSWORD=$(openssl rand -hex 32)
MEET_HOST_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 ~/selfhost/jitsi/.env
umask 022
ls -l ~/selfhost/jitsi/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same everywhere. On
Windows those mode bits are advisory: NTFS does not enforce them and the real boundary is the
user's own account.

Tell the user the moderator password is in ~/selfhost/jitsi/.env, readable with
`grep MEET_HOST_PASSWORD ~/selfhost/jitsi/.env`, and that it belongs in their password manager
now. It is the only login here.

## 5. compose.yml

```bash
cat > ~/selfhost/jitsi/compose.yml <<'EOF'
# Jitsi Meet · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   self-hosting guide . https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker/
#   variable reference . https://github.com/jitsi/docker-jitsi-meet/blob/stable-11146-1/env.example
#   upstream compose ... https://github.com/jitsi/docker-jitsi-meet/blob/stable-11146-1/docker-compose.yml
#
# Four services and no database, on the computer you are sitting at. Paths are
# relative to ~/selfhost/jitsi/, so one file works on macOS, Linux and Windows.
# The Prosody account store is a named volume rather than a bind mount: that
# image runs as uid 1000 and refuses to start when its data directory is not
# writable by it, which Docker Desktop on Windows cannot arrange for a folder
# under the home directory.
#
# Tags and digests read from ghcr.io on 2026-08-06; all four publish amd64 and
# arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: jitsi

services:
  prosody:
    image: ghcr.io/jitsi/prosody:stable-11146-1@sha256:0e3d9ada40c03e6eef151348e0872dce7b4b1c16c173ff4a67afeae60aba2404
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - ./config/prosody:/config
      - jitsi-prosody:/var/lib/prosody
    environment:
      # Rooms open only for an account registered in step 7; guests wait.
      ENABLE_AUTH: "1"
      AUTH_TYPE: internal
      ENABLE_GUESTS: "1"
      JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}
      JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}
      # Read by step 7's register command inside this container.
      MEET_HOST_PASSWORD: ${MEET_HOST_PASSWORD}
      PUBLIC_URL: http://localhost:8114
    # No `ports:`: 5222 and 5280 are reachable only from the other containers.

  jicofo:
    image: ghcr.io/jitsi/jicofo:stable-11146-1@sha256:a5da296923010dcc2daf6a02e6a183181906cb969a088ae90b97516bdeb9737f
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - ./config/jicofo:/config
    environment:
      ENABLE_AUTH: "1"
      AUTH_TYPE: internal
      JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}
      # Upstream's default heap ceiling is 3072m, more than a laptop wants.
      JICOFO_MAX_MEMORY: 512m
      XMPP_SERVER: prosody
    depends_on:
      - prosody

  jvb:
    image: ghcr.io/jitsi/jvb:stable-11146-1@sha256:6a7cec66c6a2fdd8ffd3a90101a0f8e3297aff29494f258caf1bcfbd418a17f3
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - ./config/jvb:/config
    environment:
      JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}
      # The only address a browser on this computer can reach the bridge on.
      JVB_ADVERTISE_IPS: 127.0.0.1
      VIDEOBRIDGE_MAX_MEMORY: 1024m
      XMPP_SERVER: prosody
    ports:
      # Media, not web: browsers send RTP straight here.
      - "10000:10000/udp"
    depends_on:
      - prosody

  web:
    image: ghcr.io/jitsi/web:stable-11146-1@sha256:ff81559621732d3dfc4815f261d41fd826566833016ea772f4d43a77aa88fe9a
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - ./config/web:/config
    environment:
      PUBLIC_URL: http://localhost:8114
      DISABLE_HTTPS: "1"
      ENABLE_AUTH: "1"
      ENABLE_GUESTS: "1"
      # No certificate here, so signalling rides a relative BOSH path.
      BOSH_RELATIVE: "1"
      ENABLE_XMPP_WEBSOCKET: "0"
      XMPP_BOSH_URL_BASE: http://prosody:5280
    ports:
      # Loopback only: no other device on the wifi can reach 8114.
      - "127.0.0.1:8114:8000"
    depends_on:
      - jvb

volumes:
  jitsi-prosody:
EOF
cd ~/selfhost/jitsi && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Four services, no database, one named volume, two ports.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. There is no hostname to resolve, and a
certificate attests a public name that nothing here has. Browsers treat http://localhost as a
secure context, so camera and microphone permissions still work without one.

8114 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi. One port is not on loopback and the user should hear it plainly. 10000/udp, the media
port, is published the way it is on a server. A stranger on the same network gets nothing from
it, because the bridge accepts media only for a session the web interface issued credentials
for, and that interface is on 127.0.0.1. On a network they do not trust, `docker compose down`
closes it.

```bash
grep -n '127.0.0.1' ~/selfhost/jitsi/compose.yml
```

Assert: one line, `- "127.0.0.1:8114:8000"`. Prosody publishes no host port at all.

## 7. Start and verify

```bash
cd ~/selfhost/jitsi
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8114/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8114/ | grep -o '<title>Jitsi Meet</title>'
curl -sS http://localhost:8114/config.js | grep -E "config.hosts.(auth|anonymous)domain"
```

Assert all three and print what you received. The loop ends on `200`. The second prints
`<title>Jitsi Meet</title>`. The third prints
`config.hosts.anonymousdomain = 'guest.meet.jitsi';` and
`config.hosts.authdomain = 'meet.jitsi';`, two lines that appear only when authenticated room
creation is on. If any miss, stop and run `docker compose logs --tail 40 web` and
`docker compose logs --tail 40 prosody`. `port is already allocated` means something else holds
8114 or 10000; find it with `lsof -nP -iTCP:8114 -sTCP:LISTEN`. A running container is not
success.

Now register the account that can open meetings, and prove the room-creating domain takes
nobody else:

```bash
cd ~/selfhost/jitsi
docker compose exec -T prosody sh -c 'prosodyctl --config /run/prosody/config/prosody.cfg.lua register moderator meet.jitsi "$MEET_HOST_PASSWORD"'
docker compose exec -T prosody find /var/lib/prosody -name 'moderator.dat'
docker compose exec -T prosody awk '/^VirtualHost "meet.jitsi"$/,/^VirtualHost /' /run/prosody/config/conf.d/jitsi-meet.cfg.lua | grep authentication
```

Assert both. The `find` prints one path ending in `moderator.dat`. The `awk` prints
`authentication = "internal_hashed"`, the security assert here: that domain takes registered
accounts only, so nothing opens a room without the password, which came from the container's
own environment and is in neither the process list nor the history. If the `find` prints
nothing, Prosody was likely still starting: wait 30 seconds and rerun the register line. On
any other miss, stop.

The first screen at http://localhost:8114 is the Jitsi welcome page, with a room-name box and a
`Start meeting` button.

STOP: tell the user to open http://localhost:8114, type a room name, start the meeting, and
sign in as `moderator` with the password from `grep MEET_HOST_PASSWORD ~/selfhost/jitsi/.env`.
Then have them open the same room in a second window and confirm both windows see each other.
Wait for both. Do not continue until they confirm. Only a browser proves a camera and a
microphone reach the bridge.

## 8. First backup and restore

Two archives: the account store, which lives in a Docker volume, and the two files that rebuild
the service.

```bash
cd ~/selfhost/jitsi
docker compose exec -T prosody tar -cz -C /var/lib/prosody . > ~/selfhost/jitsi/backups/jitsi-accounts-$(date +%F).tar.gz
tar -C ~/selfhost/jitsi -czf ~/selfhost/jitsi/backups/jitsi-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/jitsi/backups/
```

Assert: both files exist and both are non-empty. Print both sizes.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a sync folder
or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both filenames are listed there.

To restore, in this order. `cd ~/selfhost/jitsi`, untar the config archive there first so
compose.yml and .env are back before any container starts. Then `docker compose down -v`, the
one place `-v` belongs because it drops the old account volume on purpose,
`docker compose up -d prosody`, wait about 30 seconds,
`docker compose exec -T prosody tar -xz -C /var/lib/prosody < backups/jitsi-accounts-<date>.tar.gz`,
then `docker compose up -d`. Sign in once as `moderator` to prove it took.

## 9. Updating later

New versions are listed at https://github.com/jitsi/docker-jitsi-meet/releases. Take both
backups first, then edit all four image lines in ~/selfhost/jitsi/compose.yml to the new tag and
digest. The four ship together; upstream does not support mixing them.

```bash
cd ~/selfhost/jitsi
docker compose pull
docker compose up -d
docker compose logs --tail 30 jicofo
```

Watch that log until it settles, then re-run the three checks from step 7.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8114 out of habit, and got a connection refused that reads
like a broken install. It was not: Docker Desktop had not started with the session, so nothing
was listening on 8114. `restart: unless-stopped` only acts once the Docker daemon is up. Turn on
its start-at-login setting, and after a reboot run `cd ~/selfhost/jitsi && docker compose up -d`
first.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8114 to 0.0.0.0 or point `JVB_ADVERTISE_IPS` at this machine's wifi address so
  a phone can join. That puts a meeting server on every network the user walks into.
- Do not install Jibri or Jigasi. Recording is a headless browser in a container of its own,
  and dial-in needs a SIP provider and a phone number.
