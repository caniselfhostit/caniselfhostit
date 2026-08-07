You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Collabora Online Development Edition 26.04.2.4.1 under ~/selfhost/collabora, answering
at http://localhost:8165.

## 1. Preflight

Say this before step 2 runs; it decides whether they want this install at all. Collabora Online
is an editing engine, not a place to keep files: on its own it edits nothing, it renders and
saves documents another application hands it. That application has to be on this same computer,
because the editor answers at http://localhost:8165, which means "this machine" wherever it is
read, and nobody else can open a document alongside them.

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
distribution ID and codename print next, for step 2. This install needs 2048 MB of RAM
available and 10 GB free on the home disk; amd64 and arm64 are both published. On macOS and
Windows the figure printed is the host's, and Docker Desktop takes its allocation out of it. If
available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Each
open document is a separate process here, so a machine short of memory fails on the third
document, not at startup.

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
mkdir -p ~/selfhost/collabora/backups
ls -la ~/selfhost/collabora
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder and no ownership
fix on any of the three systems, because step 5 declares no volume at all: coolwsd builds its
jails and its cache inside the container, which the source calls state-less. Two files are the
whole install.

## 4. Secrets

One secret: the admin console password. Generate it here, print it nowhere, and keep it out of
your summary and any log line. Hex rather than base64, because the user types this into a
browser login box and hex has no characters that invite a typo.

```bash
umask 077
cat > ~/selfhost/collabora/.env <<EOF
username=admin
password=$(openssl rand -hex 24)
server_name=localhost:8165
aliasgroup1=
EOF
chmod 600 ~/selfhost/collabora/.env
umask 022
ls -l ~/selfhost/collabora/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same
on all three. The four names are lowercase because coolwsd reads them from the environment
exactly as written. `username` and `password` become the admin console credentials.
`aliasgroup1` is deliberately empty and step 7 fills it in: set at all, it switches the WOPI
host list into group mode, and with no group in it upstream's own log line reads
`all WOPI hosts will be denied`. The alternative default lets the first application that
connects claim the server. The user reads the password with `grep password .env` here.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/collabora/compose.yml <<'EOF'
# Collabora Online (CODE) · the deterministic fallback for the local path.
# Authored by caniselfhostit from the upstream sources, not copied:
#   image build ........ https://github.com/CollaboraOnline/online.mirror/blob/main/docker/from-packages/Dockerfile
#   env var handling ... https://github.com/CollaboraOnline/online.mirror/blob/main/wsd/COOLWSD.cpp
#   config reference ... https://github.com/CollaboraOnline/online.mirror/blob/main/coolwsd.xml.in
#
# One service, same tag, digest and host port as the server file, with the env
# file path relative so it works from ~/selfhost/collabora/ on all three
# systems. No volumes and no bind mounts at all: coolwsd builds its jails and
# its cache inside the container, which the source calls state-less. Your
# documents live in whichever application hands them over, not here.
#
# No healthcheck is declared here. The 26.04 image is built on a distroless
# base with no shell, so a CMD-SHELL probe of ours would have nothing to run
# it. It ships `coolwsd --probe --use-env-vars` instead, which GETs /livez.
#
# Digest read on 2026-08-07; amd64 and arm64 both published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  collabora:
    image: collabora/code:26.04.2.4.1@sha256:1f864ce3f0c49e867787b6dd303bd6ba989542d3023f6809df558eafd04c1b97
    container_name: collabora
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Nothing here terminates TLS, so coolwsd serves plain http and the
      # links it builds say http. With ssl.enable false the self-signed
      # certificate branch never runs, so no throwaway certificate is made.
      extra_params: "--o:ssl.enable=false"
    ports:
      # Loopback only: no other device on the wifi can reach 8165.
      - "127.0.0.1:8165:9980"
    # SIGTERM has to leave coolwsd time to save and upload whatever is still
    # open in an editor. Upstream's own deployment allows the same 60 seconds.
    stop_grace_period: 60s
EOF
cd ~/selfhost/collabora && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`: one service, one published port, no volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs shutting.

8165 is bound to 127.0.0.1: this computer, not the user's phone, not a laptop on the same wifi.
That is the point of this path, not a defect in it. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/collabora/compose.yml
```

Assert: that prints `1`, the published-port line. Nothing else is published.

## 7. Start and verify

The image is about 470 MB compressed, so the pull takes minutes, and the first start scans the
fonts and dictionaries before anything answers.

```bash
cd ~/selfhost/collabora
docker compose pull
docker compose up -d
for i in $(seq 1 30); do body=$(curl -sS http://localhost:8165/ || true); echo "$i $body"; [ "$body" = "OK" ] && break; sleep 10; done
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8165/hosting/discovery
curl -sS http://localhost:8165/hosting/discovery | grep -c 'wopi-discovery'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8165/browser/dist/admin/admin.html
```

Assert all four, and print what you received for each: the loop ends on `OK`, the plain text
body upstream's own readiness probe reads from `/`; discovery returns `200`; the grep prints at
least `1`; the admin console returns `401`, the security assert, because it proves the console
refuses anyone without the password from step 4. If any of the four misses, stop, run
`docker compose logs --tail 40 collabora`, and name the cause: an empty reply in the first
minutes is a container still starting, and a `200` from the console means .env never reached
it. If `port is already allocated` came back, find what holds 8165
(`lsof -nP -iTCP:8165 -sTCP:LISTEN`, or `netstat -ano | findstr :8165` on Windows) and stop
until the user frees it. A running container is not success.

The first screen is http://localhost:8165/hosting/discovery, an XML document whose opening
element reads `<wopi-discovery>`. The admin console at
http://localhost:8165/browser/dist/admin/admin.html asks for the username `admin` and the
step 4 password, and its dashboard heading then reads `Dashboard`.

STOP: tell the user nothing is editing a document yet, ask for the address their Nextcloud
answers on, and wait. Do not continue until they answer, or say they will connect it later.
Then put that address in the alias group and restart:

```bash
sed -i.bak 's|^aliasgroup1=$|aliasgroup1=http://localhost:8080|' ~/selfhost/collabora/.env
cd ~/selfhost/collabora && docker compose up -d --force-recreate
sleep 20
grep -c '^aliasgroup1=http' ~/selfhost/collabora/.env
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8165/hosting/discovery
```

Replace `http://localhost:8080` with the address the user gave, scheme and port included, then
`rm ~/selfhost/collabora/.env.bak`. Assert: the grep prints `1` and discovery prints `200`.
Until then this server denies every application that asks for a document, a safe state rather
than a fault. The user's Nextcloud steps: install the app named `Collabora Online` from Apps,
open `/settings/admin/richdocuments`, put `http://localhost:8165` in the server field, save.
Read them step 10 first: that address is where this goes wrong.

## 8. First backup and restore

One archive of two files, and it is the whole install: the documents are in the other
application and this container keeps nothing. What is irreplaceable is the password and alias
group in `.env`, and the pinned digest in `compose.yml`.

```bash
cd ~/selfhost/collabora
tar -czf backups/collabora-config-$(date +%F).tar.gz compose.yml .env
ls -lh backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped.

That archive sits on the same disk as everything else, which is not a backup: on a laptop the
disk and the machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms the filename
is listed there; if they have neither, say plainly this install has no backup.

Prove the restore now, while nothing is at stake. In `~/selfhost/collabora`: `docker compose
down`, `rm -f compose.yml .env`, `tar -xzf backups/collabora-config-$(date +%F).tar.gz`,
`docker compose up -d`, then re-run step 7's loop. Assert: it ends on `OK` again. That is the
whole disaster plan, and anything open in an editor at that moment is lost, though the document
itself is not.

## 9. Updating later

New tags are at https://hub.docker.com/r/collabora/code/tags and what changed is at
https://www.collaboraonline.com/code-26-04-release-notes/. Back up first, then edit the image
line in ~/selfhost/collabora/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/collabora
docker compose pull
docker compose up -d
docker compose logs --tail 30 collabora
```

Watch that log until it settles, then re-run step 7's four asserts before calling it done.

## 10. What will probably go wrong

The address will work in the browser and fail in the application anyway. I put
http://localhost:8165 into Nextcloud's Collabora settings, watched the editor load in my own
browser, and got an error saying the server was unreachable. Both were true: my browser was on
this machine, so localhost was this machine, but Nextcloud's server fetches
`/hosting/discovery` from that address too, and if Nextcloud is in a container then localhost
is that container, where nothing listens. Run that application outside a container, or put
both on one Docker network and use the service name in the settings field and the alias group.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not delete the `aliasgroup1` line to make a connector work. Removing it hands the server
  to whichever application connects first, and step 10 is the real problem it hides.
- Do not set `remoteconfigurl`. It fetches configuration from a URL on every restart, which
  hands the install to whoever controls that URL.
- Do not install Nextcloud here. This prompt installs the editor.
