This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Postiz 2.23.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A
record already points at the box.

Read this before step 1. `<DOMAIN>` is the host inside every OAuth redirect URI you will
register at X, Meta, LinkedIn and every other network you connect. Each of those apps is
registered by hand in that company's developer portal, several of them are reviewed by a
person and take days, and changing your hostname afterwards means editing every one of them
again. Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a
hostname that does not resolve. On memory, believe the number rather than the plan you
bought: this stack is five containers, upstream tested its own compose file on a 2 GB
machine and then said to plan for 4 GB or more once PostgreSQL, Redis and the workflow
engine share a host, which is exactly what you are about to do. A 2 GB box will start and
then die during the first migration, and a box sold as 4 GB usually shows less than
4096 MB available once the OS takes its share, so it fails this gate too: 8 GB is the size
that clears it.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/postiz /srv/postiz/backups /srv/postiz/config /srv/postiz/uploads
sudo install -d -m 700 /srv/postiz/postgres /srv/postiz/temporal-postgres /srv/postiz/redis
ls -la /srv/postiz
```

You should see: six directories. `backups`, `config` and `uploads` owned by you, and
`postgres`, `temporal-postgres` and `redis` at mode `drwx------` owned by root.

If you do not: leave the last three owned by root on purpose. Both PostgreSQL images and
the Redis image chown their own data directory the first time they start, and one you have
already chowned to yourself makes PostgreSQL refuse to initialise.

## 3. Secrets

Three secrets: a password for each of the two PostgreSQL services, and the key that signs
your session tokens. All three are generated here, on the server, straight into a file only
you can read.

```bash
umask 077
cat > /srv/postiz/.env <<EOF
POSTIZ_DOMAIN=<DOMAIN>
POSTIZ_DB_PASSWORD=$(openssl rand -hex 32)
TEMPORAL_DB_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 48)
EOF
chmod 600 /srv/postiz/.env
umask 022
ls -l /srv/postiz/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>`
on the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens
if you pasted the lines separately in different shells. Run `chmod 600 /srv/postiz/.env` and
carry on. If the file already existed from an earlier attempt, this block has now
overwritten all three values, which is fine before the databases exist and a problem
afterwards: a PostgreSQL volume keeps the password it was created with, so a changed
password against an existing volume shows up as an authentication failure in the Postiz log
rather than as anything about passwords.

Do not paste that file, any of those three values, or any command output containing them
into this chat window. This is the one rule the agent path never has to think about and
this path does: the values are on your server, and a chat window is somebody else's
computer.

Docker Compose reads this file from the working directory, so run every command from here
on with /srv/postiz as your working directory. It is also the file the social-network keys
go into later.

## 4. compose.yml

Paste the whole block at once, including the last two lines. Five services: Postiz, its
PostgreSQL, its Redis, the Temporal server, and the PostgreSQL Temporal keeps its workflow
history in.

```bash
cat > /srv/postiz/compose.yml <<'EOF'
# Postiz · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose install ....... https://docs.postiz.com/installation/docker-compose
#   variable reference .... https://docs.postiz.com/configuration/reference
#   system requirements ... https://docs.postiz.com/installation/system-requirements
#   temporal, sql only .... https://github.com/temporalio/docker-compose/blob/main/docker-compose-postgres.yml
#
# Five services. Postiz runs its frontend, backend and orchestrator in one
# container behind an nginx on port 5000. Upstream has required Temporal since
# v2.12.0, and Temporal keeps workflow history in its own database, so the two
# PostgreSQL services differ: the first holds your posts, the second holds
# state you can throw away. Upstream also ships Elasticsearch, a Temporal web
# UI and admin-tools; Temporal's own PostgreSQL-only compose has none of them,
# so neither does this. Digests read 2026-08-06; all four are amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: postiz

services:
  postiz-postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_DB: postiz
      POSTGRES_USER: postiz
      POSTGRES_PASSWORD: ${POSTIZ_DB_PASSWORD}
    volumes:
      - /srv/postiz/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postiz -d postiz"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other containers.

  postiz-redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/postiz/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  temporal-postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_USER: temporal
      POSTGRES_PASSWORD: ${TEMPORAL_DB_PASSWORD}
    volumes:
      - /srv/postiz/temporal-postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U temporal"]
      interval: 10s
      retries: 12

  temporal:
    image: temporalio/auto-setup:1.28.1@sha256:607d68caa111338d754771efb876c92dfcdae06d056e4530bb31cd0f37406e6a
    restart: unless-stopped
    environment:
      # postgres12 names the driver, not a version floor.
      DB: postgres12
      DB_PORT: "5432"
      POSTGRES_USER: temporal
      POSTGRES_PWD: ${TEMPORAL_DB_PASSWORD}
      POSTGRES_SEEDS: temporal-postgres
    # No dynamic-config mount: the image ships its own, and Postiz overrides
    # nothing in it.
    healthcheck:
      test: ["CMD", "temporal", "operator", "cluster", "health", "--address", "temporal:7233"]
      interval: 10s
      retries: 30
    depends_on:
      temporal-postgres:
        condition: service_healthy

  postiz:
    image: ghcr.io/gitroomhq/postiz-app:v2.23.0@sha256:785f97312f66a347fb96cdccc4ded5a33ced69a672c89a9adc8054e7d6a21dc5
    restart: unless-stopped
    environment:
      # /api because the container's nginx routes /api/ to the backend.
      FRONTEND_URL: "https://${POSTIZ_DOMAIN}"
      NEXT_PUBLIC_BACKEND_URL: "https://${POSTIZ_DOMAIN}/api"
      BACKEND_INTERNAL_URL: "http://localhost:3000"
      DATABASE_URL: "postgresql://postiz:${POSTIZ_DB_PASSWORD}@postiz-postgres:5432/postiz"
      REDIS_URL: "redis://postiz-redis:6379"
      JWT_SECRET: ${JWT_SECRET}
      TEMPORAL_ADDRESS: "temporal:7233"
      # RUN_CRON registers the workflows that post on a schedule.
      IS_GENERAL: "true"
      RUN_CRON: "true"
      # One signup while the database is empty, then the page shuts.
      DISABLE_REGISTRATION: "true"
      STORAGE_PROVIDER: "local"
      UPLOAD_DIRECTORY: "/uploads"
      NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY: "/uploads"
    volumes:
      - /srv/postiz/config:/config
      - /srv/postiz/uploads:/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8111.
      - "127.0.0.1:8111:5000"
    depends_on:
      postiz-postgres:
        condition: service_healthy
      postiz-redis:
        condition: service_healthy
      temporal:
        condition: service_healthy
EOF
cd /srv/postiz && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `variable is not set` means step 3 did not write .env into /srv/postiz, or
you are in a different directory. `services must be a mapping` means the indentation was
lost between the page and your terminal: run `rm /srv/postiz/compose.yml` and paste again
in one go. Upstream's own compose file also runs Elasticsearch, a Temporal web interface
and an interactive admin-tools container. This one runs none of the three, because
Temporal publishes a PostgreSQL-only compose file without them and three fewer containers
on a 4 GB box is the difference between comfortable and not.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>`
in the block with your hostname before you paste. The first line takes a copy, because a
syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-postiz
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Postiz · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://docs.postiz.com/reverse-proxies/caddy
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. It is also
# POSTIZ_DOMAIN in .env, and the host every OAuth redirect URI points back at.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting a channel bounces out to a provider.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8111 is the loopback port compose publishes here. It is not a container
	# port and it is not open in the firewall. One upstream serves both halves
	# of the app: the nginx inside the container sends /api/ to the backend and
	# everything else to the frontend.
	reverse_proxy 127.0.0.1:8111
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-postiz /etc/caddy/Caddyfile`,
reload, and paste again. There is one upstream and no second route, because the nginx
inside the Postiz container already sends `/api/` to the backend and everything else to the
frontend. Caddy issues the certificate on the first request and renews it on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8111`, `5432`, `6379` or `7233`.

If you do not: delete anything for those four with, for example,
`sudo ufw delete allow 8111`. 8111 is bound to 127.0.0.1 by the compose file, and the two
databases, the cache and the workflow engine publish no host port at all, so there is
nothing for a firewall rule to apply to. `Status: inactive` is a different problem: Prompt
Zero left this firewall enabled, so something has turned it off since, and `sudo ufw enable`
puts it back before you go any further.

## 7. Start and verify

The first start is the slow one. Temporal builds two database schemas before it reports
healthy, and Postiz then runs its own migrations, so the loop below is allowed ten minutes.

```bash
cd /srv/postiz
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose exec -T temporal temporal operator cluster health --address temporal:7233
curl -sS https://<DOMAIN>/api/
curl -sS https://<DOMAIN>/api/auth/can-register
```

You should see, in order: the loop climbing through `502` and ending on `200`, then
`SERVING`, then `App is running!`, then `{"register":true}`.

If you do not: a loop that never leaves `502` after ten minutes is usually Postiz waiting on
Temporal. Run `docker compose logs --tail 20 temporal` first, because a Temporal container
that never reports healthy means step 3's password did not reach its PostgreSQL, then
`docker compose logs --tail 40 postiz`. A `404` where you expected `App is running!` means
Caddy is reaching something other than the container: check `docker compose ps`. The
`{"register":true}` is the one worth understanding, because it says the sign-up window is
open and the database has no account in it yet, which is exactly the state the next step
depends on.

Now open https://<DOMAIN>/auth in a browser. The first screen shows the heading `Sign Up`
over an email, password and company form, with a `Create Account` button. Create the one
account this install will have, then come back and close the window behind you:

```bash
curl -sS https://<DOMAIN>/api/auth/can-register
```

You should see: `{"register":false}`.

If you do not: `{"register":true}` after you registered means the account was not created,
so try again in the browser and watch for an error under the form. `DISABLE_REGISTRATION`
is already true in compose.yml, and upstream documents that as allowing a single signup and
then disabling the sign-up page, so a `false` here is the proof that the one account it
allowed is yours. Reload https://<DOMAIN>/auth and confirm it now reads
`Registration is disabled`. A green `docker compose ps` is not success; these two checks
are.

## 8. First backup and restore

Two artifacts. The database dump holds the accounts, the drafts and the schedule. The
config archive holds the files that rebuild the service around it, uploaded media included.
Temporal's own database is in neither, because the auto-setup image rebuilds it from empty.

```bash
cd /srv/postiz
docker compose exec -T postiz-postgres pg_dump -U postiz -d postiz | gzip > /srv/postiz/backups/postiz-db-$(date +%F).sql.gz
sudo tar -czf /srv/postiz/backups/postiz-config-$(date +%F).tar.gz -C /srv/postiz compose.yml .env config uploads -C /etc/caddy Caddyfile
ls -lh /srv/postiz/backups/
```

You should see: two files, both non-empty. Nothing goes offline, because `pg_dump` snapshots
a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/postiz
scp vps:/srv/postiz/backups/* ~/backups/postiz/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/postiz/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is one empty account:

```bash
cd /srv/postiz
docker compose down
sudo rm -rf /srv/postiz/postgres /srv/postiz/temporal-postgres
sudo install -d -m 700 /srv/postiz/postgres /srv/postiz/temporal-postgres
docker compose up -d postiz-postgres
sleep 30
gunzip -c /srv/postiz/backups/postiz-db-$(date +%F).sql.gz | docker compose exec -T postiz-postgres psql -U postiz -d postiz
docker compose up -d
sleep 120
curl -sS https://<DOMAIN>/api/auth/can-register
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `{"register":false}` from
the last command, which means your account survived a database that was deleted and rebuilt.

If you do not: `role "postiz" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. The last `sleep 120` is there
because Temporal is rebuilding its schemas from scratch too; if the final command answers
nothing, wait and run it again before concluding anything. Understand what this protects:
your drafts and your calendar come back from that dump, and a connected channel comes back
only if that network's token has not expired in the meantime.

## 9. Updating later

New versions are listed at https://github.com/gitroomhq/postiz-app/releases. Take both
backup artifacts first, then edit the `image:` line in /srv/postiz/compose.yml to the new
tag and its digest.

```bash
cd /srv/postiz
docker compose pull
docker compose up -d
docker compose logs --tail 30 postiz
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
the four checks from step 7 before you call the update done. Read the release notes rather
than only the tag: which services this stack needs has changed before, and Temporal
arriving in v2.12.0 is the example.

## 10. What will probably go wrong

The first four minutes look like a broken install. I watched https://<DOMAIN>/api/ return
`502` over and over while `docker compose ps` showed every container up, and went hunting a
Caddy mistake that was not there. Temporal was still building its schemas, and Postiz
answers nothing until it can reach Temporal. Watch `docker compose logs -f temporal`, then
the Postiz log for its migrations, and give step 7 its full ten minutes before touching
anything.

## 11. Out of scope

- Do not connect a social network yet. Each one needs an app registered in that company's
  own developer portal, a redirect URI of
  `https://<DOMAIN>/integrations/social/`, and its client id and secret added to
  /srv/postiz/.env. Several of those registrations are reviewed by a person at the other
  company and take days, and no amount of waiting in this window changes that. Start at
  https://docs.postiz.com/providers/overview when the install is done.
- Do not configure SMTP or set `EMAIL_PROVIDER`. With no mail provider set upstream
  activates accounts without email, and this install relies on that.
- Do not install the Temporal web interface, the admin-tools container or Elasticsearch.
  Upstream ships all three; this stack runs without them and each is another service to
  watch.
- Do not set `OPENAI_API_KEY`, the Stripe keys, or `STORAGE_PROVIDER=cloudflare`. Each is
  an account somewhere else, and this install needs none of them.
