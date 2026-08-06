This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Activepieces 0.86.3-hotfix.1 on a VPS where Prompt Zero is done: `ssh vps`
works, Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record
already points at the box.

Read this before step 1. `<DOMAIN>` becomes `AP_FRONTEND_URL`, and every webhook URL and OAuth
redirect this instance hands out is built from it. Flows that are already running keep pointing
at the old name if you move it, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. On memory, the floor is
real rather than cautious: upstream sizes a container running the API and a worker together at
roughly 1 GB per concurrent flow on top of a 2 GB API tier, and this install runs two flows at
once. A 2 GB box will start, then be killed by the kernel partway through your first real flow.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/activepieces /srv/activepieces/backups /srv/activepieces/cache
sudo install -d -m 700 /srv/activepieces/postgres /srv/activepieces/redis
ls -la /srv/activepieces
```

You should see: `backups` and `cache` owned by you, and `postgres` and `redis` at mode
`drwx------` owned by root.

If you do not: leave those last two owned by root on purpose. Both images chown their own data
directory the first time they start, and a PostgreSQL directory you have already chowned to
yourself makes the container refuse to initialise. `cache` holds the piece packages the app
downloads; it is a cache, and losing it costs a slow boot and nothing else.

## 3. Secrets

Three secrets: the encryption key that protects every credential you will hand a piece, the JWT
signing secret, and the PostgreSQL password. All three are generated here, on the server, into
a file only you can read. The encryption key is 32 hexadecimal characters because upstream says
so, which is why it is `-hex 16` while the other two are `-hex 32`.

```bash
umask 077
cat > /srv/activepieces/.env <<EOF
AP_FRONTEND_URL=https://<DOMAIN>
AP_ENCRYPTION_KEY=$(openssl rand -hex 16)
AP_JWT_SECRET=$(openssl rand -hex 32)
AP_POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/activepieces/.env
umask 022
ls -l /srv/activepieces/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

Do not paste that file, any of the three values, or any command output containing them into
this chat window. The agent path never sees them; this one will hand them to a third party
unless you are deliberate about it.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/activepieces/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
all three secrets, which is fine before the database exists and a problem afterwards:
PostgreSQL keeps the password it was created with, so a changed `AP_POSTGRES_PASSWORD` on an
existing data directory shows up as an authentication failure in the activepieces log rather
than anything about passwords. Read the encryption key once with
`sudo grep AP_ENCRYPTION_KEY /srv/activepieces/.env` and put it in your password manager: every
connection you create is encrypted with it, and a restored database without it is a list of
flows you cannot run.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/activepieces/compose.yml <<'EOF'
# Activepieces · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose install ..... https://www.activepieces.com/docs/install/options/docker-compose
#   variable reference .. https://www.activepieces.com/docs/install/reference/environment-variables
#   sizing and sandbox .. https://www.activepieces.com/docs/install/configure-operate/production-setup
#
# Three services: Activepieces, the PostgreSQL that holds the flows and the run
# history, and the Redis that holds the job queue. Upstream's own compose file
# splits the API and five worker replicas apart; this one does not, because
# AP_CONTAINER_TYPE defaults to WORKER_AND_APP and one image runs both roles.
# PostgreSQL is the pgvector image because the knowledge base asks the database
# for that extension at every boot and drops the feature when it is absent.
# Upstream's compose pins pgvector 0.8.0-pg14; this file runs the pg16 line,
# the major upstream's own CI runs its Postgres suite against.
#
# Neither the database nor the queue declares `ports:`, and 8095 binds to
# loopback, so the host's Caddy is the only thing that reaches this stack.
# AP_EXECUTION_MODE is upstream's choice for a single-tenant install and the
# image default: flow code runs with this container's own reach.
# AP_WORKER_CONCURRENCY is 2, roughly 1 GB per concurrent flow on top of the API
# tier, and the queue dashboard stays off because it stops the boot when it is on
# with no credentials set. Digests read 2026-08-05; all three images publish
# amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg16@sha256:a36250871de0833b8757561c72f2477ef1ddd1101afa4e617fb552e0de514c6b
    container_name: activepieces-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: activepieces
      POSTGRES_USER: activepieces
      POSTGRES_PASSWORD: ${AP_POSTGRES_PASSWORD}
    volumes:
      - /srv/activepieces/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U activepieces -d activepieces"]
      interval: 10s
      retries: 12

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: activepieces-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/activepieces/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  activepieces:
    image: ghcr.io/activepieces/activepieces:0.86.3-hotfix.1@sha256:4da6910cf46dbc38857c8c4fac6ba867ab804b8a3a8551d672d4490cb1245566
    container_name: activepieces
    restart: unless-stopped
    env_file: /srv/activepieces/.env
    environment:
      AP_ENVIRONMENT: prod
      AP_CONTAINER_TYPE: WORKER_AND_APP
      AP_DB_TYPE: POSTGRES
      AP_POSTGRES_HOST: postgres
      AP_POSTGRES_PORT: "5432"
      AP_POSTGRES_DATABASE: activepieces
      AP_POSTGRES_USERNAME: activepieces
      AP_REDIS_TYPE: STANDALONE
      AP_REDIS_HOST: redis
      AP_REDIS_PORT: "6379"
      AP_EXECUTION_MODE: UNSANDBOXED
      AP_WORKER_CONCURRENCY: "2"
      AP_QUEUE_UI_ENABLED: "false"
      AP_TELEMETRY_ENABLED: "false"
    volumes:
      - /srv/activepieces/cache:/usr/src/app/cache
    ports:
      - "127.0.0.1:8095:80"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/activepieces && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/activepieces/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/activepieces/compose.yml` and paste again in one go. The `${AP_POSTGRES_PASSWORD}`
on the postgres service is not a typo; compose reads it out of the `.env` in the same
directory, which is why that file has to exist before this command runs.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-activepieces
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Activepieces · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.activepieces.com/docs/install/configure-operate/setup-ssl and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# AP_FRONTEND_URL in .env, and every webhook URL this instance hands out is built
# from it, so it is the value here you cannot change once flows are running.

<DOMAIN> {
	# The flow editor holds a websocket open for live run output. Upstream's proxy
	# example passes the upgrade headers by hand; Caddy does it without being told.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting a piece sends the user out to a third-party
		# OAuth consent screen and back, and some providers check the origin.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8095 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8095
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-activepieces /etc/caddy/Caddyfile`,
reload, and paste again. The flow editor streams live run output over a websocket, and
upstream's own proxy example sets the upgrade headers by hand. Caddy does that without being
told, so there is no upgrade stanza in the block and nothing missing from it.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8095`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8095`. 8095 is bound
to 127.0.0.1 by the compose file, and 5432 and 6379 are never published at all, so neither the
database nor the queue has a host port a firewall rule could apply to. 80/tcp redirects to
HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which
Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back
before you go any further.

## 7. Start and verify

Activepieces runs its own database migrations on the way up and then syncs the metadata for the
piece catalogue. The first boot is slow and the loop below is built to wait for it.

```bash
cd /srv/activepieces
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/health
curl -sS https://<DOMAIN>/api/v1/flags | grep -o '"USER_CREATED":[a-z]*' || echo "USER_CREATED absent"
```

You should see, in order: the loop climbing through `502` and then reaching `200`, then
`{"status":"Healthy"}`, then `USER_CREATED absent`.

If you do not: the `502` while it climbs is normal, because Caddy has a site block for a
container that is still migrating. The image's own health check does not begin probing for 60
seconds. If the loop never reaches `200`, run `docker compose logs --tail 20 postgres` first,
because a database that never reports healthy is step 2 done wrong, and
`docker compose logs --tail 40 activepieces` second. A certificate error rather than a `502`
points at step 5 or at DNS.

Now open https://<DOMAIN>/sign-up in a browser. The first screen shows the heading
`Create a new account` over a form asking for a first name, a last name, an email address and a
password. Create the account. It owns this instance.

Then confirm registration has closed behind you:

```bash
curl -sS https://<DOMAIN>/api/v1/flags | grep -o '"USER_CREATED":true'
```

You should see: `"USER_CREATED":true`.

If you do not: an empty result means the sign-up did not complete, so reload the page and check
whether you are logged in. Once that flag is true, a second sign-up is answered against the
platform your account created, and that path requires an invitation unless
`AP_ALLOW_OPEN_SIGN_UP` is set, which this install never sets. Both of those checks passing is
what success means here. A running container is not success.

## 8. First backup and restore

Two artifacts. The database holds the flows, the connections and the run history. The config
archive holds the files that rebuild the service around them, including the encryption key.

```bash
cd /srv/activepieces
docker compose exec -T postgres pg_dump -U activepieces -d activepieces | gzip > /srv/activepieces/backups/activepieces-db-$(date +%F).sql.gz
sudo tar -C /srv/activepieces -czf /srv/activepieces/backups/activepieces-config-$(date +%F).tar.gz compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/activepieces/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently. Redis is not in the backup and does not
need to be, because it carries jobs in flight rather than the record of what the flows are.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/activepieces
scp vps:/srv/activepieces/backups/* ~/backups/activepieces/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/activepieces/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty instance:

```bash
cd /srv/activepieces
docker compose down
sudo rm -rf /srv/activepieces/postgres
sudo install -d -m 700 /srv/activepieces/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/activepieces/backups/activepieces-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U activepieces -d activepieces
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/api/v1/health
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `{"status":"Healthy"}`.

If you do not: `role "activepieces" does not exist` means the database container had not
finished initialising, so wait longer and run the `gunzip` line again. Understand the stake
before you skip this step. The dump and the config archive are one backup in two files:
restored without the matching `AP_ENCRYPTION_KEY` from `.env`, that database comes back with
every flow intact and every stored credential unreadable, and there is no recovery from that
other than reconnecting every service by hand.

## 9. Updating later

New versions are listed at https://github.com/activepieces/activepieces/releases. Take both
backup artifacts first, then edit the image line in /srv/activepieces/compose.yml to the new
tag and its digest.

```bash
cd /srv/activepieces
docker compose pull
docker compose up -d
docker compose logs --tail 30 activepieces
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one flow in the editor as
well, because a service that answers `Healthy` can still be failing to run flows if a migration
stopped halfway.

## 10. What will probably go wrong

The first boot looks like a failed install for several minutes. I watched Caddy answer `502`
over and over while the container ran migrations and pulled the piece catalogue metadata, and
the pull to start editing the compose file was strong. Nothing was wrong. The image's health
check does not begin probing for 60 seconds, and the loop in step 7 waits ten minutes for a
reason. Before touching anything, run `docker compose logs --tail 40 activepieces`: a log still
moving is an install still working.

## 11. Out of scope

- Do not configure SMTP. No `AP_SMTP_` variable is set here, and the community edition verifies
  the first account itself rather than mailing a link.
- Do not set `AP_GOOGLE_CLIENT_ID`, `AP_GOOGLE_CLIENT_SECRET` or any SSO variable. First login
  is an email address and a password, and single sign-on is a paid-edition feature.
- Do not split the worker into its own container, raise `AP_WORKER_CONCURRENCY`, or configure
  S3 storage. Those are the production shape for a fleet, and this is one machine.
- Do not set `AP_NETWORK_MODE=STRICT` or change `AP_EXECUTION_MODE`. Upstream states that the
  strict guard is best-effort inside the process, not a boundary against hostile code.
