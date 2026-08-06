You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install LibreChat v0.8.7, with the MongoDB and Meilisearch it needs, under ~/selfhost/librechat,
answering at http://localhost:8112.

## 1. Preflight

Tell the user both of these before step 2. LibreChat is a chat interface, not a model: it
answers with whatever provider key it is given, metered per token by Anthropic, OpenAI or
Google and billed to them, so light use usually costs less than a subscription and heavy use
can cost more. And it answers at http://localhost:8112, this computer and nowhere else: not
their phone, and not this machine while asleep.

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
distribution ID and codename print next, for step 2. These three containers need 2048 MB of RAM
available and 10 GB free on the home disk; all three images publish amd64 and arm64. On macOS
and Windows that figure is the host's, and Docker Desktop's virtual machine takes its share. If RAM is under 2048 MB or disk under 10 GB, print both and stop. Do not install and
hope.

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
mkdir -p ~/selfhost/librechat/{images,uploads,logs,meili,backups}
if [ "$(uname -s)" = "Linux" ]; then sudo chown -R 1000:1000 ~/selfhost/librechat/{images,uploads,logs}; fi
ls -la ~/selfhost/librechat
```

Assert: `ls -la` shows all five directories. The app image runs as its `node` user, uid 1000,
so on Linux three of them are chowned to that uid; on macOS and Windows Docker Desktop handles
it and the fence does nothing. There is no folder for the database: step 5 keeps it in a
volume Docker manages.

## 4. Secrets

Five secrets, all generated here, none printed. Keep them out of your summary and out of any
log line. `CREDS_KEY` is a 32-byte key and `CREDS_IV` a 16-byte initialisation vector, both
hex; upstream documents that the app crashes without them, and they encrypt every provider key
typed in later.

```bash
umask 077
cat > ~/selfhost/librechat/.env <<EOF
DOMAIN_CLIENT=http://localhost:8112
DOMAIN_SERVER=http://localhost:8112
ALLOW_REGISTRATION=true
CREDS_KEY=$(openssl rand -hex 32)
CREDS_IV=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)
MEILI_MASTER_KEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/librechat/.env
umask 022
ls -l ~/selfhost/librechat/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. On Windows the mode bits are advisory and the real boundary is the
user's own account. `ALLOW_REGISTRATION` is true only until step 7 closes it.

## 5. compose.yml

```bash
cat > ~/selfhost/librechat/compose.yml <<'EOF'
# LibreChat · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://www.librechat.ai/docs/local/docker
#   variable reference . https://www.librechat.ai/docs/configuration/dotenv
#
# Three services. Paths are relative to ~/selfhost/librechat/, so one file works
# on macOS, Linux and Windows. Upstream's RAG API and pgvector database are left
# out: they need an embeddings API key of their own. MongoDB sits in a named
# volume, because the image chowns /data/db to a uid Docker Desktop cannot grant
# on Windows, and runs --noauth as upstream ships it, reachable only from the
# app container. Digests read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mongodb:
    image: mongo:8.0.20@sha256:098862b1339f031900ca66cf8fef799e616d6324fa41b9a263f2ec899552c1ef
    restart: unless-stopped
    command: ["mongod", "--noauth"]
    volumes:
      - librechat-mongo:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 10s
      retries: 24

  meilisearch:
    image: getmeili/meilisearch:v1.35.1@sha256:8b57fc3c7f46535ddef3828df1538465ac19d892eb57c9a10da6df0880bd5856
    restart: unless-stopped
    environment:
      MEILI_MASTER_KEY: ${MEILI_MASTER_KEY}
      MEILI_NO_ANALYTICS: "true"
    volumes:
      - ./meili:/meili_data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:7700/health"]
      interval: 10s
      retries: 24
    # No `ports:`: only the app container queries this index.

  api:
    image: ghcr.io/danny-avila/librechat:v0.8.7@sha256:c5db3331b845e1f289f8d04c0c77936c4bbe372f76730a804abc1c37e44d23a9
    restart: unless-stopped
    env_file: ./.env
    environment:
      HOST: 0.0.0.0
      MONGO_URI: mongodb://mongodb:27017/LibreChat
      MEILI_HOST: http://meilisearch:7700
      SEARCH: "true"
      # No TLS here; browsers trust http://localhost anyway.
      SESSION_COOKIE_SECURE: "false"
      # No mail server, so the flow that needs one is off.
      ALLOW_PASSWORD_RESET: "false"
      # `user_provided`: no credential is stored here. It is asked for in
      # the browser and encrypted with CREDS_KEY.
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-user_provided}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-user_provided}
      GOOGLE_KEY: ${GOOGLE_KEY:-user_provided}
    volumes:
      - ./images:/app/client/public/images
      - ./uploads:/app/uploads
      - ./logs:/app/logs
    ports:
      # Loopback only: no other device on the wifi can reach 8112.
      - "127.0.0.1:8112:3080"
    depends_on:
      mongodb:
        condition: service_healthy
      meilisearch:
        condition: service_healthy

volumes:
  librechat-mongo:
EOF
cd ~/selfhost/librechat && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port, one volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the login cookie still works.
- No firewall rule. Nothing is published past loopback.

8112 is bound to 127.0.0.1, this computer only, and the other two publish no host port at all,
which is what makes running MongoDB unauthenticated reasonable. Confirm it:

```bash
grep -c '127.0.0.1:8112:3080' ~/selfhost/librechat/compose.yml
grep -c '27017:\|7700:' ~/selfhost/librechat/compose.yml
```

Assert: `1`, then `0`.

## 7. Start and verify

The first pull downloads over a gigabyte.

```bash
cd ~/selfhost/librechat
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8112/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8112/health
curl -sS http://localhost:8112/api/config
```

Assert all three and print what you received: the loop ends on `200`, `/health` answers the
literal string `OK`, and `/api/config` returns JSON containing `"appTitle":"LibreChat"` and
`"registrationEnabled":true`. If any misses, stop, run `docker compose logs --tail 40 api` and
name the likely cause: a mongodb that never reports healthy points at step 5, a slow first
start wants more time, and `port is already allocated` means something else holds
8112 (`lsof -nP -iTCP:8112 -sTCP:LISTEN`). A running container is not success.

The first screen at http://localhost:8112 shows the heading `Welcome back` over `Email` and
`Password` fields, a `Sign in` button, and below it `Don't have an account?` with a `Sign up`
link.

STOP: tell the user to open http://localhost:8112, click `Sign up`, create their account, and
wait. Do not continue until they confirm. Upstream documents that the first account becomes the
admin account and that there are no default credentials; with no mail server here, it is the
whole recovery story.

Once they confirm, close registration and restart the app:

```bash
cd ~/selfhost/librechat
sed -i.bak 's/^ALLOW_REGISTRATION=true$/ALLOW_REGISTRATION=false/' .env && rm -f .env.bak
docker compose up -d --force-recreate api
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8112/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8112/api/config
```

Assert: the loop ends on `200`, the config JSON now reads `"registrationEnabled":false`, and the
user reloads in a private window and confirms `Sign up` is gone.

STOP: tell the user to sign in, pick a provider from the model menu, paste their own provider
key into the dialog LibreChat shows, send one message, and wait. Do not report success until
they confirm an answer streamed back. That credential is theirs and billed to them, so never
ask them to paste it to you.

## 8. First backup and restore

Two artifacts. The MongoDB dump holds the accounts, the conversations and the encrypted
provider keys. The config archive holds what rebuilds the service around them, `.env` included:
without `CREDS_KEY` every stored key in the dump is unreadable. The Meilisearch folder is only
an index, rebuilt from MongoDB.

```bash
cd ~/selfhost/librechat
docker compose exec -T mongodb mongodump --archive --gzip --db=LibreChat > backups/librechat-db-$(date +%F).archive.gz
tar -czf backups/librechat-config-$(date +%F).tar.gz compose.yml .env images uploads
ls -lh backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing is stopped, `mongodump` reads
a running database.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy both there with `cp`; in Git Bash a Windows drive is written
`/d/Backups`. Assert: the user confirms both filenames are there.

To restore, in this order: `cd ~/selfhost/librechat`, untar the config archive there first so
compose.yml and .env are back before any container starts, then `docker compose down -v`, the
one place `-v` belongs because it drops the old volume on purpose,
`docker compose up -d mongodb`, wait 30 seconds for healthy, then feed the dump in with
`docker compose exec -T mongodb mongorestore --archive --gzip --drop < backups/librechat-db-$(date +%F).archive.gz`,
then `docker compose up -d`. Sign in and open one old conversation.

## 9. Updating later

New versions are listed at https://github.com/danny-avila/LibreChat/releases. Take both backups
first, then edit the `image:` line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/librechat
docker compose pull
docker compose up -d
docker compose logs --tail 30 api
```

Leave the mongo and Meilisearch tags alone: Meilisearch refuses to open a database written by
another version.

## 10. What will probably go wrong

The machine has plenty of memory and the containers still do not. Docker Desktop runs a virtual
machine with its own memory limit, and mine was set under what three services need, so the app
was killed part way through its first start and came back as a restart loop that looked like a
broken image. Give it 4 GB in Docker Desktop's Resources settings first.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8112 to 0.0.0.0 so a phone can reach it. That puts a login page holding
  provider keys on every network this computer joins.
- Do not add the RAG API or the pgvector database from upstream's compose file. Chatting with
  uploaded documents needs an embeddings credential of its own.
