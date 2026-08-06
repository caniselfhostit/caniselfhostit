You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install WeKan v10.71, with the MongoDB 7 it keeps every board in, under ~/selfhost/wekan,
answering at http://localhost:8104.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. WeKan is a shared board by design, and this one answers only at http://localhost:8104: not
a colleague, not their phone, not them while the machine sleeps.

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
distribution ID and codename print next, for step 2. WeKan plus MongoDB needs 2048 MB of RAM
available and 10 GB free on the home disk, and both images publish amd64 and arm64. If either
floor is missed, print both numbers and stop. Do not install and hope. One hardware rule from
upstream: MongoDB 7 needs AVX on x86 and ARMv8.2-A on arm, which every Mac and PC of the last
decade has and a Raspberry Pi 4 does not.

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
mkdir -p ~/selfhost/wekan/backups
ls -la ~/selfhost/wekan
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: both data
directories are named volumes Docker manages, on all three systems.

## 4. Secrets

This install generates no secrets and writes no `.env` file, so there is nothing here to keep
out of your summary. WeKan has no admin token, and its only credential is the first account,
made in a browser in step 7. MongoDB runs with no password: it publishes no host port and only
the WeKan container reaches it.

## 5. compose.yml

```bash
cat > ~/selfhost/wekan/compose.yml <<'EOF'
# WeKan · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   mongodb compose .... https://github.com/wekan/wekan/blob/v10.71/docker-compose-mongodb-v7.yml
#   root url and proxy . https://github.com/wekan/wekan/blob/v10.71/docs/Webserver/Settings.md
#   oplog reactivity ... https://github.com/wekan/wekan/blob/v10.71/docs/Databases/MongoDB/Oplog-Configuration.md
#   image and port ..... https://github.com/wekan/wekan/blob/v10.71/Dockerfile
#
# Two services on the computer you are sitting at. This file lives in
# ~/selfhost/wekan/ and names no absolute path, so it works the same on macOS,
# Linux and Windows. Both data directories are named volumes rather than binds,
# because MongoDB and the WeKan image each chown their own directory to a uid
# Docker Desktop cannot grant on a home-directory bind mount. ROOT_URL sits in
# here, not in a .env file, because here it is neither secret nor a choice.
# Digests read on 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  wekandb:
    image: mongo:7.0.39@sha256:35a5926f71f8b6cb19206bee928c5a85f241a8be99f20c81abe35ae78a73415d
    container_name: wekan-db
    restart: unless-stopped
    # A one-member replica set, which is what makes the oplog exist. Meteor
    # tails it instead of re-reading whole collections on a timer, which
    # upstream measures as 50 ms rather than 2000 ms before a change shows up
    # in a second browser tab. Step 7 initiates the set once.
    command: ["mongod", "--replSet", "rs0", "--bind_ip_all", "--quiet"]
    volumes:
      - wekan-db:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "try { quit(db.hello().isWritablePrimary ? 0 : 1) } catch (e) { quit(1) }"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 30s
    # No `ports:` at all: 27017 is reachable only from the other container.

  wekan:
    image: wekanteam/wekan:v10.71@sha256:5ccfd900c9b68fd9ebd9eb194d286119fdee000ba1e907df583ce942bad54fdc
    container_name: wekan-app
    restart: unless-stopped
    environment:
      # The image can also start a FerretDB it carries; naming the backend
      # takes that away from the entrypoint.
      WEKAN_DB: mongodb
      MONGO_URL: mongodb://wekandb:27017/wekan
      MONGO_OPLOG_URL: mongodb://wekandb:27017/local?replicaSet=rs0
      METEOR_REACTIVITY_ORDER: changeStreams,oplog,polling
      # SockJS rather than uws, upstream's own default, and the reason there
      # is a plain /sockjs/info endpoint for step 7 to check.
      DDP_TRANSPORT: sockjs
      # Attachments and avatars are files under this path, not database rows.
      WRITABLE_PATH: /data
      WITH_API: "true"
      ROOT_URL: http://localhost:8104
    volumes:
      - wekan-files:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8104.
      - "127.0.0.1:8104:8080"
    depends_on:
      wekandb:
        condition: service_healthy

volumes:
  wekan-db:
  wekan-files:
EOF
cd ~/selfhost/wekan && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, two volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one, and browsers treat
http://localhost as a secure context anyway. Nothing is published past loopback, so no port
needs closing.

8104 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/wekan/compose.yml
```

Assert: one line, `- "127.0.0.1:8104:8080"`. MongoDB publishes no host port, so 27017 cannot
appear.

## 7. Start and verify

MongoDB stays unhealthy until its one-member replica set is initiated, which is what creates the
oplog Meteor tails.

```bash
cd ~/selfhost/wekan
docker compose pull
docker compose up -d wekandb
for i in $(seq 1 20); do docker compose exec -T wekandb mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1 && break; sleep 5; done
docker compose exec -T wekandb mongosh --quiet --eval 'try { rs.status().ok } catch (e) { rs.initiate({_id: "rs0", members: [{_id: 0, host: "wekandb:27017"}]}).ok }'
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8104/sign-in); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8104/sign-in | grep -o '<title>Wekan</title>'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8104/sockjs/info
```

Assert all four, and print what you received for each: the mongosh line prints `1`, the loop
ends printing `200`, the grep prints `<title>Wekan</title>`, which WeKan writes into every page,
and `/sockjs/info` prints `200`, the live data socket's own endpoint answering. If any misses,
stop, run `docker compose logs --tail 40 wekan` and `docker compose logs --tail 20 wekandb`, and
name the cause: a database that never reports healthy points at the replica-set line above, and
a WeKan log still in schema migrations wants more time. If `port is already allocated` came
back, find what holds 8104 with `lsof -nP -iTCP:8104 -sTCP:LISTEN` and stop until the user frees
it, because 8104 is inside ROOT_URL. A running container is not success.

The first screen at http://localhost:8104/sign-in is a form headed `Sign In`, with username and
password fields and a link to register. Upstream states the first registered user becomes the
administrator, so the next step is a hard stop.

STOP: tell the user to open http://localhost:8104/sign-up now, register their username, email
address and password, and confirm once they are signed in. Do not continue until they confirm.
Tell them an `Internal Server Error` there is upstream's documented answer when no mail server
is set: the account is made anyway.

Close registration now:

```bash
cd ~/selfhost/wekan
printf 'db.settings.updateOne({}, {$set: {disableRegistration: true, modifiedAt: new Date()}});\n' | docker compose exec -T wekandb mongosh --quiet wekan
docker compose restart wekan
sleep 30
printf 'print(db.settings.findOne({}).disableRegistration);\n' | docker compose exec -T wekandb mongosh --quiet wekan
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8104/sign-in
```

Assert: the second mongosh line prints `true` and the curl prints `200`. The setting is enforced
server-side, not in the page. Then have the user reload the sign-in page and confirm the
register link is gone.

## 8. First backup and restore

Three artifacts: boards, attachments and configuration live in three places.

```bash
cd ~/selfhost/wekan
docker compose exec -T wekandb mongodump --quiet --archive --gzip --db=wekan > backups/wekan-db-$(date +%F).archive.gz
docker compose exec -T wekan tar -C /data -czf - . > backups/wekan-files-$(date +%F).tar.gz
tar -C ~/selfhost/wekan -czf backups/wekan-config-$(date +%F).tar.gz compose.yml
ls -lh ~/selfhost/wekan/backups/
```

Assert: all three exist and none is empty. Print all three sizes. Nothing goes offline:
`mongodump` reads a running database consistently.

All three sit on the same disk as the data, which is not a backup, and on a laptop the disk and
the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy all three there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms all three
filenames are there. If they have no destination, say plainly that this install has no backup.

To restore, in this order. Untar the config archive so compose.yml is back, then
`docker compose down -v`, the one place `-v` belongs because it drops the old volumes on
purpose. Then `docker compose up -d wekandb`, wait 30 seconds, re-run the replica-set line from
step 7, feed the `.archive.gz` into
`docker compose exec -T wekandb mongorestore --archive --gzip --drop`, `docker compose up -d`,
then the files tarball into `docker compose exec -T wekan tar -C /data -xzf -`. Open a board and
check a card.

## 9. Updating later

New versions are listed at https://github.com/wekan/wekan/releases. WeKan often ships several
releases in one day, so read that page as a list, not a queue. Take all three backups first,
then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/wekan
docker compose pull
docker compose up -d
docker compose logs --tail 30 wekan
```

WeKan runs its own schema migrations on the way up, so watch that log until it settles, then
re-run step 7's asserts. Leave the MongoDB line alone.

## 10. What will probably go wrong

I closed the lid on a Friday with a board open, opened it on Monday, and got a spinner that
never resolved. A sleeping machine suspends the containers with it, and after a reboot Docker
Desktop had not started with the session, so nothing was listening on 8104 at all.
`restart: unless-stopped` acts only once the Docker daemon is up. Turn on Docker
Desktop's start-at-login setting, and after a reboot run `docker compose up -d` from
~/selfhost/wekan before concluding anything is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change ROOT_URL to this machine's LAN address and do not rebind 8104 to 0.0.0.0 so a
  phone can reach it. That puts a board with a sign-in page on every network the user joins.
- Do not configure `MAIL_URL` or `MAIL_FROM`. Upstream states a working email server is not
  required, and a laptop is a poor place to send mail from.
