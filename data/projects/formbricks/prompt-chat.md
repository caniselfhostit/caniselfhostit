This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Formbricks 5.3.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` becomes `WEBAPP_URL`, the front of every survey link you
send out, so a link already sitting in somebody's inbox stops working if you change it later.
Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line. That RAM floor is upstream's own Helm limits added up: 2 GB web,
1 GB Cube, 512 MB Hub, 192 MB Valkey, plus PostgreSQL.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve and failed attempts count against a rate limit you cannot see. Under 4096 MB available
is the one number not to argue with: five services on a 2 GB box means the kernel picks which
one dies, and it usually picks the web app after ten minutes of looking fine.

## 2. Layout

Cube reads two files upstream ships in their repository, not in their image. This block makes
the tree, fetches both at the pinned tag, and checks them against digests recorded on
2026-08-06.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/formbricks /srv/formbricks/backups /srv/formbricks/cube /srv/formbricks/cube/schema
sudo install -d -m 700 /srv/formbricks/postgres /srv/formbricks/redis
cd /srv/formbricks/cube
for f in cube.js schema/FeedbackRecords.js; do curl -fsSL -o "$f" "https://raw.githubusercontent.com/formbricks/formbricks/5.3.0/docker/cube/$f"; done
cat > SHA256SUMS <<'EOF'
723eea0f581200a686f854ff47b38f2e92bbfe5d802338049afaa061f154a335  cube.js
c3322a3739ee1cc57224139f502395a20dcbe4dd71e331be41d687ffdfe140f8  schema/FeedbackRecords.js
EOF
sha256sum -c SHA256SUMS
ls -la /srv/formbricks
```

You should see: `cube.js: OK` and `schema/FeedbackRecords.js: OK`, then a listing with `backups`
and `cube` owned by you and `postgres` and `redis` at `drwx------` owned by root.

If you do not: `FAILED` means the bytes on disk are not the bytes we recorded, so stop there,
because this is configuration for a service that queries your database. Leave `postgres` and
`redis` owned by root on purpose: both images chown their own data directory the first time they
start, and one you have already chowned to yourself makes PostgreSQL refuse to initialise.

## 3. Secrets

Six secrets: the PostgreSQL password and five keys the application requires. All six are
generated here, on the server, straight into a file only you can read. Replace `<DOMAIN>` on the
first two lines with your real hostname before you paste.

```bash
umask 077
cat > /srv/formbricks/.env <<EOF
WEBAPP_URL=https://<DOMAIN>
NEXTAUTH_URL=https://<DOMAIN>
DB_PASSWORD=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
CRON_SECRET=$(openssl rand -hex 32)
HUB_API_KEY=$(openssl rand -hex 32)
CUBEJS_API_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/formbricks/.env
umask 022
ls -l /srv/formbricks/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: `-rw-r--r--` means `umask 077` did not take effect, which happens if you pasted
the lines separately in different shells. Run `chmod 600 /srv/formbricks/.env` and carry on. If
the file already existed from an earlier attempt this block has overwritten all six values,
which is fine before the database exists and a problem afterwards: PostgreSQL keeps the password
it was created with, so a changed `DB_PASSWORD` on an existing volume shows up as an
authentication failure in the app log rather than as anything about passwords.

Do not paste that file, any of those six values, or any command output containing them into this
chat window. `ENCRYPTION_KEY` is the one to understand: upstream uses it for two-factor secrets,
single-use survey links and audit-log hashing, so a database restored without this exact file is
one you cannot fully read.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/formbricks/compose.yml <<'EOF'
# Formbricks · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose setup ....... https://formbricks.com/docs/self-hosting/setup/docker
#   variable reference .. https://formbricks.com/docs/self-hosting/configuration/environment-variables
#
# Seven services: five that stay up, two migration jobs that run in order and
# exit. Upstream makes Hub, Cube and Valkey mandatory in version 5. Only 8110
# is published, on loopback. Digests read 2026-08-06, all five multi-arch.
#
# Three deliberate trims from upstream's compose: no validate-env prefix on
# the migrate job (the web container runs it at startup), no direct postgres
# depends_on for hub and cube (the migration chain already gates them), and
# no saml-connection mount (paid edition, out of scope).
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: formbricks

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg18@sha256:691673308c99d2161ba298736f3147f1f22d79de2fb7ec93ae9b4afcab870b62
    restart: unless-stopped
    environment:
      POSTGRES_DB: formbricks
      POSTGRES_USER: formbricks
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/formbricks/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U formbricks -d formbricks"]
      interval: 10s
      retries: 30

  redis:
    image: valkey/valkey:9.0.5-alpine@sha256:0cb61366757e2bcd26500b4e8bb63cbd7117610e3e4f05aacb3c812511da7632
    restart: unless-stopped
    command: ["valkey-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - /srv/formbricks/redis:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 30

  formbricks-migrate:
    image: ghcr.io/formbricks/formbricks:5.3.0@sha256:d79dba3668a359b63d984ac39b19a58fb6746b3aed57fd890b9f2f6f372210e6
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?schema=public
    command: ["node", "packages/database/dist/scripts/apply-migrations.js"]
    depends_on:
      postgres:
        condition: service_healthy

  hub-migrate:
    image: ghcr.io/formbricks/hub:0.8.3@sha256:4dc0c4f26cf999b3bf4a26d7b09634fc65ae23cbb30c9ad82042da019d231458
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?sslmode=disable
    entrypoint: ["sh", "-c"]
    command: ['/usr/local/bin/goose -dir /app/migrations postgres "$$DATABASE_URL" up && /usr/local/bin/river migrate-up --database-url "$$DATABASE_URL"']
    depends_on:
      formbricks-migrate:
        condition: service_completed_successfully

  hub:
    image: ghcr.io/formbricks/hub:0.8.3@sha256:4dc0c4f26cf999b3bf4a26d7b09634fc65ae23cbb30c9ad82042da019d231458
    restart: unless-stopped
    environment:
      API_KEY: ${HUB_API_KEY}
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?sslmode=disable
    depends_on:
      hub-migrate:
        condition: service_completed_successfully

  cube:
    image: cubejs/cube:v1.6.6@sha256:746a381c5deb1f33500c84bed357ebe68aa08acc5030939f9e9efd35796d368c
    restart: unless-stopped
    environment:
      CUBEJS_DB_TYPE: postgres
      CUBEJS_DB_HOST: postgres
      CUBEJS_DB_NAME: formbricks
      CUBEJS_DB_USER: formbricks
      CUBEJS_DB_PASS: ${DB_PASSWORD}
      CUBEJS_API_SECRET: ${CUBEJS_API_SECRET}
      CUBEJS_JWT_ISSUER: formbricks-web
      CUBEJS_JWT_AUDIENCE: formbricks-cube
      CUBEJS_DEFAULT_API_SCOPES: meta,data
      CUBEJS_EXTERNAL_DEFAULT: "false"
      CUBEJS_CACHE_AND_QUEUE_DRIVER: memory
    volumes:
      - /srv/formbricks/cube/cube.js:/cube/conf/cube.js:ro
      - /srv/formbricks/cube/schema:/cube/conf/model:ro
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:4000/readyz', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: 10s
      retries: 18
      start_period: 40s
    depends_on:
      hub-migrate:
        condition: service_completed_successfully

  formbricks:
    image: ghcr.io/formbricks/formbricks:5.3.0@sha256:d79dba3668a359b63d984ac39b19a58fb6746b3aed57fd890b9f2f6f372210e6
    restart: unless-stopped
    env_file: /srv/formbricks/.env
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?schema=public
      REDIS_URL: redis://redis:6379
      HUB_API_URL: http://hub:8080
      CUBEJS_API_URL: http://cube:4000
      EMAIL_VERIFICATION_DISABLED: "1"
      PASSWORD_RESET_DISABLED: ${PASSWORD_RESET_DISABLED:-1}
      SKIP_STARTUP_MIGRATION: "true"
    ports:
      - "127.0.0.1:8110:3000"
    depends_on:
      formbricks-migrate:
        condition: service_completed_successfully
      redis:
        condition: service_healthy
      cube:
        condition: service_healthy
      hub:
        condition: service_started
EOF
cd /srv/formbricks && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/formbricks/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/formbricks/compose.yml` and paste again in one go. Nothing in this file is
optional. Upstream moved Hub and Cube into the baseline stack at version 5, and the web
container will not start without a Redis URL, so there is no smaller version of this that works.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-formbricks
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Formbricks · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://formbricks.com/docs/self-hosting/configuration/domain-configuration
# and https://caddyserver.com/docs/automatic-https

<DOMAIN> {
	# No X-Frame-Options and no frame-ancestors on purpose: link surveys are
	# meant to be embedded in other people's pages.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8110 is the loopback port compose publishes. Not open in the firewall.
	reverse_proxy 127.0.0.1:8110
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-formbricks /etc/caddy/Caddyfile`, reload,
and paste again. There is deliberately no `X-Frame-Options` in that block: link surveys are meant
to be embedded in other people's pages, and a deny would break the one distribution channel this
software exists for.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8110`, `5432`, `6379`, `8080` or `4000`.

If you do not: delete anything for those five with `sudo ufw delete allow 8110`. 8110 is bound
to 127.0.0.1 by the compose file, and the database, the queue, Hub and Cube publish no host port
at all, so none of them has a port a firewall rule could apply to. 80/tcp is there to redirect
to HTTPS and answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3.
`Status: inactive` is a different problem: Prompt Zero left this firewall on, so something has
turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The two migration jobs run and exit first, then Cube has to report healthy before the web
container is allowed to start. On a first pull the whole step takes several minutes, so let the
loop run.

```bash
cd /srv/formbricks
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -c 'Welcome to Formbricks'
docker compose ps -a
```

You should see, in order: the loop reaching `200`, then `{"status":"ok"}`, then
`https://<DOMAIN>/setup/intro`, then a count of at least `1`, then a table where
`formbricks-migrate` and `formbricks-hub-migrate` say `exited (0)` and the other five are up.

If you do not: a `formbricks-hub-migrate` that exited non-zero points back at step 3, where an
empty `DB_PASSWORD` makes every connection string wrong. A `cube` container stuck in `starting`
points at step 2, where a failed checksum leaves it with no model to serve. Read
`docker compose logs --tail 40 formbricks` and `docker compose logs --tail 20 cube hub-migrate`
before changing anything. Containers being up is not the same as the app answering.

Now open https://<DOMAIN> in a browser. The first screen carries the heading
`Welcome to Formbricks!` above a `Get started` button. Click it and create your administrator
account and organization. This is the only moment that account can be made: upstream keeps
signup closed on self-hosted instances, and afterwards only an owner or admin can invite anyone.
There is no SMTP server here, so there is no password-reset mail either. Put the email and
password in your password manager before you click anything else.

Then prove the door shut behind you:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup/intro
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/
```

You should see: `404`, then `https://<DOMAIN>/auth/login`.

If you do not: a `200` from the first command means the account was never created, so go back
and finish the wizard. The setup pages answer only while the user table is empty, which is what
makes this pair of commands worth running rather than trusting.

## 8. First backup and restore

Two artifacts. The database holds every survey, every response and every account. The config
archive holds what rebuilds the service around them, `ENCRYPTION_KEY` included.

```bash
cd /srv/formbricks
docker compose exec -T postgres pg_dump -U formbricks -d formbricks | gzip > /srv/formbricks/backups/formbricks-db-$(date +%F).sql.gz
sudo tar -czf /srv/formbricks/backups/formbricks-config-$(date +%F).tar.gz -C /srv/formbricks compose.yml .env cube -C /etc/caddy Caddyfile
ls -lh /srv/formbricks/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently. Valkey is not in the backup on purpose, it
holds cache and in-flight jobs rather than your data.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/formbricks
scp vps:/srv/formbricks/backups/* ~/backups/formbricks/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/formbricks/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty account:

```bash
cd /srv/formbricks
docker compose down
sudo rm -rf /srv/formbricks/postgres
sudo install -d -m 700 /srv/formbricks/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/formbricks/backups/formbricks-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U formbricks -d formbricks
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/health
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `{"status":"ok"}`, and you
should be able to log in with the account you made in step 7.

If you do not: `role "formbricks" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the two files are
for before you skip this: the dump without the `.env` gives you rows you cannot decrypt, so they
are one backup in two pieces and they travel together.

## 9. Updating later

Releases are listed at https://github.com/formbricks/formbricks/releases, and the Hub and Cube
versions that pair with each one are in `charts/formbricks/values.yaml` inside that same tag.
Take both backup artifacts first, then edit the `image:` lines in /srv/formbricks/compose.yml to
the new tags and digests.

```bash
cd /srv/formbricks
docker compose pull
docker compose up -d
docker compose logs --tail 40 formbricks-migrate hub-migrate formbricks
```

You should see: both migration jobs exiting 0, then the app starting, and no repeating restart.

If you do not: put the old tags and digests back and run the same three commands. Then re-run
the health check from step 7 before you call the update done, because a stack that answers
`{"status":"ok"}` can still be failing if a migration stopped halfway.

## 10. What will probably go wrong

The wait. I brought this up on a 4 GB box, saw two containers in `Created` and one `starting`,
and went looking for what I had broken. Nothing was: the app is gated on Cube being healthy,
Cube has a 40 second start period before its first check counts, and is gated on both migration
jobs finishing. That chain ran past six minutes before /health answered. Let the loop in step 7
run all forty times before deciding it is broken.

## 11. Out of scope

- Do not configure SMTP. `EMAIL_VERIFICATION_DISABLED` and `PASSWORD_RESET_DISABLED` are 1,
  upstream's default, and the survey loop needs no mail.
- Do not configure S3 or the bundled RustFS storage. That is a second subdomain and another
  service; without it the file-upload and image questions stay off.
- Do not enable the `qwen` or `taxonomy` profiles, set `ENTERPRISE_LICENSE_KEY`, or configure
  SSO, SAML or OIDC. The AI profiles are opt-in and one wants an NVIDIA GPU; the rest is the
  paid edition, and this is the community one.
