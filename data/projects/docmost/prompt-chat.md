This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Docmost 0.95.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

One thing to settle before step 1. `<DOMAIN>` becomes `APP_URL`, and Docmost builds every
invitation link and every shared page link out of `APP_URL`. Pick the hostname you intend to
keep, and point its A record at the server now, because the certificate cannot be issued for a
name that does not resolve.

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
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB is the
one to take seriously here: three services share this box, and the container that gets killed
when memory runs out is usually PostgreSQL, which looks like a database bug and is not.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/docmost /srv/docmost/backups
sudo install -d -m 755 -o 1000 -g 1000 /srv/docmost/storage
sudo install -d -m 700 /srv/docmost/postgres /srv/docmost/redis
ls -la /srv/docmost
```

You should see: `backups` owned by you, `storage` owned by uid 1000, and `postgres` and `redis`
at mode `drwx------` owned by root.

If you do not: leave those three owners alone, they are each deliberate. Attachments go into
`storage`, and the Docmost image runs as its base image's `node` user, which is uid 1000, so a
`storage` you own yourself is a directory the app cannot write to. `postgres` and `redis` stay
root-owned because both images chown their own data directory at start-up, and one you have
already chowned to yourself makes PostgreSQL refuse to initialise.

## 3. Secrets

Two secrets: the application secret Docmost signs sessions with, and the PostgreSQL password.
Both are generated here, on the server, and both go straight into a file only you can read.
Upstream states the app refuses to start if `APP_SECRET` keeps its shipped default, and asks
for 32 characters minimum.

```bash
umask 077
cat > /srv/docmost/.env <<EOF
APP_URL=https://<DOMAIN>
APP_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/docmost/.env
umask 022
ls -l /srv/docmost/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately into different shells. Run `chmod 600 /srv/docmost/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
both secrets, which is fine before the database exists and a problem afterwards: PostgreSQL
keeps the password it was created with, so a changed `DB_PASSWORD` against an existing data
directory produces an authentication failure in the Docmost log rather than anything that
mentions passwords.

Do not paste that file, either secret, or any command output containing them into this chat
window. Nothing in this install ever needs you to read a secret out loud.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/docmost/compose.yml <<'EOF'
# Docmost · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installation ....... https://docmost.com/docs/installation
#   variable reference . https://docmost.com/docs/self-hosting/environment-variables
#   reverse proxy ...... https://docmost.com/docs/self-hosting/reverse-proxy
#   caddy notes ........ https://docmost.com/docs/self-hosting/reverse-proxy/caddy
#   image ............. https://github.com/docmost/docmost/blob/main/Dockerfile
#
# Three services: Docmost, the PostgreSQL that holds every page, and the Redis
# that carries the collaborative editor and the job queue. Upstream lists
# DATABASE_URL and REDIS_URL as required, so neither is a nice-to-have here.
# The PostgreSQL 18 image keeps its cluster under /var/lib/postgresql and
# chowns that directory itself on first start, and the Redis image chowns /data
# on every start, so step 2 leaves both root-owned and lets the images sort it
# out. Docmost runs as the node user of its base image, uid 1000, so the
# storage bind mount is created with that owner instead. Tags and digests were
# read from the registries on 2026-08-05; all three images publish amd64 and
# arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: docmost-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: docmost
      POSTGRES_USER: docmost
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/docmost/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U docmost -d docmost"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: docmost-redis
    restart: unless-stopped
    # appendonly writes every change to disk, and noeviction makes Redis refuse
    # writes rather than silently drop a queued job when memory runs out.
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - /srv/docmost/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 6379 never leaves the compose network.

  docmost:
    image: docmost/docmost:0.95.0@sha256:41c8d777cf23c74e78f94e676aec328b7d7856f48df5e573543dac68d371e37c
    container_name: docmost
    restart: unless-stopped
    env_file: /srv/docmost/.env
    environment:
      DATABASE_URL: postgresql://docmost:${DB_PASSWORD}@postgres:5432/docmost
      REDIS_URL: redis://redis:6379
      # Attachments land on this disk, under the bind mount below. No S3
      # bucket, no Azure account, nothing extra to sign up for.
      STORAGE_DRIVER: local
    volumes:
      - /srv/docmost/storage:/app/data/storage
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8092.
      - "127.0.0.1:8092:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/docmost && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/docmost/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal,
so run `rm /srv/docmost/compose.yml` and paste the block again in one go. Compose reads `.env`
from this directory to fill `${DB_PASSWORD}` in two places, the PostgreSQL environment and the
connection string, which is how one generated value ends up in both without you typing it.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-docmost
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Docmost · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docmost.com/docs/self-hosting/reverse-proxy/caddy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_URL in .env, and Docmost builds its invitation links and its shared
# page links from APP_URL, so the two have to say the same thing.

<DOMAIN> {
	encode zstd gzip

	# No X-Frame-Options here on purpose. Docmost decides its own frame
	# header from IFRAME_EMBED_ALLOWED, and one set at this layer would
	# override the application's answer without the application knowing.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8092 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Upstream states the
	# real-time editor rides WebSockets and stays read-only if the proxy
	# does not pass the Upgrade and Connection headers. Caddy's reverse_proxy
	# performs that upgrade with no extra directive, which is the reason this
	# block is three lines rather than thirty.
	reverse_proxy 127.0.0.1:8092
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-docmost /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you replaced in the site line but not in
the comment above it, or the other way round; only the site line matters to Caddy, but a
half-replaced block is a sign the paste was edited by hand mid-flight.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8092`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8092`. 8092 is bound
to 127.0.0.1 by the compose file, and 5432 and 6379 are never published at all, so neither
database has a host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS
and to answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which
Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back
before you go any further.

## 7. Start and verify

Docmost runs its own database migrations on the way up, so the first start is slower than every
one after it.

```bash
cd /srv/docmost
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/workspace/public
```

You should see, in order: the loop reaching `200`, a JSON object containing `"status":"ok"`
with `database` and `redis` both `up`, then `404`.

If you do not: the `404` is the one worth understanding. It means the API is up and telling you
no workspace exists yet, which is exactly right at this point, so seeing it is good news. If the
loop never reaches `200`, run `docker compose logs --tail 20 postgres` first, because a database
that never reports healthy is step 2 done wrong, and `docker compose logs --tail 40 docmost`
second. A `502` from Caddy with healthy containers points at step 5 instead.

The first screen at https://<DOMAIN>/setup/register shows the heading `Create workspace` above
fields for a workspace name, a name, an email and a password of at least 8 characters. Open it,
create your workspace and your own account, and come back. That account becomes the workspace
owner. Then prove that first-run registration is now closed to everyone else:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/workspace/public
curl -sS -w '\n%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' https://<DOMAIN>/api/auth/setup
```

You should see: `200` from the first, then a 403 body containing
`Workspace setup already completed.` from the second.

If you do not: a second `404` means the account was not actually created, so go back to the
setup page. Anything other than that 403 message from the second command is the one result here
worth stopping for, because it would mean a stranger who finds this hostname can still create an
owner account on your wiki. A running container is not success; these two lines are.

## 8. First backup and restore

Two artifacts. The database holds every page, space, user and permission. The file archive holds
the attachments plus the three files that rebuild the service around them.

```bash
cd /srv/docmost
docker compose exec -T postgres pg_dump -U docmost -d docmost | gzip > /srv/docmost/backups/docmost-db-$(date +%F).sql.gz
sudo tar -czf /srv/docmost/backups/docmost-files-$(date +%F).tar.gz -C /srv/docmost storage compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/docmost/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently. Redis is not in the backup on purpose, as
it holds live editor sessions and queued jobs rather than content.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/docmost
scp vps:/srv/docmost/backups/* ~/backups/docmost/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/docmost/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a page you wrote five minutes ago:

```bash
cd /srv/docmost
docker compose down
sudo rm -rf /srv/docmost/postgres
sudo install -d -m 700 /srv/docmost/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/docmost/backups/docmost-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U docmost -d docmost
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/workspace/public
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command, and
your pages still there when you reload the browser.

If you do not: `role "docmost" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. The `.env` in the file archive
matters as much as the dump, because PostgreSQL keeps the password it was created with and a
restore under a different `DB_PASSWORD` fails with an authentication error that never mentions
passwords.

## 9. Updating later

New versions are listed at https://github.com/docmost/docmost/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/docmost/compose.yml to the new tag and its
digest.

```bash
cd /srv/docmost
docker compose pull
docker compose up -d
docker compose logs --tail 30 docmost
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one real page as well,
because a service that answers `"status":"ok"` on health can still be failing to render content
if a migration stopped halfway.

## 10. What will probably go wrong

Attachments, and not until later. On my first run I left /srv/docmost/storage owned by root, the
containers started, the health endpoint answered `"status":"ok"`, pages saved, and everything
looked finished. The first image I dragged into a page failed with a server error, and the only
trace was an `EACCES` line in the Docmost log. Health checks the database and Redis and never
touches the storage directory, so nothing warns you. If uploads fail, run
`ls -ld /srv/docmost/storage` and confirm it is owned by uid 1000 before looking anywhere else.

## 11. Out of scope

- Do not configure SMTP. Docmost runs without mail, and invitations can be handed out as links
  copied from the members page. Password resets are the thing you give up until you add a mail
  provider.
- Do not switch `STORAGE_DRIVER` to s3 or azure. That is a second vendor account, and the backup
  in step 8 assumes attachments are on this disk.
- Do not add a license key and do not enable the enterprise features. Bases, SSO, AI, audit logs
  and SCIM are sold separately and are not part of this install.
- Do not set `AI_DRIVER`, `OPENAI_API_KEY` or any other model credential. Nothing here needs a
  model to store a page.
