You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install LibreChat v0.8.7 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say this to the user first. LibreChat is a chat interface, not a model. It answers with
whatever provider key it is given, and that key is metered per token by Anthropic, OpenAI or
Google and billed to the user. There is no subscription and no flat monthly ceiling.

LibreChat with MongoDB and Meilisearch needs 2048 MB of RAM available and 10 GB free on /srv.
All three images publish amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope: the app image alone unpacks to over a gigabyte. If `dig +short`
prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/librechat /srv/librechat/backups
sudo install -d -m 700 /srv/librechat/mongo /srv/librechat/meili
sudo install -d -m 750 -o 1000 -g 1000 /srv/librechat/images /srv/librechat/uploads /srv/librechat/logs
ls -la /srv/librechat
```

Assert: `ls -la` shows `backups` owned by the login user, `mongo` and `meili` at mode `700`
owned by root, and `images`, `uploads` and `logs` owned by uid `1000`. Three owners on purpose:
the mongo image chowns its data directory on first start, Meilisearch runs as root in its
container, and the LibreChat image runs as `node`, which is uid 1000.

## 3. Secrets

Five secrets, all generated here, none printed. Do not repeat them in your summary or in a log
line. `CREDS_KEY` is a 32-byte key and `CREDS_IV` a 16-byte initialisation vector, both
hex; upstream documents that the app crashes on start-up without them. They encrypt every
provider key typed into the browser later.

```bash
umask 077
cat > /srv/librechat/.env <<EOF
DOMAIN_CLIENT=https://<DOMAIN>
DOMAIN_SERVER=https://<DOMAIN>
ALLOW_REGISTRATION=true
CREDS_KEY=$(openssl rand -hex 32)
CREDS_IV=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)
MEILI_MASTER_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/librechat/.env
umask 022
ls -l /srv/librechat/.env
```

Assert: the file exists with mode `-rw-------`, with `<DOMAIN>` on the first two lines replaced
by the real hostname. `ALLOW_REGISTRATION` is true only until step 7 closes it. None of these
five is a provider key: the user supplies those in the browser.

## 4. compose.yml

```bash
cat > /srv/librechat/compose.yml <<'EOF'
# LibreChat · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://www.librechat.ai/docs/local/docker
#   variable reference . https://www.librechat.ai/docs/configuration/dotenv
#   reverse proxy ...... https://www.librechat.ai/docs/remote/nginx
#
# Three services: the app, the MongoDB holding accounts and conversations, and
# the Meilisearch that makes those conversations searchable. Upstream's compose
# file adds a RAG API and a pgvector database for chatting with uploaded
# documents; both are left out, because they need an embeddings API key of
# their own and would make this a five-container stack.
#
# MongoDB runs with --noauth, as upstream ships it. That is safe here only
# because it publishes no port: the app container on this private network is
# the one thing that can reach 27017. Digests read 2026-08-06, all multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mongodb:
    image: mongo:8.0.20@sha256:098862b1339f031900ca66cf8fef799e616d6324fa41b9a263f2ec899552c1ef
    restart: unless-stopped
    command: ["mongod", "--noauth"]
    volumes:
      - /srv/librechat/mongo:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 10s
      retries: 24
    # No `ports:`: 27017 never leaves the compose network.

  meilisearch:
    image: getmeili/meilisearch:v1.35.1@sha256:8b57fc3c7f46535ddef3828df1538465ac19d892eb57c9a10da6df0880bd5856
    restart: unless-stopped
    environment:
      MEILI_MASTER_KEY: ${MEILI_MASTER_KEY}
      MEILI_NO_ANALYTICS: "true"
    volumes:
      - /srv/librechat/meili:/meili_data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:7700/health"]
      interval: 10s
      retries: 24
    # No `ports:` either: only the app queries this index.

  api:
    image: ghcr.io/danny-avila/librechat:v0.8.7@sha256:c5db3331b845e1f289f8d04c0c77936c4bbe372f76730a804abc1c37e44d23a9
    restart: unless-stopped
    env_file: /srv/librechat/.env
    environment:
      HOST: 0.0.0.0
      MONGO_URI: mongodb://mongodb:27017/LibreChat
      MEILI_HOST: http://meilisearch:7700
      SEARCH: "true"
      # Caddy terminates TLS and is the only hop in front of this container.
      TRUST_PROXY: "1"
      # No mail server here, so the flow that needs one is off.
      ALLOW_PASSWORD_RESET: "false"
      # Keep this out of search engine results.
      NO_INDEX: "true"
      # `user_provided`: no credential is stored here. LibreChat asks each
      # signed-in person for theirs in the browser and encrypts it with
      # CREDS_KEY.
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-user_provided}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-user_provided}
      GOOGLE_KEY: ${GOOGLE_KEY:-user_provided}
    volumes:
      - /srv/librechat/images:/app/client/public/images
      - /srv/librechat/uploads:/app/uploads
      - /srv/librechat/logs:/app/logs
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8112.
      - "127.0.0.1:8112:3080"
    depends_on:
      mongodb:
        condition: service_healthy
      meilisearch:
        condition: service_healthy
EOF
cd /srv/librechat && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The app reads the five secrets through `env_file` and
Meilisearch reads the master key by substitution from the same file, so both agree on it
without it appearing here.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-librechat
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# LibreChat · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.librechat.ai/docs/remote/nginx and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also DOMAIN_CLIENT and DOMAIN_SERVER in .env; change it in one place and the
# login cookie stops matching the address the browser is on.

<DOMAIN> {
	# Model replies arrive as a stream of events, one piece at a time.
	# Nothing here compresses or holds that stream: hence no `encode`
	# line, and a proxy that flushes every write.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8112 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8112 {
		flush_interval -1
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-librechat, reload, and report what it objected to. Caddy requests
the certificate on first request and renews it on its own. Nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8112 is bound to 127.0.0.1, and 27017 and 7700 are never published at all: an
unauthenticated MongoDB reachable from the internet is how self-hosted installs end up in a
breach list. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and nothing for 8112, 27017 or 7700.

## 7. Start and verify

The first pull downloads more than a gigabyte, and the app takes about a minute after that
before it answers.

```bash
cd /srv/librechat
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/api/config
```

Assert all three and print what you received for each: the loop ends on `200`, `/health`
answers the literal string `OK`, and `/api/config` returns JSON containing
`"appTitle":"LibreChat"` and `"registrationEnabled":true`. If any misses, stop, run
`docker compose logs --tail 40 api` and `docker compose logs --tail 20 mongodb`, and name the
likely cause: a mongodb container that never reports healthy points at step 2, and a `502`
means the app is still starting. A running container is not success.

The first screen at https://<DOMAIN> shows the heading `Welcome back` over `Email` and
`Password` fields, a `Sign in` button, and below it `Don't have an account?` with a `Sign up`
link.

STOP: tell the user to open https://<DOMAIN>, click `Sign up`, create their account, and wait.
Do not continue until they confirm. Upstream documents that the first account registered becomes
the admin account and that there are no default credentials. With no mail server here, that
account is the whole recovery story.

Once they confirm, close registration and restart the app:

```bash
sed -i 's/^ALLOW_REGISTRATION=true$/ALLOW_REGISTRATION=false/' /srv/librechat/.env
cd /srv/librechat && docker compose up -d --force-recreate api
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/config
```

Assert: the loop ends on `200` and the config JSON now reads `"registrationEnabled":false`, and
the user reloads https://<DOMAIN> in a private window and confirms the `Sign up` link is gone.
Both must pass before you go on.

STOP: tell the user to sign in, pick a provider from the model menu, paste their own provider
key into the dialog LibreChat shows, send one message, and wait. Do not report success until
they confirm an answer streamed back. That credential is theirs and billed to their account;
never ask them to paste it to you.

## 8. First backup and restore

Two artifacts. The MongoDB dump holds the accounts, the conversations and the encrypted
provider keys. The config archive holds what rebuilds the service around them, `.env` included:
without `CREDS_KEY` every stored key in the dump is unreadable. The Meilisearch directory is
not backed up, because it is an index rebuilt from MongoDB.

```bash
cd /srv/librechat
docker compose exec -T mongodb mongodump --archive --gzip --db=LibreChat > /srv/librechat/backups/librechat-db-$(date +%F).archive.gz
sudo tar -czf /srv/librechat/backups/librechat-config-$(date +%F).tar.gz -C /srv/librechat compose.yml .env images uploads -C /etc/caddy Caddyfile
ls -lh /srv/librechat/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped,
`mongodump` reads a running database. A backup on the same disk is not a backup, so run this
from the user's machine:

```bash
mkdir -p ~/backups/librechat
scp vps:/srv/librechat/backups/* ~/backups/librechat/
```

To restore: `docker compose down`, untar the config archive back into /srv/librechat so `.env`
is in place first, `docker compose up -d mongodb`, wait for it to report healthy, then feed the
dump in with
`docker compose exec -T mongodb mongorestore --archive --gzip --drop < backups/librechat-db-$(date +%F).archive.gz`,
then `docker compose up -d`. Tell the user that is the whole disaster plan, and that a dump restored
without its matching `.env` comes back unreadable.

## 9. Updating later

New versions are listed at https://github.com/danny-avila/LibreChat/releases. Upstream marks
every release as a prerelease there, so release candidates sit in the same list: skip any tag
with `-rc` in it. Take both backups first, then edit the `image:` line in
/srv/librechat/compose.yml to the new tag and digest:

```bash
cd /srv/librechat
docker compose pull
docker compose up -d
docker compose logs --tail 30 api
```

Leave the mongo and Meilisearch tags alone unless a release note says otherwise. Meilisearch
refuses to open a database written by another version and wants a dump and reimport; MongoDB
major versions want their own upgrade path. Re-run step 7's health check before calling it
done.

## 10. What will probably go wrong

The install will look finished and broken at the same time. I signed in, typed a message, and
got a red error with nothing useful in it, because this server holds no provider credential and
I had not given it one. Nothing was wrong: `user_provided` means LibreChat waits for one from
the browser, and until it arrives there is no model on the other end. Give it a key before you
conclude anything.

## 11. Out of scope

- Do not configure SMTP. Password reset is off and nothing here sends mail, so the first
  account is the whole recovery story.
- Do not add the RAG API or the pgvector database from upstream's compose file. Chatting with
  uploaded documents needs an embeddings credential billed separately, and two more containers.
- Do not run the bundled admin panel. It is a second web application on its own port with its
  own session secret, and this prompt installs the chat server.
- Do not write a librechat.yaml. The three provider endpoints are set in compose.yml.
