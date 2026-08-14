This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Twenty 2.30.1 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. Twenty ships no setup wizard and no seeded administrator. The first
person who opens your hostname and finishes the workspace form becomes the administrator of
this instance, and upstream then refuses every later signup. That is the design, and it is also
a race: from the moment step 7 starts the containers until you finish that form, the instance
belongs to whoever loads the page. Do step 7 in one sitting.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: 4096 MB is not a suggestion here. Two Node processes, PostgreSQL and Redis on a
2 GB box will start, then get killed by the kernel partway through the first migration, and the
symptom is a container that restarts forever with no useful error. Upstream's own floor for the
application alone is 2 GB. An empty last line means the A record does not exist yet: add it,
wait a minute, and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a
name that does not resolve and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/twenty /srv/twenty/backups
sudo install -d -m 700 /srv/twenty/postgres
sudo install -d -m 750 -o 1000 -g 1000 /srv/twenty/storage
ls -la /srv/twenty
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`storage` owned by `1000`.

If you do not: leave `postgres` owned by root on purpose, because the PostgreSQL image chowns
its own data directory the first time it starts and one you have already chowned to yourself
makes it refuse to initialise. `storage` is the opposite case: the application image runs as uid
1000, so a directory owned by you is one it cannot write, and the first file anybody attaches to
a record fails with a permission error long after this step is forgotten.

## 3. Secrets

Three secrets, all generated here on the server: the key that encrypts stored secrets at rest,
the legacy application secret the token code still reaches for, and the PostgreSQL password.
The database password is hex rather than base64 because it rides inside a connection string,
where upstream asks for a strong password with no special characters in it.

```bash
umask 077
cat > /srv/twenty/.env <<EOF
SERVER_URL=https://<DOMAIN>
IS_MULTIWORKSPACE_ENABLED=false
APP_SECRET=$(openssl rand -base64 32)
ENCRYPTION_KEY=$(openssl rand -base64 32)
PG_DATABASE_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/twenty/.env
umask 022
ls -l /srv/twenty/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste, with no trailing slash.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/twenty/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all
three values, which is fine before the database exists and a problem afterwards: PostgreSQL
keeps the password it was created with, so a changed `PG_DATABASE_PASSWORD` on an existing
directory shows up as an authentication failure in the server log rather than anything about
passwords.

Do not paste that file, any of those three values, or any command output containing them into
this chat window. Read `ENCRYPTION_KEY` once with `sudo grep ENCRYPTION_KEY /srv/twenty/.env`
and put it in your password manager: upstream says losing it means losing access to every secret
stored in the database, which over time becomes your OAuth tokens and two-factor secrets.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/twenty/compose.yml <<'EOF'
# Twenty · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation and upstream's own compose file:
#   docker compose ..... https://docs.twenty.com/developers/self-host/capabilities/docker-compose
#   upstream compose ... https://github.com/twentyhq/twenty/blob/064bdd795a0bd78c65f024350cefed2c8f38a661/packages/twenty-docker/docker-compose.yml
#
# Four services, the same four upstream runs: the server, a worker on the same
# image draining the job queue, PostgreSQL and Redis. Upstream writes postgres:16
# and a bare redis; this file pins the patch and digest of each, and that bare
# tag is the 8.10 line below. SERVER_URL and IS_MULTIWORKSPACE_ENABLED arrive
# from .env, so both containers read one value. Digests read from the registries
# on 2026-08-12; the application image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: twenty-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: default
      POSTGRES_USER: twenty
      POSTGRES_PASSWORD: ${PG_DATABASE_PASSWORD}
    volumes:
      - /srv/twenty/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U twenty -d default"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: twenty-redis
    restart: unless-stopped
    # Upstream's own flag: the job queue must not be evicted under pressure.
    command: ["--maxmemory-policy", "noeviction"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  server:
    image: twentycrm/twenty:v2.30.1@sha256:36049a73f0d2e25c059007ccb452cf183b02fd57cb107afee7d959879639fa97
    container_name: twenty-server
    restart: unless-stopped
    env_file: /srv/twenty/.env
    environment:
      NODE_PORT: 3000
      PG_DATABASE_URL: postgres://twenty:${PG_DATABASE_PASSWORD}@db:5432/default
      REDIS_URL: redis://redis:6379
      # Attachments land in the mount below, not in an S3 bucket.
      STORAGE_TYPE: local
    volumes:
      - /srv/twenty/storage:/app/packages/twenty-server/.local-storage
    healthcheck:
      # Upstream's own. Many retries: the entrypoint runs the schema setup and
      # every migration before this port answers anything.
      test: ["CMD", "curl", "--fail", "http://localhost:3000/healthz"]
      interval: 10s
      timeout: 5s
      retries: 30
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8183.
      - "127.0.0.1:8183:3000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  worker:
    image: twentycrm/twenty:v2.30.1@sha256:36049a73f0d2e25c059007ccb452cf183b02fd57cb107afee7d959879639fa97
    container_name: twenty-worker
    restart: unless-stopped
    command: ["yarn", "worker:prod"]
    env_file: /srv/twenty/.env
    environment:
      PG_DATABASE_URL: postgres://twenty:${PG_DATABASE_PASSWORD}@db:5432/default
      REDIS_URL: redis://redis:6379
      STORAGE_TYPE: local
      # Upstream's own values here: the server owns migrations and cron
      # registration, and two processes racing one migration half-apply it.
      DISABLE_DB_MIGRATIONS: "true"
      DISABLE_CRON_JOBS_REGISTRATION: "true"
    volumes:
      - /srv/twenty/storage:/app/packages/twenty-server/.local-storage
    depends_on:
      db:
        condition: service_healthy
      server:
        condition: service_healthy
EOF
cd /srv/twenty && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/twenty/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/twenty/compose.yml` and paste again in one go. A warning about
`PG_DATABASE_PASSWORD` not being set means you are running the command from somewhere other
than /srv/twenty, because Compose reads the `.env` beside the compose file and nowhere else.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-twenty
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Twenty · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.twenty.com/developers/self-host/capabilities/docker-compose and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# SERVER_URL in .env: upstream says to set the server URL to your public URL,
# because the server uses it for the links it generates and to work out that it
# is being reached over HTTPS, which is what makes its session cookies secure.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Nothing here is meant to be framed by another site.
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8183 is the loopback port compose publishes; it is not open in the firewall.
	reverse_proxy 127.0.0.1:8183
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-twenty /etc/caddy/Caddyfile`, reload,
and paste again. The hostname in this block and the `SERVER_URL` you wrote in step 3 have to be
the same string: upstream states the server URL must match how people reach the application in
their browsers, and a mismatch produces links and redirects that point somewhere nobody can
follow.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8183`, `5432`, `6379` or `3000`.

If you do not: delete anything for those four with `sudo ufw delete allow 8183`. 8183 is bound
to 127.0.0.1 by the compose file, and 5432 and 6379 are never published at all, so the database
and Redis have no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS
and to answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy
offers by default. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The server container runs the schema setup and every migration before it answers a request, so
the first boot takes minutes rather than seconds. The worker waits on the server's own health
check before it starts, which is why it sits idle for a while in `docker compose ps`.

```bash
cd /srv/twenty
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthz; echo
curl -sSL https://<DOMAIN>/ | grep -c '<title>Twenty</title>'
curl -sS https://<DOMAIN>/client-config | grep -o '"isMultiWorkspaceEnabled":[a-z]*'
docker compose ps --format '{{.Service}} {{.State}}'
```

You should see, in order: the loop counting up and ending on `200`, a small JSON object
containing `"status":"ok"`, a number greater than `0`, the text
`"isMultiWorkspaceEnabled":false`, and four lines reading `db`, `redis`, `server` and `worker`,
each `running`.

If you do not: the loop is allowed to take ten minutes on a first boot, and the honest way to
watch it is `docker compose logs -f server` in a second terminal rather than the browser. A 502
that never clears with all four containers up is step 5. A `server` that keeps restarting is
usually memory: run `free -m` and compare with step 1. If the loop reaches `200` but the title
grep prints `0`, Caddy is reaching something other than Twenty, so check
`docker compose ps` for a second service holding 8183.

The first screen at https://<DOMAIN> is a sign-in form with a `Continue with Email` button, and
the browser tab reads `Twenty`. There is no wizard and no default account. `isMultiWorkspaceEnabled`
being `false` is what makes the rest of this step true: on a single-workspace instance the first
user becomes the administrator with full privileges, and upstream disables new signups once the
first workspace exists.

Go and claim it now, in one sitting: open https://<DOMAIN>, create your account, and keep going
until the workspace is created and the records screen has loaded. Save that password in your
password manager, because no mail is configured and the reset link has nothing to send.

Then prove the window is shut. This asks the public signup mutation for a second account on an
address nobody owns:

```bash
curl -sS -X POST https://<DOMAIN>/graphql -H 'content-type: application/json' --data '{"query":"mutation Probe($e: String!, $p: String!) { signUp(email: $e, password: $p) { tokens { refreshToken { token } } } }","variables":{"e":"closure-probe@example.com","p":"probe-not-a-login"}}' -o /tmp/twenty-signup-probe.json
cat /tmp/twenty-signup-probe.json; echo
grep -c SIGNUP_DISABLED /tmp/twenty-signup-probe.json
```

You should see: a JSON body carrying `"subCode":"SIGNUP_DISABLED"` and no token at all, then
`1` from the grep.

If you do not: a `0` from the grep with a `refreshToken` in the body means an account was
created and your instance is still open to strangers. That happens when you stopped at the
account screen without finishing the workspace, because the block only closes once a workspace
exists. Go back to https://<DOMAIN>, finish it, and run the probe again. Do not leave this step
until the grep prints `1`. A running container is not success.

## 8. First backup and restore

Two artifacts. The database holds every person, company, note, task and user account. The file
archive holds the attachments and the three files that rebuild the service around them.

```bash
cd /srv/twenty
docker compose exec -T db pg_dump -U twenty -d default | gzip > /srv/twenty/backups/twenty-db-$(date +%F).sql.gz
sudo tar -czf /srv/twenty/backups/twenty-files-$(date +%F).tar.gz -C /srv/twenty compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/twenty/backups/
```

You should see: two files, both non-empty. On a fresh install the dump is a few hundred
kilobytes, because Twenty's schema is large before you have entered anything.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error. Nothing
goes offline for either command: `pg_dump` snapshots a running database consistently.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/twenty
scp vps:/srv/twenty/backups/* ~/backups/twenty/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/twenty/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty CRM:

```bash
cd /srv/twenty
docker compose down
sudo rm -rf /srv/twenty/postgres
sudo install -d -m 700 /srv/twenty/postgres
docker compose up -d db
sleep 40
gunzip -c /srv/twenty/backups/twenty-db-$(date +%F).sql.gz | docker compose exec -T db psql -U twenty -d default
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/healthz; echo
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `{"status":"ok"...}` from the
health check, and your account still works when you sign in.

If you do not: `role "twenty" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. If you are restoring onto a fresh
box rather than testing, untar the file archive into /srv/twenty first, before anything starts,
because PostgreSQL takes its password from `.env` the moment it initialises an empty directory.
Both halves matter: `ENCRYPTION_KEY` in that file is what decrypts the secrets inside those rows,
so a database restored without it is a CRM that cannot read its own integrations.

## 9. Updating later

New versions are listed at https://github.com/twentyhq/twenty/releases. The release tag carries a
`twenty/` prefix and the image tag does not, so release `twenty/v2.30.1` is image tag `v2.30.1`.
Take both backup artifacts first, then edit both image lines in /srv/twenty/compose.yml to the
new tag and its digest, because the server and the worker must never run different builds against
one database.

```bash
cd /srv/twenty
docker compose pull
docker compose up -d
docker compose logs --tail 40 server
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check and the signup probe from step 7 before you call the update done, because a
migration that stopped halfway can leave a service that answers `ok` on health and fails on the
first record you open.

## 10. What will probably go wrong

The first boot looks like a hang. I ran `docker compose up -d`, watched `docker compose ps` show
`server` as `starting` for four minutes, got a 502 from Caddy the whole time, and started
checking the reverse proxy. Nothing was wrong: the container runs the schema setup and every
migration before it opens the port, and the worker sits waiting until the server passes. Watch
`docker compose logs -f server` rather than the browser, and only suspect step 5 once that log
has printed a listening line and the page is still 502.

## 11. Out of scope

- Do not configure SMTP and do not set `EMAIL_DRIVER`. Mail is off, so invitations and password
  resets have nothing to send, which is why step 7 tells you to save that password.
- Do not set `IS_MULTIWORKSPACE_ENABLED`. It reopens signup to every visitor and moves the
  application onto per-workspace subdomains needing a wildcard DNS record.
- Do not configure Google or Microsoft authentication, calendar or messaging sync. Each is an
  OAuth client in somebody else's console.
- Do not set `LOGIC_FUNCTION_TYPE` or `CODE_INTERPRETER_TYPE` to `LOCAL`, and do not add an S3
  bucket. Upstream disables those drivers outside development because they run submitted code on
  the host with no sandbox.
