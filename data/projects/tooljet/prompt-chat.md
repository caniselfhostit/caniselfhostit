This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing ToolJet v3.20.208-lts, the community edition, on a VPS where Prompt Zero is
done: `ssh vps` works, Docker and Caddy are installed, the firewall is default-deny. Run
everything over `ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname
whose A record already points at the box.

Read this before step 1. `<DOMAIN>` becomes `TOOLJET_HOST`, the address the server compares
request origins against and the one every link it builds carries. Changing it later means editing
a file and recreating containers, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64`, and your server's IP
on the last line.

If you do not: `arm64` on the third line is the one that ends the install here. ToolJet publishes
its community-edition image for amd64 only, and a Linux VPS has no emulation layer to fall back
on, so rebuild the box on an amd64 plan rather than trying to force the pull. An empty last line
means the A record does not exist yet: add it, wait a minute, run `dig +short <DOMAIN>` again,
because Caddy cannot get a certificate for a hostname that does not resolve and failed attempts
count against a rate limit you cannot see. Under 4096 MB of RAM, resize the box rather than
continuing. Upstream sizes the application machine at 4 GB and a separate database machine at
8 GB, and this install puts both on one box, so 4 GB is where it starts rather than where it is
comfortable.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/tooljet /srv/tooljet/backups
sudo install -d -m 700 /srv/tooljet/postgres
ls -la /srv/tooljet
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. There is no directory for ToolJet itself, because every app, query, datasource and
user is a row in that database.

## 3. Secrets

Four secrets: the lockbox master key that encrypts datasource credentials, the application secret
key that signs sessions, the PostgreSQL password and the PostgREST JWT secret. All four are
generated here, on the server, and all four go straight into a file only you can read. Replace
`<DOMAIN>` on the first line before you paste.

```bash
umask 077
cat > /srv/tooljet/.env <<EOF
TOOLJET_HOST=https://<DOMAIN>
LOCKBOX_MASTER_KEY=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 64)
PG_PASS=$(openssl rand -hex 32)
PGRST_JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/tooljet/.env
umask 022
ls -l /srv/tooljet/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. The lengths are the ones
upstream documents for each variable.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/tooljet/.env` and carry on.
If the file already existed from an earlier attempt, this block has now overwritten all four,
which is fine before the database exists and a problem afterwards: PostgreSQL keeps the password
it was created with, so a changed `PG_PASS` on an existing volume shows up as the ToolJet
container sitting at `wait-for-it` rather than as anything about passwords.

Read `LOCKBOX_MASTER_KEY` once, with `sudo grep LOCKBOX_MASTER_KEY /srv/tooljet/.env`, and put it
in your password manager tonight. It encrypts every database password, API key and token you hand
to a datasource, so a database restored without it comes back with every app intact and nothing
able to connect.

Do not paste that file, any of those four values, or any command output containing them into this
chat window. No human ever signs in with any of them: the password you choose in step 7, in a
browser, is the only one you type again.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/tooljet/compose.yml <<'EOF'
# ToolJet · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker deployment .. https://docs.tooljet.ai/docs/setup/docker/
#   variable reference . https://docs.tooljet.ai/docs/setup/env-vars/
#   sizing ............. https://docs.tooljet.ai/docs/setup/system-requirements/
#   tooljet database ... https://docs.tooljet.ai/docs/tooljet-db/tooljet-database/
#
# Upstream's in-built-PostgreSQL deployment in our layout: the ToolJet server,
# one PostgreSQL holding the three databases it makes for itself, and the
# PostgREST the ToolJet Database is read through. No Redis service: the -ce
# image starts one in its own container. -ce is the community edition, the tree
# AGPL-3.0 covers; the paid half sits in two private git submodules. Digests
# read 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: tooljet-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: tooljet_production
      POSTGRES_USER: tooljet
      POSTGRES_PASSWORD: ${PG_PASS}
    volumes:
      - /srv/tooljet/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U tooljet -d tooljet_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  tooljet:
    image: tooljet/tooljet-ce:v3.20.208-lts@sha256:78cb01a47c2a0f5efde54ebf2ff3d4c704c1523e1a6b497df65697028701f3c9
    container_name: tooljet
    restart: unless-stopped
    # amd64 only, named rather than guessed. PORT is 3000, not 80, because
    # this image runs as a non-root user.
    platform: linux/amd64
    env_file: /srv/tooljet/.env
    command: ["npm", "run", "start:prod"]
    environment:
      SERVE_CLIENT: "true"
      PORT: "3000"
      # Three databases are made on the first boot.
      PG_HOST: postgres
      PG_USER: tooljet
      PG_DB: tooljet_production
      TOOLJET_DB_HOST: postgres
      TOOLJET_DB_USER: tooljet
      TOOLJET_DB_PASS: ${PG_PASS}
      TOOLJET_DB: tooljet_db
      PGRST_HOST: http://postgrest:3000
      # No browser makes an account except the first administrator's, and
      # neither of the next two phones home, which upstream ships them doing.
      DISABLE_SIGNUPS: "true"
      DISABLE_TOOLJET_TELEMETRY: "true"
      CHECK_FOR_UPDATES: "false"
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8176.
      - "127.0.0.1:8176:3000"
    depends_on:
      postgres:
        condition: service_healthy

  postgrest:
    image: postgrest/postgrest:v12.2.0@sha256:2cf1efd2c9c2e7606610c113cc73e936d8ce9ba089271cb9cbf11aa564bc30c7
    container_name: tooljet-postgrest
    restart: unless-stopped
    environment:
      PGRST_DB_URI: postgres://tooljet:${PG_PASS}@postgres:5432/tooljet_db
      PGRST_JWT_SECRET: ${PGRST_JWT_SECRET}
      PGRST_DB_PRE_CONFIG: postgrest.pre_config
    depends_on:
      postgres:
        condition: service_healthy
    # Restarts until ToolJet's first boot has made tooljet_db and its
    # postgrest.pre_config function. No `ports:` here either.
EOF
cd /srv/tooljet && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/tooljet/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/tooljet/compose.yml` and paste again in one go. The `postgrest` service is not
optional scenery. It is what turns the ToolJet Database, the built-in place you can keep tables
without connecting an outside database, into the REST API the builder reads it through. There is
no Redis service because the community-edition image starts one inside its own container.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-tooljet
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# ToolJet · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://docs.tooljet.ai/docs/setup/docker/
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also TOOLJET_HOST in .env.

<DOMAIN> {
	# ToolJet sends a Content-Security-Policy carrying `frame-ancestors *`,
	# which lets any site load this editor in an iframe. This rewrites that
	# one directive with a regular expression and leaves the rest alone.
	header Content-Security-Policy "frame-ancestors [^;]+" "frame-ancestors 'self'"

	header {
		# Nothing in the container knows it is served over https.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8176 is the loopback port compose publishes here, not a container port
	# and not open in the firewall. reverse_proxy carries the editor's
	# multiplayer WebSocket with no extra configuration.
	reverse_proxy 127.0.0.1:8176
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-tooljet /etc/caddy/Caddyfile`, reload, and
paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the other.
Caddy asks for the certificate on the first request and renews it itself, so there is nothing here
to schedule. The three-argument `header` line is a find-and-replace on the policy ToolJet sends:
its own Content-Security-Policy carries `frame-ancestors *`, which would let any site on the
internet load your editor and your apps in an iframe, and this narrows that one directive to your
own origin without touching the rest.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8176`, `5432` or `3000`.

If you do not: delete anything for those three with `sudo ufw delete allow 8176`. 8176 is bound to
127.0.0.1 by the compose file, and PostgreSQL and PostgREST publish no host port at all, unlike
upstream's own example compose file which publishes the application on the host's port 80. 80/tcp
is there to redirect to HTTPS and to answer the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem:
Prompt Zero left this firewall enabled, so something has turned it off since, and `sudo ufw enable`
puts it back before you go further.

## 7. Start and verify

The first boot is slow. The image is about 3 GB, then the server waits for PostgreSQL, creates
three databases and runs its migrations before it answers anything.

```bash
cd /srv/tooljet
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/health
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/onboarding/signup
docker compose exec -T postgres psql -U tooljet -d tooljet_db -tAc "select count(*) from pg_proc where proname='pre_config'"
```

You should see, in order: the loop reaching `200`, then a small JSON object containing
`"works":"yeah"`, then `403`, then `1`.

If you do not: the `403` is the one worth understanding. It means open signup is refused, which is
what this install wants, and it is the security check in this block. A `201` there would mean
anyone on the internet can create an account on your instance. The JSON from the health endpoint
also reports the licence as invalid and expired: that is the community edition answering honestly,
not a fault, and nothing here needs a licence key. If the loop never reaches `200`, run
`docker compose logs --tail 40 postgres` first, because a database that never reports healthy is
step 2 done wrong, and `docker compose logs --tail 60 tooljet` second. A ToolJet log that sits on
`wait-for-it` is step 3's password not matching a database volume left from an earlier attempt. A
running container is not success.

If the last command printed `0` instead of `1`, ToolJet has not finished creating the ToolJet
Database yet, and PostgREST will be restarting in a loop until it does. Wait two minutes and run
that one line again.

The first screen at https://<DOMAIN> is the setup form, headed `Set up your admin account`, over
fields for `Name`, `Email` and a password and a `Sign up` button. Your browser draws that heading,
which is why the checks above go to the API instead.

Open https://<DOMAIN> in a browser now and fill that form in. It runs once, and it makes the only
administrator this install has. Put the password in your password manager as you type it, because
there is no SMTP configured here and therefore no password-reset email to fall back on.

Then prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/onboarding/setup-super-admin
```

You should see: `403`.

If you do not: a `400` means the first-account form has not been completed, because that endpoint
answers `400` on an empty body while it is still open and `403` once an administrator exists. Go
back to the browser and finish it. That form is the one moment this install would accept an
administrator from anyone who could reach the URL, and closing it is the point of this check.

## 8. First backup and restore

Two artifacts. The database holds every app, query, datasource and user. The config archive holds
the files that rebuild the service around them, and the key that decrypts the credentials in it.

```bash
cd /srv/tooljet
docker compose exec -T postgres pg_dumpall -U tooljet | gzip > /srv/tooljet/backups/tooljet-db-$(date +%F).sql.gz
sudo tar -czf /srv/tooljet/backups/tooljet-config-$(date +%F).tar.gz -C /srv/tooljet compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/tooljet/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline, because
the dump snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dumpall` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.
`pg_dumpall` rather than `pg_dump` on purpose: there are three databases in that container, and
the ToolJet Database is one of them.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/tooljet
scp vps:/srv/tooljet/backups/* ~/backups/tooljet/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/tooljet/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/tooljet
docker compose down
sudo rm -rf /srv/tooljet/postgres
sudo install -d -m 700 /srv/tooljet/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/tooljet/backups/tooljet-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U tooljet -d postgres
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/health
```

You should see: `CREATE DATABASE`, `CREATE TABLE` and `COPY` lines from psql, then `200` from the
last command, and your administrator account still works when you sign in.

If you do not: `role "tooljet" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the config archive
is for before you skip it: it carries `.env`, and `LOCKBOX_MASTER_KEY` in that file is what
decrypts every datasource credential in the dump. Restore a database next to a freshly generated
key and you get back every app you built and not one working connection.

## 9. Updating later

New versions are listed at https://github.com/ToolJet/ToolJet/releases. Stay on the `-lts` line:
tags ending `-beta` are the pre-release channel and upstream advises against them for real use.
Take both backup artifacts first, then edit the ToolJet image line in /srv/tooljet/compose.yml to
the new tag and its digest.

```bash
cd /srv/tooljet
docker compose pull
docker compose up -d
docker compose logs --tail 40 tooljet
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one of your apps as well,
because a server that answers `"works":"yeah"` can still be failing on a migration that stopped
halfway.

## 10. What will probably go wrong

PostgREST. For the first few minutes of the very first boot it exits and restarts every few
seconds, and `docker compose ps` shows it flapping while everything else looks fine. I read that
log, saw a connection error naming a database that did not exist, and checked the password three
times. Nothing was wrong: ToolJet makes `tooljet_db` and the `postgrest.pre_config` function
inside it during its own first boot, and PostgREST cannot start until both exist. The fourth check
in step 7 is what tells you it has settled. If it still restarts after that check prints `1`,
`docker compose logs --tail 30 postgrest` will say why.

## 11. Out of scope

- Do not set `TJ_LICENSE` and do not switch to the `tooljet/tooljet-ee` image. This install is the
  community edition, the AGPL-3.0 one.
- Do not configure SMTP. ToolJet builds and serves apps without it; the cost is invitation and
  password-reset email, a trade you make later.
- Do not add a Redis service or set `WORKER=true`. Those belong to the multi-worker workflow
  deployment; this install runs one server with the Redis its own image starts.
- Do not set `ENABLE_CORS` or `ENABLE_CUSTOM_DOMAINS`. The first opens the API to every origin,
  the second changes the cookie policy this install depends on.
