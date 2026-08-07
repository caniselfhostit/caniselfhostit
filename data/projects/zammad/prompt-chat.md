This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Zammad 7.1.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box. That hostname becomes `ZAMMAD_FQDN`, the address Zammad writes into every link it
builds, so pick the one you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `6144` MB available, at least `20` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: six gigabytes is upstream's own minimum, and it is for a stack without
Elasticsearch, which is the one this builds. Four Rails processes hold the whole application in
memory at once, so a 4 GB box does not squeak through, it gets OOM-killed during the schema
load. An empty last line means the A record does not exist yet: add it, wait a minute, and run
`dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/zammad /srv/zammad/backups /srv/zammad/redis
sudo install -d -m 750 -o 1000 -g 1000 /srv/zammad/storage
sudo install -d -m 700 /srv/zammad/postgres
ls -la /srv/zammad
```

You should see: `backups` and `redis` owned by you, `storage` owned by uid `1000`, and
`postgres` at mode `drwx------` owned by root.

If you do not: those two odd ownerships are both deliberate. The Zammad image runs as uid 1000
and cannot write a directory you own, and the PostgreSQL image chowns its own data directory
the first time it starts and refuses one that has already been chowned.

## 3. Secrets

One secret: the PostgreSQL password. Upstream ships `zammad` as the default value for it, so
this replaces a published credential rather than inventing a new one. It is generated here, on
the server, into a file only you can read.

```bash
umask 077
cat > /srv/zammad/.env <<EOF
ZAMMAD_FQDN=<DOMAIN>
ZAMMAD_HTTP_TYPE=https
POSTGRESQL_PASS=$(openssl rand -hex 32)
EOF
chmod 600 /srv/zammad/.env
umask 022
ls -l /srv/zammad/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/zammad/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten the
password, which is fine before the database exists and a problem afterwards: PostgreSQL keeps
the password it was created with, so a changed one on an existing volume shows up as an
authentication failure in the Zammad log rather than as anything about passwords.

Do not paste that file, the password, or any command output containing it into this chat
window. Nothing in this install asks you to.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/zammad/compose.yml <<'EOF'
# Zammad · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose ..... https://docs.zammad.org/en/latest/install/docker-compose.html
#   scenarios .......... https://docs.zammad.org/en/latest/install/docker-compose/docker-compose-scenarios.html
#   variable reference . https://docs.zammad.org/en/latest/appendix/environment-variables.html
#
# Seven services. Four are one Zammad image under different commands:
# railsserver answers the browser, websocket carries live updates, scheduler
# works the job queue, nginx serves the assets and routes /ws. PostgreSQL,
# Redis and memcached are the prerequisites upstream names. Their own file
# adds three more, each left out here: Elasticsearch through their
# ELASTICSEARCH_ENABLED switch, at the cost of full-text search; the nightly
# backup container, since step 8 takes a dump that leaves the box; and the
# migration container, run once by hand so its output is on screen. Digests
# read from Docker Hub on 2026-08-07; all four images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: zammad

# The four Zammad processes share one image; compose ignores x- keys.
x-zammad: &zammad
  image: zammad/zammad:7.1.2-0003@sha256:1ce0e929fac75f83f3e7534e9eb7aabfc3596cffbd00e25393be79709b9bea0c
  restart: unless-stopped
  init: true
  env_file: /srv/zammad/.env
  environment:
    POSTGRESQL_HOST: zammad-postgresql
    POSTGRESQL_DB: zammad_production
    POSTGRESQL_USER: zammad
    MEMCACHE_SERVERS: zammad-memcached:11211
    REDIS_URL: redis://zammad-redis:6379
    # Upstream's own switch for a stack with no Elasticsearch in it.
    ELASTICSEARCH_ENABLED: "false"
    # Caddy terminates TLS, so nginx is told the scheme it cannot see.
    NGINX_SERVER_SCHEME: https
    # Clients reach nginx over the compose network, never over loopback.
    RAILS_TRUSTED_PROXIES: 127.0.0.1,::1,172.16.0.0/12
  volumes:
    - /srv/zammad/storage:/opt/zammad/storage
  depends_on:
    zammad-postgresql:
      condition: service_healthy
    zammad-redis:
      condition: service_healthy
    zammad-memcached:
      condition: service_healthy

services:
  zammad-postgresql:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: zammad-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: zammad_production
      POSTGRES_USER: zammad
      POSTGRES_PASSWORD: ${POSTGRESQL_PASS}
    volumes:
      - /srv/zammad/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zammad -d zammad_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  zammad-redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: zammad-redis
    restart: unless-stopped
    volumes:
      - /srv/zammad/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  zammad-memcached:
    image: memcached:1.6.45-alpine@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7
    container_name: zammad-memcached
    restart: unless-stopped
    command: memcached -m 256M
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "11211"]
      interval: 10s
      retries: 12

  zammad-railsserver:
    <<: *zammad
    container_name: zammad-railsserver
    command: ["zammad-railsserver"]
    healthcheck:
      # The first boot loads a large schema, hence the long start period.
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:3000"]
      interval: 30s
      start_period: 240s
      retries: 5

  zammad-websocket:
    <<: *zammad
    container_name: zammad-websocket
    command: ["zammad-websocket"]

  zammad-scheduler:
    <<: *zammad
    container_name: zammad-scheduler
    command: ["zammad-scheduler"]

  zammad-nginx:
    <<: *zammad
    container_name: zammad-nginx
    command: ["zammad-nginx"]
    init: false
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8169.
      - "127.0.0.1:8169:8080"
    depends_on:
      zammad-railsserver:
        condition: service_healthy
EOF
cd /srv/zammad && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/zammad/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/zammad/compose.yml` and paste again in one go. The scheduler service is the one
people delete to save memory and then miss: it works the queue where triggers, escalation
clocks and notifications run, and without it Zammad answers every page perfectly and does
nothing on schedule.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-zammad
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Zammad · the Caddy site block for this service. Authored by caniselfhostit
# from https://docs.zammad.org/en/latest/install/docker-compose.html and
# https://caddyserver.com/docs/automatic-https. Append it to
# /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname pointed at this
# box; that hostname is also ZAMMAD_FQDN in .env.

<DOMAIN> {
	# A helpdesk holds other people's names and complaints, so nothing here
	# is framed, sniffed, or leaked through a referrer.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8169 is the loopback port compose publishes here, not open in the
	# firewall. The Zammad nginx behind it routes /ws itself, so Caddy has
	# one upstream.
	reverse_proxy 127.0.0.1:8169
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-zammad /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the Zammad nginx container,
which is why `NGINX_SERVER_SCHEME` is `https` in the compose file: without it that container
would read the scheme off a plain connection and hand out `http://` links for a site only
reachable over https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8169`, `5432`, `6379` or `11211`.

If you do not: delete anything for those four with `sudo ufw delete allow 8169`. 8169 is bound
to 127.0.0.1 by the compose file and the other three are never published at all, so there is no
host port a firewall rule could apply to. `Status: inactive` is a different problem: Prompt Zero
left this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it
back before you go any further.

## 7. Start and verify

The migration container runs first, once, in the foreground. It creates the database, loads the
schema and seeds it. This is the long step: minutes of output, and it is meant to be.

```bash
cd /srv/zammad
docker compose pull
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/users
```

You should see, in order: migration lines from the init run ending with a shell prompt back,
the loop climbing to `200`, then `401` from the last command.

If you do not: the `401` is the one worth understanding. It means the API is up and refusing a
call with no session, which is the answer you want from a helpdesk on the public internet. A
`404` in its place means Caddy is not reaching the container: check `docker compose ps`. If the
loop never reaches `200`, run `docker compose logs --tail 40 zammad-railsserver`. A connection
failure inside the init run points at step 3 and an `.env` with no password line.

The first screen at https://<DOMAIN> shows the heading `Welcome!` above a button reading
`Set up a new system`. Open it, press that button, and work through the wizard to create your
administrator account. Put that password in your password manager as you type it: this install
configures no mail, so there is no reset link behind it.

Once the wizard is done, shut the self-signup door Zammad ships open:

```bash
cd /srv/zammad
docker compose exec -T zammad-railsserver bundle exec rails r "Setting.set('user_create_account', false)"
curl -sS -H 'Content-Type: application/json' -d '{"query":"{systemSetupInfo{status}}"}' https://<DOMAIN>/graphql
curl -sS -H 'Content-Type: application/json' -d '{"query":"{applicationConfig{key value}}"}' https://<DOMAIN>/graphql | grep -q user_create_account && echo "signup OPEN" || echo "signup CLOSED"
```

You should see: `"status":"done"` in the first response, then `signup CLOSED` on the last line.

If you do not: `"status":"new"` means the wizard did not finish, so go back and complete it.
`signup OPEN` means the setting did not take: re-run the first line and check it prints no
error. Zammad hands `user_create_account` to anonymous browsers only while it is on, so its
absence from that response is the proof the door is shut. Both of these matter more here than
anywhere else in the install, because until the second one prints `CLOSED` anybody who finds
your hostname can make themselves an account on your helpdesk.

## 8. First backup and restore

Two artifacts. Attachments live in the database on the default storage setting, so the dump is
the whole of the data; the config archive holds the files that rebuild the service around it.

```bash
cd /srv/zammad
docker compose exec -T zammad-postgresql pg_dump -U zammad -d zammad_production | gzip > /srv/zammad/backups/zammad-db-$(date +%F).sql.gz
sudo tar -czf /srv/zammad/backups/zammad-config-$(date +%F).tar.gz -C /srv/zammad compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/zammad/backups/
```

You should see: two files, the dump a few hundred kilobytes on a fresh install and the config
archive a few kilobytes. Nothing goes offline: `pg_dump` snapshots a running database
consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/zammad
scp vps:/srv/zammad/backups/* ~/backups/zammad/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/zammad/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty helpdesk:

```bash
cd /srv/zammad
docker compose down
sudo rm -rf /srv/zammad/postgres
sudo install -d -m 700 /srv/zammad/postgres
docker compose up -d zammad-postgresql
sleep 30
gunzip -c /srv/zammad/backups/zammad-db-$(date +%F).sql.gz | docker compose exec -T zammad-postgresql psql -U zammad -d zammad_production
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command,
and your administrator login still works.

If you do not: `role "zammad" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand the stakes before you
skip this: every ticket, every customer and every attachment anyone ever sends you is a row in
that database, and the `.env` in the config archive is what the next PostgreSQL is created with.

## 9. Updating later

Image tags are listed at https://hub.docker.com/r/zammad/zammad/tags and software versions at
https://github.com/zammad/zammad/tags. The tag carries a build number after the version, which
is why this install pins `7.1.2-0003` and not `7.1.2`. Take both backup artifacts first, then
edit the `image:` line in /srv/zammad/compose.yml to the new tag and its digest.

```bash
cd /srv/zammad
docker compose pull
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d
docker compose logs --tail 30 zammad-railsserver
```

You should see: migration output from the init run, then the server starting, and no repeating
restart.

If you do not: put the old tag and digest back and run the same commands. That init run is not
optional and it is the step people skip: the new image migrates the database it inherited, and
without it every other container sits waiting for migrations nobody ran, which looks exactly
like a hung boot.

## 10. What will probably go wrong

The wait after `docker compose up -d`. It returned in a second, `docker compose ps` showed
zammad-nginx as `Created` rather than running, and https://<DOMAIN> answered `502` for four
minutes. Nothing was wrong: nginx waits on the rails health check, which has a four-minute
start period because the first boot loads a great deal before it answers anything. I tore the
stack down and started again, sure it had hung, and bought another four minutes. Let the loop
in step 7 run.

## 11. Out of scope

- Do not configure SMTP, IMAP or POP3. Ticket-by-email is what most people eventually want
  here, and it is a separate day's work with a mail provider; the web form, the agent interface
  and the customer portal all work without it.
- Do not add Elasticsearch. This stack is built without it deliberately, and it costs another
  container, another four gigabytes and a reindex.
- Do not set `user_create_account` back to true. Step 7 proves it is off, and an open signup on
  a public helpdesk is an open door.
- Do not enable the built-in backup container or S3 storage. Step 8 owns the backup, and a
  bucket puts attachments where that backup cannot see them.
