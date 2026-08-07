You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install draw.io 31.1.8 under ~/selfhost/drawio, answering at http://localhost:8158.

## 1. Preflight

Say both of these to the user before step 2 runs; together they decide whether this install
is worth doing.

First: draw.io already runs a hosted editor at https://app.diagrams.net that costs nothing
and asks for no account. Their own home page says "No account required. No credit card."
This prompt installs the same editor; what changes is where the page comes from. This copy
loads from a container here, so it works with the network unplugged and no third-party
origin serves the code. If neither matters, say plainly that the hosted editor does the
same job.

Second: nothing here stores a diagram. The container has no database and no document store,
so a drawing lives in the storage of the browser that drew it or in a file the user saves
themselves, and clearing site data loses work no backup could have held.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux
the distribution ID and codename print next, for step 2. draw.io is a Tomcat on a JVM and
wants 1024 MB of RAM available and 5 GB free on the home disk; the image publishes amd64
and arm64. Every branch prints free memory, so one floor covers all three, and Docker
Desktop takes its allocation out of that number. If available RAM is under 1024 MB or free
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
mkdir -p ~/selfhost/drawio/backups
ls -la ~/selfhost/drawio
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: the
container writes no diagram to disk, so step 5 mounts nothing and no ownership fix is
needed on any of the three systems.

## 4. Secrets

One secret, and it is not a login. draw.io has no accounts, so there is nothing to sign in
to. What this generates is `KEYSTORE_PASS`: the image builds a self-signed certificate for
its own container port 8443 at every start, and with that variable unset it uses a value
printed in its own public documentation. That port is never published here, so a documented
default would guard something unreachable, which is a reason to replace it rather than a
reason to keep it. Print it nowhere, and keep it out of your summary and out of any log.

```bash
umask 077
cat > ~/selfhost/drawio/.env <<EOF
DRAWIO_SERVER_URL=http://localhost:8158/
KEYSTORE_PASS=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/drawio/.env
umask 022
ls -l ~/selfhost/drawio/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the
same on all three systems. `DRAWIO_SERVER_URL` is upstream's variable for the deployment
URL and it wants the trailing slash, which is why the line ends in one.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary
is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/drawio/compose.yml <<'EOF'
# draw.io · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image, ports, env vars .. https://github.com/jgraph/docker-drawio/blob/v31.1.8/README.md
#   entrypoint behaviour .... https://github.com/jgraph/docker-drawio/blob/v31.1.8/main/docker-entrypoint.sh
#   image build ............. https://github.com/jgraph/docker-drawio/blob/v31.1.8/main/Dockerfile
#
# One container: Tomcat 9 on JDK 11 serving the compiled draw.io editor at the
# root path on container port 8080, as a non-root tomcat user. This file lives
# in ~/selfhost/drawio/ and holds no absolute path, so it works on all three.
#
# There is no volume here, and that is not an omission: a diagram is written to
# this computer's disk or into the browser that drew it, never to the server.
#
# The entrypoint switches every cloud backend off when its credentials are
# absent: with no DRAWIO_GOOGLE_CLIENT_ID, DRAWIO_MSGRAPH_CLIENT_ID or
# DRAWIO_GITLAB_ID it writes gapi, od and gl to 0, and it always writes db, gh
# and tr to 0. This file sets none of them, so none of them are on.
#
# KEYSTORE_PASS arrives from ./.env. Left alone, the image falls back to a
# keystore value printed in its own documentation, on a self-signed certificate
# it makes at every start for container port 8443, which this file never
# publishes. The generated value replaces a documented default.
#
# Tag and digest read from Docker Hub on 2026-08-06; the manifest list covers
# linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  drawio:
    image: jgraph/drawio:31.1.8@sha256:0c8910ea14dfbccb17c784ee17d995317a8d753479f5ec0f21b2ab2213153100
    container_name: drawio
    restart: unless-stopped
    env_file: ./.env
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8080/ >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    ports:
      # Loopback only: no other device on the wifi can reach 8158.
      - "127.0.0.1:8158:8080"
EOF
cd ~/selfhost/drawio && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no mounts.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8158 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the
same wifi, not anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/drawio/compose.yml
```

Assert: that prints `1`, the single published port `- "127.0.0.1:8158:8080"`. Container
port 8443 is never published, so the certificate the image makes at start-up has no way in.

## 7. Start and verify

Tomcat rewrites the editor's configuration from the environment at every start, so the
first boot is the slow one.

```bash
cd ~/selfhost/drawio
docker compose pull
docker compose up -d
for i in $(seq 1 20); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8158/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8158/ | grep -c 'Flowchart Maker'
curl -sS http://localhost:8158/js/PreConfig.js | grep -cF "urlParams['gapi'] = '0'"
curl -sS http://localhost:8158/js/PreConfig.js | grep -cF "window.DRAWIO_SERVER_URL = 'http://localhost:8158/'"
```

Assert all four, and print what you received for each. The loop ends on `200`. The second
command prints `1`, because `Flowchart Maker` is in the title of the served document. The
third prints `1`, the security assert here: it proves the container wrote `gapi` off, so
the Google Drive backend is not offered on this page. The fourth prints `1`, proving the
`.env` from step 4 reached the container. If any of the four misses, stop, run
`docker compose logs --tail 40 drawio`, and name the likely cause: a `404` on PreConfig.js
means the entrypoint could not write into the webapp, and a loop that never reaches `200`
usually means Tomcat is still starting, so give it another minute. If
`port is already allocated` came back, find what holds 8158 with
`lsof -nP -iTCP:8158 -sTCP:LISTEN` and stop until the user frees it. A running container is
not success. Four asserts is success.

The first screen at http://localhost:8158/?offline=1 is a dialog headed `Save diagrams to:`
with two buttons, `Device` and `Browser`, and a `Decide Later` link under them. There is no
login form and no sign-up link, because there are no accounts.

STOP: tell the user to open http://localhost:8158/?offline=1, confirm that dialog shows
`Device` and `Browser` and no Google Drive, OneDrive or GitHub button, and wait.
Do not continue until they confirm. That check is the difference between an editor that
keeps the work on this machine and one that offers to post it somewhere else.

## 8. First backup and restore

There is no database to dump and no data directory to archive. The backup here is the
configuration that rebuilds the service:

```bash
cd ~/selfhost/drawio
tar -C ~/selfhost/drawio -czf ~/selfhost/drawio/backups/drawio-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/drawio/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped, because
there is no write to catch halfway.

That archive sits on the same disk as everything else, which is not a backup, and on a
laptop the disk and the machine fail together. Ask the user for a destination that leaves
this computer, a folder their sync service watches or a USB stick, and copy it there with
`cp`. In Git Bash a Windows drive is written `/d/Backups`. Assert: the user confirms the
filename is listed there.

The diagrams are the other half, and no command here can reach them.

STOP: tell the user to open http://localhost:8158/?offline=1, draw one shape, and use File
then Save As to write the `.drawio` file into a folder they already back up, and wait.
Do not continue until they confirm they have that file. Explain why: pick `Browser` in
that dialog and the diagram is in one browser's local storage, which the archive above
does not contain.

To restore the service: untar the archive into ~/selfhost/drawio and run
`docker compose up -d`. To restore a diagram, open the editor and use File then Open. Tell
the user that is two disaster plans and the second one holds the work.

## 9. Updating later

New versions are listed at https://github.com/jgraph/drawio/releases, and the Docker tag is
the release tag without its leading `v`. Take the backup first, then edit the image line in
~/selfhost/drawio/compose.yml to the new tag and its digest:

```bash
cd ~/selfhost/drawio
docker compose pull
docker compose up -d
docker compose logs --tail 30 drawio
```

Then re-run all four asserts from step 7 before calling the update done. Nothing is
migrated, because the container carries no state between versions.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8158 out of habit, and got a connection error that
looked like the install had evaporated. It had not: Docker Desktop had not started with the
session, so nothing was listening on 8158. `restart: unless-stopped` acts only once the
Docker daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/drawio && docker compose up -d` before concluding anything is broken. The
diagrams were never at risk: they were in the browser and on the disk, not in the container.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8158 to 0.0.0.0 so a phone or a colleague can reach it. That publishes an
  editor with no login on every network this machine joins.
- Do not install the export server or set `DRAWIO_SELF_CONTAINED` or `EXPORT_URL`. That is
  a second container carrying headless Chromium; PNG and SVG export from the browser works
  without it.
- Do not set `DRAWIO_GOOGLE_CLIENT_ID`, `DRAWIO_MSGRAPH_CLIENT_ID`, `DRAWIO_GITLAB_ID` or
  `ENABLE_DRAWIO_PROXY=1`. The first three are OAuth applications registered with somebody
  else, and step 7 asserts they are off; the last opens an endpoint that fetches arbitrary
  external URLs from inside this machine's network.
