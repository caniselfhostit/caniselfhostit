This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing LibreChat v0.8.7 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. LibreChat is a chat interface, not a model. It answers with whatever
provider key you give it, and that key is metered per token by Anthropic, OpenAI or Google and
billed to you. There is no subscription and no flat monthly ceiling: light use usually costs
less than a subscription, heavy use can cost more, and the meter is now yours to watch.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that does
not resolve and failed attempts count against a rate limit you cannot see. Under 2048 MB of RAM
is the other common stop: three containers plus a Node application that builds its client
indexes at start-up will be killed by the kernel on a 1 GB box, and the failure reads like a
broken image rather than a small server. The three images together unpack to several gigabytes,
which is what most of the 10 GB floor is for.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/librechat /srv/librechat/backups
sudo install -d -m 700 /srv/librechat/mongo /srv/librechat/meili
sudo install -d -m 750 -o 1000 -g 1000 /srv/librechat/images /srv/librechat/uploads /srv/librechat/logs
ls -la /srv/librechat
```

You should see: `backups` owned by you, `mongo` and `meili` at `drwx------` owned by root, and
`images`, `uploads` and `logs` owned by `1000`.

If you do not: leave `mongo` owned by root on purpose. The mongo image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. The three at uid 1000 are the opposite case: the LibreChat image runs as
its `node` user, which is uid 1000, and a directory it cannot write is a container that exits
while you are still reading the log.

## 3. Secrets

Five secrets, all generated here, on the server, and all written straight into a file only you
can read. `CREDS_KEY` is a 32-byte key and `CREDS_IV` a 16-byte initialisation vector, both in
hex, and upstream documents that the app crashes on start-up without them. They are what
encrypts the provider keys you type into the browser later.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first two lines with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/librechat/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
all five, which is fine before anyone has signed in and a problem afterwards: a changed
`CREDS_KEY` leaves every stored provider key in the database undecryptable, and a changed
`JWT_SECRET` signs everyone out.

Do not paste that file, any of those five values, or any command output containing them into
this chat window. None of them is a provider API key: those you enter in the browser in step 7,
and they should not come near this window either.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/librechat/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/librechat/compose.yml` and paste again in one go. The three `${...:-user_provided}`
lines are not a mistake. `user_provided` tells LibreChat to hold no provider credential at all
and ask each signed-in person for their own in the browser, encrypted with `CREDS_KEY`. If you
would rather run one key for everyone, put the real value in `.env` under the same name and it
wins over the default.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-librechat /etc/caddy/Caddyfile`, reload,
and paste again. There is no `encode` line in that block and there is a `flush_interval -1`,
both on purpose: a model reply arrives as a stream of events, and a proxy that buffers it turns
a live answer into a long pause followed by a wall of text.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8112`, `27017` or `7700`.

If you do not: delete anything for those three with `sudo ufw delete allow 8112`. 8112 is bound
to 127.0.0.1 by the compose file, and 27017 and 7700 are never published, so neither database
has a host port a firewall rule could apply to. That matters more here than usual: this MongoDB
runs without authentication, exactly as upstream ships it, and the only thing keeping that
sensible is that nothing outside the compose network can reach it. `Status: inactive` is a
different problem: Prompt Zero left this firewall enabled, so something has turned it off since,
and `sudo ufw enable` puts it back before you go any further.

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

You should see, in order: the loop reaching `200`, the literal string `OK`, then a JSON object
containing `"appTitle":"LibreChat"` and `"registrationEnabled":true`.

If you do not: run `docker compose logs --tail 20 mongodb` first, because a database that never
reports healthy holds the app back and that is step 2 done wrong, then
`docker compose logs --tail 40 api`. A `502` from Caddy while the loop is still counting is
normal for the first minute; a `502` that never clears means the app container is not listening
on 3080. A running container is not success.

Now open https://<DOMAIN> in a browser. The first screen shows the heading `Welcome back` over
`Email` and `Password` fields, a `Sign in` button, and below it `Don't have an account?` with a
`Sign up` link. Click `Sign up` and create your account. Upstream documents that the first
account you register becomes the admin account and that there are no default credentials, so
this account is the whole install: nothing here sends mail, and there is no reset link behind
it. Put the password in your password manager now.

Then close registration, so the login page stops being a signup page:

```bash
sed -i 's/^ALLOW_REGISTRATION=true$/ALLOW_REGISTRATION=false/' /srv/librechat/.env
cd /srv/librechat && docker compose up -d --force-recreate api
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/config
```

You should see: the loop reaching `200` again, and `"registrationEnabled":false` in the JSON.
Reload https://<DOMAIN> in a private window and confirm the `Sign up` link is gone.

If you do not: `"registrationEnabled":true` still there means the `sed` did not match, usually
because the line had trailing whitespace. Check with `grep ALLOW_REGISTRATION /srv/librechat/.env`
and edit it by hand, then run the recreate again. Leaving this open on a public hostname means
anyone who finds the address can make themselves an account on your instance.

Last, sign in, pick a provider from the model menu, paste your own provider API key into the
dialog LibreChat shows, and send one message. You should see an answer stream back a few words
at a time. That key is yours and billed to your account by the provider, it belongs in the
browser dialog and nowhere else, and it must not be pasted into this chat window.

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

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline;
`mongodump` reads a running database.

If you do not: an archive of about 20 bytes is an empty dump, which means `mongodump` failed and
the shell created the file anyway. It writes its error to stderr, so run the line again and read
what came back before the prompt returned.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/librechat
scp vps:/srv/librechat/backups/* ~/backups/librechat/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/librechat/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one test conversation:

```bash
cd /srv/librechat
docker compose down
sudo rm -rf /srv/librechat/mongo
sudo install -d -m 700 /srv/librechat/mongo
docker compose up -d mongodb
sleep 30
docker compose exec -T mongodb mongorestore --archive --gzip --drop < /srv/librechat/backups/librechat-db-$(date +%F).archive.gz
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/health
```

You should see: `restoring` and `finished restoring` lines from mongorestore, then `OK` from the
last command. Sign in with the same password and open the conversation you sent in step 7.

If you do not: `Failed: no reachable servers` means the database container had not finished
starting, so wait longer and run the `mongorestore` line again. If you can reach the login page but
your password no longer works, the `.env` you restored is not the one the dump was taken with,
and that is the failure this step exists to find while it is still cheap.

## 9. Updating later

New versions are listed at https://github.com/danny-avila/LibreChat/releases. Upstream marks
every release as a prerelease there, so release candidates sit in the same list: skip any tag
with `-rc` in it. Take both backup artifacts first, then edit the `image:` line in
/srv/librechat/compose.yml to the new tag and its digest.

```bash
cd /srv/librechat
docker compose pull
docker compose up -d
docker compose logs --tail 30 api
```

You should see: the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Leave the mongo
and Meilisearch tags alone unless a release note says otherwise. Meilisearch refuses to open a
database written by another version and wants a dump and reimport, and MongoDB major versions
want their own upgrade path, so moving either of those is a separate evening.

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
  own session secret, and this install gives you the chat server.
- Do not write a librechat.yaml. The three provider endpoints are set in compose.yml.
