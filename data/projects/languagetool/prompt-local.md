You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install LanguageTool 6.8 under ~/selfhost/languagetool, answering at http://localhost:8149,
so the browser add-on and editor plugins on this computer check writing without sending it
anywhere.

## 1. Preflight

Say this to the user before anything installs. The checking they are about to get exists on
this computer and nowhere else: their phone, tablet and second laptop cannot reach
http://localhost:8149, so writing done there goes unchecked. In exchange, not one sentence
they type leaves this machine, which is the thing the paid product cannot offer at any price.

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
distribution ID and codename print next, for step 2. LanguageTool is a Java service that loads
dictionaries for every language it knows, and needs 2048 MB of RAM available and 5 GB free on
the home disk. The image publishes amd64 and arm64. Every branch prints free memory, so one
floor covers all three; on macOS and Windows it is the host's, and Docker Desktop's virtual
machine takes its allocation out of it. If available RAM is under 2048 MB or free disk is
under 5 GB, print both numbers and stop. Do not install and hope: the heap ceiling in step 5
is 1 GB and a machine under the floor fails mid-check, not at start-up.

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
mkdir -p ~/selfhost/languagetool/backups
ls -la ~/selfhost/languagetool
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder and there will
not be one, so there is no ownership fix to make on any of the three systems. LanguageTool
reads its rules and dictionaries out of the image and keeps nothing between requests: text
arrives, is checked, is answered, and is dropped. Step 8 is short because of it.

## 4. Secrets

None, and that is a real answer rather than a skipped step. No account to create, no API key
to mint, no password to set, because the LanguageTool HTTP server has no login of its own. On
a public server that absence has to be covered by a password at the reverse proxy, and the
server path for this app generates one. Here the boundary is the loopback binding instead,
which step 6 explains. Generate nothing and move on.

## 5. compose.yml

```bash
cat > ~/selfhost/languagetool/compose.yml <<'EOF'
# LanguageTool · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   http server ........ https://dev.languagetool.org/http-server
#   upstream readme .... https://github.com/languagetool-org/languagetool/blob/v6.8/README.md
#   image readme ....... https://github.com/Erikvl87/docker-languagetool/blob/v6.8/README.md
#   image dockerfile ... https://github.com/Erikvl87/docker-languagetool/blob/v6.8/Dockerfile
#
# One service on the computer you are sitting at. No bind mount and no named
# volume: LanguageTool loads its rules and dictionaries out of the image and
# keeps nothing between requests, so the text you check is read, answered and
# dropped, and none of it is written to this disk.
#
# The LanguageTool project publishes no Docker image. Its README names three
# community-contributed Dockerfiles and this install uses one of them,
# Erikvl87/docker-languagetool, LGPL-2.1 like LanguageTool itself. That
# Dockerfile clones the upstream v6.8 tag and builds it with Maven, so the code
# is upstream's and the packaging is somebody else's. Tag and digest were read
# from Docker Hub on 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  languagetool:
    image: erikvl87/languagetool:6.8@sha256:ef8fa12cbd485166c9ceeb7139d76d56d07707a624da6bb1fc1fbb5411750527
    container_name: languagetool
    restart: unless-stopped
    environment:
      # The image's start script reads these two and defaults to 256m and 512m.
      # 512m runs out of room once several languages load, and the RAM floor in
      # the install accounts for the larger ceiling.
      Java_Xms: 512m
      Java_Xmx: 1g
      # Every langtool_* variable becomes one line in the server's
      # config.properties. This one caps a single request so one enormous paste
      # cannot hold the whole JVM. 40000 characters is a long document.
      langtool_maxTextLength: "40000"
    ports:
      # Loopback only: no other device on the wifi reaches 8149 and nothing on
      # the internet does. The image starts the server with --public and
      # --allow-origin '*', so this binding is the whole boundary.
      - "127.0.0.1:8149:8010"
    # The image ships a HEALTHCHECK that posts a sentence to /v2/check, so
    # `docker compose ps` reports healthy or unhealthy without help from here.
EOF
cd ~/selfhost/languagetool && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no volume of any kind.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule and no login screen. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.
- No login. This is the honest part and the user should hear it plainly: the LanguageTool
  server checks nobody's credentials, and the image starts it with `--public` and
  `--allow-origin '*'`, which means it answers whoever reaches it. Whoever reaches it is the
  boundary, and here that is this computer alone.

8149 is bound to 127.0.0.1. The user's phone cannot reach it, nor a laptop on the same wifi,
nor anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/languagetool/compose.yml
```

Assert: that prints `1`, the one published port, `- "127.0.0.1:8149:8010"`. If it ever reads
`0.0.0.0:8149`, this install has handed a free grammar API to every network the user joins.

## 7. Start and verify

The first start pulls about 430 MB and then loads dictionaries, so the loop below is patient.

```bash
cd ~/selfhost/languagetool
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8149/v2/languages); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8149/v2/languages | head -c 200
curl -sS -d "language=en-US" -d "text=I has a apple." http://localhost:8149/v2/check
```

Assert all three, and print what you received for each: the loop ends on `200`; the languages
listing contains `"longCode":"en-US"`; the check returns JSON with `"name":"LanguageTool"` in
it and a match whose rule is `"id":"EN_A_VS_AN"`, the engine finding the error in `a apple`.
If any of the three misses, stop, run `docker compose logs --tail 40 languagetool`,
and name the likely cause: a Java heap message means step 1 ran on a machine under the floor,
and `port is already allocated` means something else on this computer holds 8149. Find it with
`lsof -nP -iTCP:8149 -sTCP:LISTEN`, or `ss -ltnp | grep 8149` on Linux, or
`netstat -ano | findstr :8149` on Windows, and stop until the user frees it. A running
container is not success.

There is no first screen. LanguageTool has no web interface, and http://localhost:8149/
answers `404` with the body `Not found`, which is correct rather than broken: the server only
handles paths under `/v2/`.

STOP: tell the user to open the settings of the LanguageTool add-on in their browser, find the
advanced or experimental section where a different server can be chosen, enter
`http://localhost:8149/v2`, save, then type `I has a apple.` into any text box and wait for
the underlines. Wait for them to confirm they see them. Do not continue until they confirm.
That sentence going from their browser to this container and back is the only proof that
matters, and it is the whole product.

## 8. First backup and restore

The shortest backup block on this site, and the reason is the point of the install: no
database, no upload folder, no settings file, so nothing the user writes is here to lose.
What is worth keeping is the pinned compose file, which reproduces this exact version rather
than whatever is current later.

```bash
cd ~/selfhost/languagetool
tar -C ~/selfhost/languagetool -czf ~/selfhost/languagetool/backups/languagetool-$(date +%F).tar.gz compose.yml
ls -lh ~/selfhost/languagetool/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped, because
nothing is being written.

The archive sits on the same disk as the install, which is not a backup, and on a laptop the
disk and the machine fail together. Ask the user for a destination that leaves this computer,
a folder their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`; confirm the destination exists before
copying. Assert: the user confirms the filename is listed there.

To restore, on this machine or a new one: create `~/selfhost/languagetool`, untar the archive
into it, and run `docker compose up -d`. Then re-run step 7's three asserts. Tell the user the
honest version, because it is unusual and good news: this install has no disaster to plan for,
only a version to remember.

## 9. Updating later

LanguageTool tags releases at https://github.com/languagetool-org/languagetool/tags and the
community image that carries them is tagged at
https://hub.docker.com/r/erikvl87/languagetool/tags. Check the second: the packaging is a
separate project, so a new upstream tag is not installable until an image is built for it.
Take the backup first, then edit the image line in ~/selfhost/languagetool/compose.yml to the
new tag and digest:

```bash
cd ~/selfhost/languagetool
docker compose pull
docker compose up -d
docker compose logs --tail 30 languagetool
```

Watch that log until the server reports it is listening, then re-run step 7's three asserts
before calling the update done.

## 10. What will probably go wrong

I rebooted, wrote for twenty minutes, and thought I had suddenly become a careful writer.
Nothing was wrong with my sentences: Docker Desktop had not started with the session, nothing
was listening on 8149, and the add-on had quietly stopped underlining anything. A grammar
checker that is down looks exactly like clean prose, which is the worst failure mode a tool
can have. Turn on Docker Desktop's start-at-login setting, and if the underlines ever stop
appearing, run `curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8149/v2/languages`
before believing your own writing.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8149 to 0.0.0.0 so a phone or another laptop can reach it. This server checks
  nobody's credentials, so on a shared wifi that is an open compute endpoint.
- Do not download the n-gram data. It is roughly 8 GB per language, exists for four languages,
  and buys better detection of confusion pairs like `their` and `there`. This install trades
  that for something that fits on a laptop.
- Do not configure a LanguageTool Premium account and do not set any `langtool_premium`
  variable. Premium is a paid service of the LanguageTool company, the open-source server
  refuses those settings, and the rules it sells are not in this image.
