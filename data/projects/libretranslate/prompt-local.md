You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install LibreTranslate 1.9.6 under ~/selfhost/libretranslate, answering at
http://localhost:8154, so documents and messages are translated by models on this disk.

## 1. Preflight

Say this to the user before anything installs. The translation they are about to get happens on
this computer and nowhere else: their phone and second laptop cannot reach
http://localhost:8154, so anything typed there goes elsewhere to be translated. In exchange,
not one sentence they paste here leaves this machine, which is what a translation subscription
cannot offer at any price.

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
distribution ID and codename print next, for step 2. LibreTranslate loads neural translation
models into memory, one copy per worker, and needs 2048 MB of RAM available and 10 GB free on
the home disk. The image publishes amd64 and arm64, so an Apple Silicon Mac is covered. On
macOS and Windows the memory figure is the host's, and Docker Desktop's virtual machine takes
its allocation out of it. If available RAM is under 2048 MB or free disk is under 10 GB, print
both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/libretranslate/backups
ls -la ~/selfhost/libretranslate
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder and there will
not be one: nothing the user translates is stored. The only thing this install writes is the
model cache, kept in a volume Docker manages, so no ownership fix is needed on any of the three
systems.

## 4. Secrets

None, and that is a real answer rather than a skipped step. No account to create, no password
to set, no key to mint. The server path generates an API key and turns on the mode that demands
one, because anybody can reach a public hostname and translation is expensive CPU to give away.
Here the boundary is the loopback binding, which step 6 explains. Generate nothing and move on.

## 5. compose.yml

```bash
cat > ~/selfhost/libretranslate/compose.yml <<'EOF'
# LibreTranslate · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   installation ....... https://docs.libretranslate.com/guides/installation/
#   quickstart ......... https://docs.libretranslate.com/
#   argument defaults .. https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/libretranslate/default_values.py
#   image build ........ https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/docker/Dockerfile
#   container start .... https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/scripts/entrypoint.sh
#
# One service on the computer you are sitting at. No key database and no key
# requirement: the server path sets LT_API_KEYS and LT_UNDER_ATTACK because a
# public hostname needs a door, and here the loopback binding is the door.
#
# One mount, and it is a named volume rather than a folder you can open: the
# image creates its own user with uid 1032 and chowns /home/libretranslate to
# it, which a fresh named volume inherits and a home-directory bind mount
# cannot. Nothing is hidden from you by that. The model cache is all this
# install writes, because text arrives, is translated, is answered, and is
# dropped. Upstream's run.sh mounts the same path.
#
# Tag and digest were read from Docker Hub on 2026-08-07; the image publishes
# amd64 and arm64. The -cuda tag is a separate amd64-only image this file does
# not use: the CPU image is upstream's ordinary path.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  libretranslate:
    image: libretranslate/libretranslate:v1.9.6@sha256:1de2d7056bb8ad607a412f4563d9abe324ff632b43b5be9428bcc8e213aebb32
    container_name: libretranslate
    restart: unless-stopped
    environment:
      # Eleven languages, each paired with English in both directions and
      # pivoted through English for every other combination. That is 22 model
      # packages, about 2.1 GB, downloaded during the first start. Deleting this
      # line downloads all 100 packages in the index instead, about 8.4 GB.
      LT_LOAD_ONLY: "en,es,fr,de,it,pt,nl,pl,ru,zh,ja"
      # entrypoint.sh hands this to gunicorn as --workers. Each worker loads its
      # own copy of a model on first use, so this number multiplies memory and
      # Docker Desktop's virtual machine has a ceiling. Upstream's default is 4.
      LT_THREADS: "2"
      # One request cannot occupy a worker forever. 20000 characters is a long
      # document; upstream's default is no ceiling at all.
      LT_CHAR_LIMIT: "20000"
    volumes:
      - libretranslate-models:/home/libretranslate/.local
    ports:
      # Loopback only: no other device on the wifi reaches 8154, and nothing on
      # the internet does.
      - "127.0.0.1:8154:5000"
    healthcheck:
      # Upstream's own script. It exits 0 while /tmp/booting.flag exists, so the
      # container does not report unhealthy during the first model download.
      test: ["CMD-SHELL", "./venv/bin/python scripts/healthcheck.py"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 900s

volumes:
  libretranslate-models:
EOF
cd ~/selfhost/libretranslate && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and no API key. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.
- No key. The server path demands one because anybody can reach a public hostname, which is
  exactly why it is unnecessary here.

8154 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop
on the same wifi, nor anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/libretranslate/compose.yml
```

Assert: that prints `1`, the single published port, `- "127.0.0.1:8154:5000"`. Nothing else in
the file publishes anything.

## 7. Start and verify

The first start downloads the 22 model packages named by `LT_LOAD_ONLY`, about 2.1 GB, before
anything answers. The loop below is patient for that reason, and
`docker compose logs -f libretranslate` prints a `Downloading` line per package.

```bash
cd ~/selfhost/libretranslate
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8154/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8154/health
curl -sS http://localhost:8154/languages | grep -o '"code": *"es"' | head -1
curl -sS --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" http://localhost:8154/translate
curl -sS http://localhost:8154/ | grep -o 'Translation API' | head -1
```

Assert all five, and print what you received for each: the loop ends on `200`; the health
response carries `"status"` reading `ok`; the languages grep prints `"code":"es"`; the
translate call returns JSON containing `"translatedText"` with Spanish in it; the last command
prints `Translation API`, the heading on the first screen at http://localhost:8154. If any of
the five misses, stop, run `docker compose logs --tail 40 libretranslate`, and name the likely
cause: a connection refused while the loop runs means the models are still downloading, and a
container that keeps restarting near the RAM floor is step 1 saying it wanted more. If
`port is already allocated` came back, find what holds 8154 (`lsof -nP -iTCP:8154
-sTCP:LISTEN`, `ss -ltnp | grep 8154` on Linux, `netstat -ano | findstr :8154` on Windows) and
stop until the user frees it. A running container is not success.

STOP: tell the user to open http://localhost:8154, paste a sentence, pick a target language,
and confirm a translation appears. Do not continue until they confirm. That page is the whole
product, and the same JSON API sits underneath it for any script on this computer to post to
at http://localhost:8154/translate.

## 8. First backup and restore

The shortest backup on this site, because there is no user data to lose. The archive holds the
one file that rebuilds the service:

```bash
cd ~/selfhost/libretranslate
tar -C ~/selfhost/libretranslate -czf ~/selfhost/libretranslate/backups/libretranslate-$(date +%F).tar.gz compose.yml
ls -lh ~/selfhost/libretranslate/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped: the models are
a cache and no translation is kept.

That archive sits on the same disk as the install, which is not a backup, and on a laptop the
disk and the machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`; confirm the destination exists before
copying. Assert: the user confirms the filename is listed there.

To restore on any machine: untar the archive into ~/selfhost/libretranslate and run
`docker compose up -d`. The models download again and take as long as before. Tell the user the
honest version of what this backup is worth: ten minutes of setup and no documents at all,
because their documents were never stored here.

## 9. Updating later

New versions are listed at https://github.com/LibreTranslate/LibreTranslate/releases. Take the
backup first, then edit the image line in ~/selfhost/libretranslate/compose.yml to the new tag
and digest:

```bash
cd ~/selfhost/libretranslate
docker compose pull
docker compose up -d
docker compose logs --tail 30 libretranslate
```

Watch that log until the server reports it is listening, then re-run step 7's asserts before
calling the update done. The models are versioned separately from the software and this file
does not pin them: they resolve against a package index at download time, so a rebuilt cache
can hold a newer model than before.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8154 out of habit, and got a connection error
that read like a lost install. It was not: Docker Desktop had not started with the session, so
nothing was listening on 8154, and `restart: unless-stopped` acts only once the Docker daemon
is up. The models were exactly where I left them. Turn on Docker Desktop's start-at-login
setting, then after a reboot run `cd ~/selfhost/libretranslate && docker compose up -d` before
concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8154 to 0.0.0.0 so a phone on the wifi can reach it. With no key required, that
  hands an unauthenticated translation endpoint to every network the user joins.
- Do not switch to the `-cuda` image tag. It is a separate amd64-only image needing an NVIDIA
  card and the container toolkit; the CPU image is what upstream builds for both architectures.
- Do not delete `LT_LOAD_ONLY` to get every language. That downloads all 100 packages in the
  index, about 8.4 GB, on a disk this prompt sized for 10.
