This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Chatwoot 4.16.2, community edition, on a VPS where Prompt Zero is done:
`ssh vps` works, Docker and Caddy are installed, the firewall is default-deny. Run everything
over `ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A
record already points at the box.

Read this before step 1. `<DOMAIN>` becomes `FRONTEND_URL`, the address baked into the chat
widget snippet you paste on your website and into every link Chatwoot sends. Changing it later
means editing a file and recreating containers, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line. Upstream states 4 GB as the minimum for a Chatwoot that handles up
to 10,000 conversations a day, and Rails plus Sidekiq is where that goes.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that
does not resolve and failed attempts count against a rate limit you cannot see. Under 4096 MB of
RAM, stop and resize the box rather than continuing: the failure mode is the OOM killer arriving
in the middle of the database migration in step 7, which leaves a half-loaded schema.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/chatwoot /srv/chatwoot/backups /srv/chatwoot/storage /srv/chatwoot/redis
sudo install -d -m 700 /srv/chatwoot/postgres
ls -la /srv/chatwoot
```

You should see: `backups`, `storage` and `redis` owned by you, and `postgres` at mode `drwx------`
owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `storage` is where customer attachments land, which is why it is yours and
in the backup.

## 3. Secrets

Three secrets: the Rails key that signs cookies and sessions, the PostgreSQL password and the
Redis password. All three are generated here, on the server, and all three go straight into a
file only you can read. Replace `<DOMAIN>` on the first line before you paste.

```bash
umask 077
cat > /srv/chatwoot/.env <<EOF
FRONTEND_URL=https://<DOMAIN>
SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/chatwoot/.env
umask 022
ls -l /srv/chatwoot/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Hex rather than base64
because upstream asks for an alphanumeric value on the first one and the other two ride inside
connection strings.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/chatwoot/.env` and carry on.
If the file already existed from an earlier attempt, this block has now overwritten all three,
which is fine before the database exists and a problem afterwards: PostgreSQL keeps the password
it was created with, so a changed one on an existing volume shows up as an authentication failure
in the Rails log rather than as anything about passwords.

Do not paste that file, any of those three values, or any command output containing them into
this chat window. No human ever needs to read them, which makes this the easy rule to keep: your
own account password is the one you choose in step 7, in a browser.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/chatwoot/compose.yml <<'EOF'
# Chatwoot · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker deployment .. https://developers.chatwoot.com/self-hosted/deployment/docker
#   variable reference . https://developers.chatwoot.com/self-hosted/configuration/environment-variables
#   requirements ....... https://developers.chatwoot.com/self-hosted/deployment/requirements
#
# Four services: the Rails web process, the Sidekiq worker every background job
# runs on, PostgreSQL and Redis. The database image is pgvector's, because
# Chatwoot's schema turns on the `vector` extension and a plain postgres refuses
# the schema load. The -ce tag is the community edition, built with the
# enterprise/ directory deleted, which is the tree the MIT licence covers.
# Digests read on 2026-08-06; all three images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# Rails and Sidekiq share an image and an environment; compose ignores x- keys.
x-chatwoot: &chatwoot
  image: chatwoot/chatwoot:v4.16.2-ce@sha256:7ee85a208147a86188ffc0e7fafafd2e1c0403b4ad6aea9e31f566662cce1d2f
  restart: unless-stopped
  env_file: /srv/chatwoot/.env
  environment:
    RAILS_ENV: production
    NODE_ENV: production
    INSTALLATION_ENV: docker
    POSTGRES_HOST: postgres
    POSTGRES_USERNAME: chatwoot
    POSTGRES_DATABASE: chatwoot_production
    REDIS_URL: redis://redis:6379
    # Signup stays shut: one account, made once through the onboarding screen.
    ENABLE_ACCOUNT_SIGNUP: "false"
    ACTIVE_STORAGE_SERVICE: local
  volumes:
    - /srv/chatwoot/storage:/app/storage
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg16@sha256:a36250871de0833b8757561c72f2477ef1ddd1101afa4e617fb552e0de514c6b
    container_name: chatwoot-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: chatwoot_production
      POSTGRES_USER: chatwoot
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/chatwoot/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chatwoot -d chatwoot_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: chatwoot-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    # Doubled dollar: compose leaves it, the container's own shell expands it.
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass $$REDIS_PASSWORD"]
    volumes:
      - /srv/chatwoot/redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli --no-auth-warning -a $$REDIS_PASSWORD ping | grep -q PONG"]
      interval: 10s
      retries: 12

  rails:
    <<: *chatwoot
    container_name: chatwoot-rails
    entrypoint: docker/entrypoints/rails.sh
    command: ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8102.
      - "127.0.0.1:8102:3000"

  sidekiq:
    <<: *chatwoot
    container_name: chatwoot-sidekiq
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
EOF
cd /srv/chatwoot && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/chatwoot/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal,
so run `rm /srv/chatwoot/compose.yml` and paste again in one go. The `sidekiq` service is not
optional scenery: every outgoing message, webhook and notification is a background job, and a
Chatwoot with no worker is a dashboard whose replies never leave.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-chatwoot
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Chatwoot · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://developers.chatwoot.com/self-hosted/deployment/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also FRONTEND_URL in .env, so changing it later means editing .env too.

<DOMAIN> {
	# The dashboard holds customer conversations, so nothing here should be
	# framed, sniffed or leaked in a referrer.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8102 is the loopback port compose publishes on this host, not a container
	# port and not open in the firewall. Caddy upgrades the /cable websocket on
	# this same route and sets X-Forwarded-Proto, which is what lets Rails
	# accept that websocket as same-origin rather than rejecting it.
	reverse_proxy 127.0.0.1:8102
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-chatwoot /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the
other. Caddy requests the certificate on the first request and renews it itself, so there is
nothing here to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8102`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8102`. 8102 is bound
to 127.0.0.1 by the compose file, and 5432 and 6379 are never published at all, unlike upstream's
example compose file which publishes both on the host. 80/tcp redirects to HTTPS and answers the
ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The database is prepared once, before anything serves traffic. Upstream documents
`rails db:chatwoot_prepare` as the task that loads the schema on an empty database and migrates
an existing one; it also seeds the flag that unlocks the one-time onboarding screen. The prepare
run can take several minutes and prints very little while it works.

```bash
cd /srv/chatwoot
docker compose pull
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/api
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/v1/accounts
curl -sS https://<DOMAIN>/installation/onboarding | grep -o 'Howdy, Welcome to Chatwoot'
```

You should see, in order: the loop reaching `200`, then exactly `{"status":"woot"}`, then a JSON
object containing `"queue_services":"ok"` and `"data_services":"ok"`, then `404`, then the line
`Howdy, Welcome to Chatwoot`.

If you do not: the `404` is the one worth understanding. It means account signup is off, which is
what this install wants, and it is the security check in this block. A `200` there would mean
anyone on the internet can create an account on your support desk. `"data_services":"failing"`
points back at step 3, where a `.env` missing its password lines leaves PostgreSQL unreachable;
`"queue_services":"failing"` is the same story for Redis. A `502` from Caddy while the loop is
still running is normal for the first two minutes; if the loop finishes forty rounds without a
`200`, run `docker compose logs --tail 40 rails` and `docker compose logs --tail 20 sidekiq`. A
running container is not success.

The first screen at https://<DOMAIN> shows the heading `Howdy, Welcome to Chatwoot`, a waving
emoji after it, above a form asking for a name, a company, a work email and a password.

Open https://<DOMAIN> in a browser now and fill that form in. It runs once, and it makes the only
administrator this install has. Put the password in your password manager as you type it, because
there is no SMTP configured here and therefore no password-reset email to fall back on.

Then prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/installation/onboarding
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `302` from the first, then `200` from the second.

If you do not: a `200` from the first means the onboarding form is still open and the account was
not created, so go back to the browser and finish it. That form is the one moment this install
would accept an administrator from anyone who could reach the URL, and closing it is the point of
this check.

## 8. First backup and restore

Two artifacts. The database holds every conversation, contact and agent; the config archive holds
the files and attachments that rebuild the service around them.

```bash
cd /srv/chatwoot
docker compose exec -T postgres pg_dump -U chatwoot -d chatwoot_production | gzip > /srv/chatwoot/backups/chatwoot-db-$(date +%F).sql.gz
sudo tar -czf /srv/chatwoot/backups/chatwoot-config-$(date +%F).tar.gz -C /srv/chatwoot compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/chatwoot/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline, because
`pg_dump` snapshots a running database consistently. Redis is in neither archive on purpose: it
holds the job queue and the caches, not durable data.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/chatwoot
scp vps:/srv/chatwoot/backups/* ~/backups/chatwoot/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/chatwoot/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/chatwoot
docker compose down
sudo rm -rf /srv/chatwoot/postgres
sudo install -d -m 700 /srv/chatwoot/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/chatwoot/backups/chatwoot-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U chatwoot -d chatwoot_production
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command, and
your administrator account still works when you sign in.

If you do not: `role "chatwoot" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the config archive
is for before you skip it: it carries `.env`, and the Rails key in that file is what verifies
every session cookie. Restore a database without it and everyone is signed out into an install
that no longer recognises its own tokens.

## 9. Updating later

New versions are listed at https://github.com/chatwoot/chatwoot/releases. Keep the `-ce` suffix on
the tag. Take both backup artifacts first, then edit the application image line in
/srv/chatwoot/compose.yml to the new tag and its digest.

```bash
cd /srv/chatwoot
docker compose pull
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d
docker compose logs --tail 30 rails
```

You should see: migration output from the prepare run, then the server starting, and no repeating
restart.

If you do not: put the old tag and digest back and run the same commands. The prepare task is not
optional on an update, because it is what migrates the database the new image inherited. Then
re-run the health checks from step 7 before you call the update done.

## 10. What will probably go wrong

The wait. On a 4 GB box the prepare task in step 7 spent several minutes loading a schema with no
output at all, and then `docker compose up -d` returned instantly while Caddy answered `502` for
another two minutes because Rails was still eager-loading. I restarted the whole stack during
that window, convinced it had hung, and all that did was start the two minutes again. The loop
waits ten minutes on purpose. Let it run, and watch `docker compose logs -f rails` if you need
something to look at rather than something to press.

## 11. Out of scope

- Do not configure SMTP. Live chat works without it, and this install trades agent-invite and
  password-reset email for not fighting port 25 on a fresh VPS.
- Do not add a Facebook, Instagram, WhatsApp or email channel. Each is an app registration at
  somebody else's console, and none is needed for the widget.
- Do not set `ENABLE_ACCOUNT_SIGNUP` to true. Step 7 asserts that endpoint answers 404, and an
  open signup on a support desk is an open door to the conversation history.
- Do not switch `ACTIVE_STORAGE_SERVICE` to S3. Attachments belong on the disk step 8 archives,
  not in a bucket the backup cannot see.
