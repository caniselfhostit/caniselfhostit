You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install LinkStack 4.8.6 on this computer, answering at http://localhost:8121 and nowhere else,
with everything it keeps under ~/selfhost/linkstack/.

## 1. Preflight

Say this to the user first, because it decides whether they want the install at all. A
link-in-bio page is an address other people open. This one answers at http://localhost:8121,
which reads as "the computer I am typing on" to everyone, so a link sent to a friend or opened
on their own phone goes nowhere. What they get is the admin panel, the themes and their page as
it will look, on one machine.

Find out which operating system this is. Steps 2 and 8 branch on it.

```bash
uname -s
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize | awk '{printf "%d MB of RAM installed\n", $1/1048576}' ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. LinkStack
needs 512 MB of RAM and 5 GB free on the home disk, and the image covers amd64, arm64 and two
32-bit arm variants. Free disk under 5 GB is a stop on any system. Only the Linux line measures
the RAM floor: under 512 MB available, print both numbers and stop. macOS and Windows print
installed RAM instead (bytes on Windows, divide by 1048576), which any machine running Docker
Desktop clears; there the floor is Docker Desktop's own allocation, under Settings, Resources.
Do not install and hope.

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
  with its signing key saved to a file first, never piped into a shell. The fence is guarded, a
  no-op on anything but a Linux with apt:

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

```bash
mkdir -p ~/selfhost/linkstack/backups
ls -la ~/selfhost/linkstack
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder and no
ownership fix on any system: the application, its themes, its uploads and its SQLite
database live in a Docker volume: the image ships the application at /htdocs, and Docker fills
an empty named volume but never a bind mount. Step 8 pulls those files into `backups`.

## 4. Secrets

Nothing is generated here and there is no `openssl rand` in this prompt. LinkStack's only
credential is the administrator account, created in a browser at step 7. This step writes
configuration: the name Apache answers to, which the compose file reads.

```bash
umask 077
cat > ~/selfhost/linkstack/.env <<'EOF'
HTTP_SERVER_NAME=localhost
HTTPS_SERVER_NAME=localhost
EOF
chmod 600 ~/selfhost/linkstack/.env
umask 022
cat ~/selfhost/linkstack/.env
```

Assert: `cat` prints exactly those two lines. Say two things. There are two files called `.env`
here: this one is Compose's, and the application keeps its own at /htdocs inside the container,
which steps 7 and 8 reach with `docker compose exec`. And on Windows, mode bits on NTFS are
advisory, so `chmod` protects nothing by itself; the real boundary is their own account, and
everything here is in their home directory.

## 5. compose.yml

```bash
cat > ~/selfhost/linkstack/compose.yml <<'EOF'
# LinkStack · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker setup ... https://docs.linkstack.org/docker/setup/
#   image build .... https://github.com/LinkStackOrg/linkstack-docker/blob/main/Dockerfile
#
# One container: Alpine, Apache 2 and PHP 8.3, carrying LinkStack 4.8.6 and the
# SQLite file it keeps links and users in. It sits in ~/selfhost/linkstack/ and
# reads ./.env from beside itself, which lets one file work on all three OSes.
#
# /htdocs is a named volume, not a relative bind mount: the image ships the
# application there, and Docker fills an empty named volume from the image but
# never a bind mount.
#
# The pin is a digest with no tag, because upstream publishes no version tags.
# Manifest list read from Docker Hub on 2026-08-06; /htdocs/version.json inside
# it reads 4.8.6. It covers amd64, arm64 and two 32-bit arm variants.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  linkstack:
    image: linkstackorg/linkstack@sha256:1c8b05399ee459ac601bac3eede7fbe765d1b6b7be725663b57f3220610958bf
    container_name: linkstack
    restart: unless-stopped
    # HTTP_SERVER_NAME and HTTPS_SERVER_NAME are Apache's ServerName, and on
    # this path both are localhost. They live in .env beside this file.
    env_file: ./.env
    environment:
      TZ: UTC
      # Apache's log level. The image default is info; warn keeps the container
      # log to lines worth reading.
      LOG_LEVEL: warn
      PHP_MEMORY_LIMIT: 256M
      UPLOAD_MAX_FILESIZE: 8M
    volumes:
      - linkstack-htdocs:/htdocs
    ports:
      # Loopback only: no other device on this network reaches 8121, not the
      # user's own phone. The container also listens on 443 with a self-signed
      # certificate, which this file never publishes. The image's own health
      # check curls http://localhost, this same port.
      - "127.0.0.1:8121:80"

volumes:
  linkstack-htdocs:
EOF
cd ~/selfhost/linkstack && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision, not an omission:

- The published port is `127.0.0.1:8121`, this computer only. Another laptop on the same wifi
  cannot reach it, and neither can the user's phone. That is this path, not a defect.
- No hostname, so nothing to resolve and nothing to certify. Browsers treat `http://localhost`
  as a secure context, so pages needing crypto still work.
- No firewall rule, because nothing is published past loopback.
- The application's `FORCE_HTTPS` setting stays off, unlike the server path: nothing terminates
  TLS here, and forcing the scheme would print addresses that do not answer.

```bash
grep -n '127.0.0.1' ~/selfhost/linkstack/compose.yml
```

Assert: one line, `- "127.0.0.1:8121:80"`.

## 7. Start and verify

```bash
cd ~/selfhost/linkstack
docker compose pull
docker compose up -d
for i in $(seq 1 30); do state=$(docker inspect --format '{{.State.Health.Status}}' linkstack 2>/dev/null || echo starting); echo "$i $state"; [ "$state" = healthy ] && break; sleep 5; done
curl -sSL -o /dev/null -w '%{http_code}\n' http://localhost:8121/
curl -sSL http://localhost:8121/ | grep -c 'Setup LinkStack'
```

Assert all three, and print what you received: the loop ends on `healthy`; the curl prints
`200`; the last prints a number greater than `0`. If any misses, stop, run
`docker compose logs --tail 40 linkstack`, and name the likely cause. If `port is already
allocated` came back, find what holds 8121 (`lsof -nP -iTCP:8121 -sTCP:LISTEN`,
`ss -ltnp | grep 8121` on Linux, `netstat -ano | findstr :8121` on Windows) and stop until the
user frees it. A running container is not success.

The first screen at http://localhost:8121 shows the heading `Setup LinkStack` and a language
menu.

STOP: tell the user to open http://localhost:8121 now and work through the five setup screens,
and wait. Do not continue until they confirm. Tell them the three answers that matter: choose
SQLite for the database type, use a password from their password manager on the admin screen,
and set `Enable registration` to `No` on the last screen.

Once they confirm, prove the install closed behind them:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8121/register
docker compose exec -T linkstack sh -c 'test ! -f /htdocs/INSTALLING && echo "installer removed"'
curl -sSL http://localhost:8121/login | grep -c 'Sign In'
docker compose exec -T linkstack sh -c "sed -i 's/^APP_DEBUG=true$/APP_DEBUG=false/; s/^APP_ENV=local$/APP_ENV=production/' /htdocs/.env"
docker compose exec -T linkstack grep -E '^APP_(DEBUG|ENV)=' /htdocs/.env
```

Assert, all four: `/register` prints `404`, the application's answer once registration is off;
`installer removed` prints, so the setup routes are gone; the login count is above `0`; and the
last grep prints `APP_DEBUG=false` and `APP_ENV=production`, so a PHP error shows a generic
page, not a stack trace. All four before you report success.

## 8. First backup and restore

Two artifacts: the data archive holds what the user made, the config archive the files that
rebuild the service around it.

```bash
cd ~/selfhost/linkstack
docker compose exec -T linkstack tar -czf - -C /htdocs .env database assets/img themes > backups/linkstack-data-$(date +%F).tar.gz
tar -C ~/selfhost/linkstack -czf backups/linkstack-config-$(date +%F).tar.gz compose.yml .env
ls -lh backups/
```

Assert: both files exist and both are non-empty. Print both sizes. The data archive is small
because it leaves out the application code, which comes back from the pinned image. The `.env`
inside carries `APP_KEY`; without it the sessions and password-reset links in a restored
database stop verifying, so it is the one file that cannot be replaced.

Both archives sit on the same disk as the data, which is not a backup, and on one computer the
disk and the machine fail together. Ask which folder a sync service already watches, or have
them plug in a USB stick: /Volumes on macOS, usually /media on Linux, a drive letter such as /d
in Git Bash. Confirm it with `ls -d`, then `cp` both archives there. Do not guess a path.
Assert: the user confirms both filenames are listed there.

To restore, run `ls -lh backups/`, have the user name the data archive, and put that filename in
the `ARCHIVE` slot. `down -v` drops the volume on purpose, `up -d` refills /htdocs from the
pinned image, and the `rm -f` clears the setup marker the fresh image brings back:

```bash
cd ~/selfhost/linkstack
docker compose down -v && docker compose up -d && sleep 30
docker compose exec -T linkstack tar -xzf - -C /htdocs < backups/ARCHIVE
docker compose exec -T linkstack rm -f /htdocs/INSTALLING
```

Then open http://localhost:8121 and sign in. That is the disaster plan.

## 9. Updating later

Two things move here, separately. The application in /htdocs updates from inside: upstream's
documented path for this image is the update notice in the admin panel and its one-click
updater, which rewrites the volume. Take both archives from step 8 first.

The runtime, meaning Alpine, Apache and PHP, updates by digest. New digests appear at
https://hub.docker.com/r/linkstackorg/linkstack/tags after a release at
https://github.com/LinkStackOrg/LinkStack/releases. Edit the image line in
~/selfhost/linkstack/compose.yml to the new digest, then:

```bash
cd ~/selfhost/linkstack
docker compose pull
docker compose up -d
docker compose logs --tail 20 linkstack
```

That replaces the container and leaves /htdocs alone, because Docker only fills an empty
volume. Re-run step 7's first three commands before calling the update done.

## 10. What will probably go wrong

Docker Desktop, after a reboot. The compose file says `restart: unless-stopped` and I read that
as a promise the container comes back by itself. It does not on macOS or Windows: nothing
returns until Docker Desktop is running, and it starts at sign-in, sometimes only when someone
opens it. I rebooted, opened my own page to show somebody, and got a browser error that reads
exactly like a broken install rather than a stopped daemon. Tell the user to turn on Docker
Desktop's start-at-login, and to run `cd ~/selfhost/linkstack && docker compose up -d` after a
reboot before concluding anything is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not choose MySQL in the setup wizard. SQLite inside the container is what makes this one
  container and one archive; MySQL adds a service this prompt does not install.
- Do not run the in-app updater or the theme updater during this install. Both rewrite files in
  the volume, and step 8 has not run yet.
- Do not rebind 8121 to this machine's network address so a phone can open the page. That puts
  a sign-in form on every network this computer joins.
