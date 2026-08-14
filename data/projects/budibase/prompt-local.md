You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Budibase 3.41.3 under ~/selfhost/budibase, answering at http://localhost:8187.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Budibase builds internal tools for other people to use, and the only address those tools have
here is http://localhost:8187, which means "this computer" wherever it is read. The user gets
the builder and the tables; the colleague they meant to hand a form to does not.

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
distribution ID and codename print next, for step 2. Budibase needs 6144 MB of RAM available and
20 GB free on the home disk; the image publishes amd64 and arm64. The floor is upstream's own
figure, and one container runs CouchDB, the Clouseau search indexer, a Structured Query Server,
Redis, MinIO, an internal PostgreSQL and a LiteLLM proxy alongside the server and worker. On macOS and
Windows the number printed is the host's and Docker Desktop takes its allocation out of that, so
a 16 GB laptop capped at 4 GB will not run this. Under 6144 MB or 20 GB free, print both and
stop.

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
mkdir -p ~/selfhost/budibase/backups
ls -la ~/selfhost/budibase
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder on purpose: step
5 keeps the instance's directory in a named Docker volume, because the start-up script chowns
CouchDB's and PostgreSQL's directories to uids Windows file sharing cannot grant.

## 4. Secrets

Four secrets, generated here. Print none of them, and keep them out of your summary and your
logs. Hex rather than base64: a human types one into a login form.

STOP: ask the user which email address they want to sign in with, and wait.
Do not continue until they answer. Take it in lowercase. That address becomes the administrator,
created from this file during the first boot, so the setup form is never open to anyone.

Write the file below with that address in place of `you@example.com`:

```bash
umask 077
cat > ~/selfhost/budibase/.env <<EOF
BB_ADMIN_USER_EMAIL=you@example.com
PLATFORM_URL=http://localhost:8187
BB_ADMIN_USER_PASSWORD=$(openssl rand -hex 24)
COUCHDB_PASSWORD=$(openssl rand -hex 32)
INTERNAL_API_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/budibase/.env
umask 022
ls -l ~/selfhost/budibase/.env
```

Assert: the file exists with mode `-rw-------`, and the first line carries the address the user
gave rather than the example one. Git Bash ships openssl, so these lines run the same on all
three systems. `COUCHDB_PASSWORD` matters most: the base image bakes that credential in as the
literal word `admin`, and the start-up script leaves it alone because it is not empty.
`JWT_SECRET` signs session cookies and, with `API_ENCRYPTION_KEY` unset on this shape, is also
the key the platform encrypts stored API keys with. Tell the user to read their password with
`grep BB_ADMIN_USER_PASSWORD ~/selfhost/budibase/.env`, keep it in their password manager, and
keep the file: compose will not start without it, and step 8 copies it off this machine.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/budibase/compose.yml <<'EOF'
# Budibase · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ... https://docs.budibase.com/docs/docker
#   start-up script .. https://github.com/Budibase/budibase/blob/3.41.3/hosting/single/runner.sh
#
# One crowded service: upstream's all-in-one image runs CouchDB, Clouseau, a
# Structured Query Server, Redis, MinIO, an internal PostgreSQL and a LiteLLM
# proxy alongside the Budibase server and worker, which is where the 6 GB
# floor comes from. /data is a named volume, not a relative bind mount: the
# start-up script chowns its CouchDB and PostgreSQL directories to uids of its
# own choosing, and Windows file sharing cannot grant that on a home folder.
# ./backups stays a real folder. Digest read on 2026-08-12; amd64, arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  budibase:
    image: budibase/budibase:3.41.3@sha256:f05b90c2b8afc951feb99931bb4646d2c94af37d9c576ef3c4e01d4fdc296dc1
    container_name: budibase
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Upstream ships product analytics on for self-hosted instances. The
      # string "0" is the off switch: backend-core coerces "0" and "false"
      # to a disabled value before anything reads it.
      ENABLE_ANALYTICS: "0"
    volumes:
      - budibase-data:/data
      - ./backups:/backup
    ports:
      # Loopback only: no other device on the wifi can reach 8187.
      - "127.0.0.1:8187:80"

volumes:
  budibase-data:
EOF
cd ~/selfhost/budibase && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS, because there is no hostname to resolve.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the builder still works.
- No firewall rule. Nothing is published beyond loopback, so nothing needs closing.

8187 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop
on the same wifi, nor anyone on the internet. For a tool whose apps are meant for other people,
that is the trade here. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/budibase/compose.yml
```

Assert: that prints `1`. CouchDB, Redis, MinIO, PostgreSQL and LiteLLM are never published at
all, and step 4 replaced the CouchDB credential rather than trust the binding alone.

## 7. Start and verify

The first boot is slow and meant to be: over a gigabyte to pull, then CouchDB's system
databases, PostgreSQL's `initdb` and LiteLLM's migrations before the server and worker start.
Fifteen minutes on a laptop sharing its cores is normal.

```bash
cd ~/selfhost/budibase
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8187/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8187/api/system/status
curl -sS http://localhost:8187/api/global/configs/checklist | grep -o '"adminUser":{"checked":[a-z]*'
docker compose exec -T budibase curl -sS -o /dev/null -w '%{http_code}\n' -u admin:admin http://127.0.0.1:5984/_all_dbs
docker compose exec -T budibase sh -c 'chmod 600 /data/.env && stat -c %a /data/.env'
```

Assert, all five, and print what you received for each. The loop ends printing `200`. The status
response contains `"version":"3.41.3"`, the running build agreeing with the pinned tag. The
checklist prints `"adminUser":{"checked":true`, so the administrator came from step 4, not from
whoever opened the page first. The fourth prints `401`, so the CouchDB credential the base
image bakes in is dead. The last prints `600`: the container writes that file with its own
umask, and CouchDB and PostgreSQL run in there as uids of their own.

If any of the five misses, stop, run `docker compose logs --tail 80 budibase`, and name the
likely cause: a container restarting in a loop is usually Docker Desktop's memory cap, and `port
is already allocated` means something else holds 8187 (`lsof -nP -iTCP:8187 -sTCP:LISTEN`, or
`netstat -ano | findstr :8187` on Windows). On `"adminUser":{"checked":false`, do not create an
account by hand. Reset: `docker compose down -v`, check step 4's `.env` still carries both
`BB_ADMIN_USER_` lines, then `docker compose up -d` and repeat. A running container is not
success.

The first screen is the sign-in form, headed `Log in to Budibase`, not the `Create an admin
user` screen. That difference is what step 4 buys.

STOP: tell the user to read their password with
`grep BB_ADMIN_USER_PASSWORD ~/selfhost/budibase/.env`, sign in at http://localhost:8187 with
the address they gave, change the password in their account settings, and wait.
Do not continue until they confirm they are signed in. There is no mail here, so no reset
link.

## 8. First backup and restore

One archive, with the container stopped, because a tar of a live CouchDB is not a backup. It
runs inside a throwaway container so the uids CouchDB and PostgreSQL own their files as
survive:

```bash
cd ~/selfhost/budibase
docker compose stop
docker run --rm --volumes-from budibase --entrypoint sh budibase/budibase:3.41.3@sha256:f05b90c2b8afc951feb99931bb4646d2c94af37d9c576ef3c4e01d4fdc296dc1 -c "tar -czf /backup/budibase-$(date +%F).tar.gz -C / data"
docker compose start
ls -lh ~/selfhost/budibase/backups/
```

Assert: the archive exists and is non-empty. Print its size. The stop and start cost several
minutes while the container brings every engine back up. Upstream sells in-product workspace
backups as a licensed feature, so this file is it.

That archive sits on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination off this computer, a folder their sync service watches
or a USB stick, and copy it there with `cp`, together with `~/selfhost/budibase/.env`: data
restored beside a fresh `JWT_SECRET` cannot decrypt what the old one encrypted. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms both files
are there. If they have neither, say plainly that this install has no backup.

To restore, in order. `cd ~/selfhost/budibase`, put `.env` and `compose.yml` back if they
are missing, then `docker compose down -v`, which drops the old volume on purpose, then
`docker compose create`, which makes an empty one. Then the same `docker run` line with
`tar -xzf` and the archive's filename in place of `tar -czf` and the date, still with `-C /`.
Then `docker compose up -d` and re-run step 7. That is the plan.

## 9. Updating later

New versions are listed at https://github.com/Budibase/budibase/releases. 3.41.3 was the newest
stable release the day this was pinned. Take step 8's backup first, then edit the image line in
~/selfhost/budibase/compose.yml:

```bash
cd ~/selfhost/budibase
docker compose pull
docker compose up -d
docker compose logs --tail 60 budibase
```

Budibase migrates its own databases on the way up: watch that log until it settles, then re-run
step 7 before calling the update done.

## 10. What will probably go wrong

Docker Desktop's memory cap. I gave this a laptop with 16 GB and watched the container restart
in a loop for twenty minutes, hunting a mistake that was not there. Docker Desktop was handing
its virtual machine 4 GB, and the pile of processes in this image does not fit in 4 GB. The
number step 1 printed was the laptop's, not Docker's. Open Docker Desktop, Settings, Resources,
give it 6 GB or more, apply, restart, then run step 7 again.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8187 to 0.0.0.0 so a colleague on the wifi can open an app. That publishes the
  builder, its CouchDB at `/db/`, and every datasource credential it holds, onto every network
  this machine joins.
- Do not configure SMTP, and do not set `CUSTOM_DOMAIN`: it runs certbot for a name that does
  not exist here.
