This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing OpnForm 2.3.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step says
otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Read this before step 1. `<DOMAIN>` becomes `APP_URL`, `FRONT_URL` and `NUXT_PUBLIC_APP_URL` at
once, and every form you publish is that hostname plus `/forms/` and a slug. Change it later and
every link you have sent out stops working, so pick the one you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: this install is seven containers, three of them PHP processes each carrying a 1 GB
memory limit, plus a Node server rendering pages and a PostgreSQL. Under 4096 MB is the case where
the install looks like it worked and then the OOM killer takes something out during your first busy
hour, so move to a larger box rather than trying it. An empty last line means the A record does not
exist yet: add it, wait a minute, run `dig +short <DOMAIN>` again, because Caddy cannot get a
certificate for a hostname that does not resolve and failed attempts count against a rate limit you
cannot see.

## 2. Layout

Paste the whole block at once, including the last two lines. The ingress configuration has to exist
before any container starts: Docker creates a directory where a missing bind-mount file should be,
and nginx then refuses to start on a config that is a folder.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/opnform /srv/opnform/backups /srv/opnform/nginx
cat > /srv/opnform/nginx/default.conf <<'EOF'
# OpnForm · the ingress, authored by caniselfhostit from
# https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker/nginx.conf
# The map strips /api before PHP sees it, since Laravel's routes are at the
# root; `root` is a path inside the api container and only builds
# SCRIPT_FILENAME, so nothing static is served from this one.

map $request_uri $api_uri {
    ~^/api(/.*$) $1;
    default $request_uri;
}

server {
    listen 80;
    root /usr/share/nginx/html/public;
    client_max_body_size 50m;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://client:3000;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
    }

    location ~/(api|open|local\/temp|forms\/assets)/ {
        try_files $uri /index.php$is_args$args;
    }

    location ~ \.php$ {
        fastcgi_pass api:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_param REQUEST_URI $api_uri;
        fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
    }
}
EOF
ls -la /srv/opnform/nginx
```

You should see: `default.conf` listed as a file, owned by you, a little over a kilobyte.

If you do not: a `default.conf` listed with a `d` at the start of its permissions is a directory,
which means a container started before this step. Run `docker compose down` in /srv/opnform,
`sudo rm -rf /srv/opnform/nginx/default.conf`, and paste this block again. There is deliberately no
database or uploads directory here, because PostgreSQL, Redis and the API storage tree each chown
their own data to a uid of their choosing, so all three live in named volumes that step 8 dumps
rather than copies.

## 3. Secrets

Five secrets, all generated here on the server: the Laravel application key, the JWT signing key,
the shared secret between the Nuxt server and the API, the PostgreSQL password and the Redis
password. `APP_KEY` has a shape, `base64:` followed by 32 random bytes in base64, which is what
`php artisan key:generate --show` produces; the other four are hex, because two of them travel
inside connection strings.

```bash
umask 077
cat > /srv/opnform/.env <<EOF
APP_URL=https://<DOMAIN>
FRONT_URL=https://<DOMAIN>
APP_KEY=base64:$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -hex 32)
FRONT_API_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/opnform/.env
umask 022
ls -l /srv/opnform/.env
```

Replace `<DOMAIN>` on the first two lines with your real hostname before you paste.

You should see: mode `-rw-------`, your own username twice, and the path.

Do not paste that file, any of those five values, or any command output containing them into this
chat window. The agent path never sees them; this one hands them to a third party unless you keep
them out.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when you
paste the lines separately into different shells. Run `chmod 600 /srv/opnform/.env` and carry on. If
the file already existed from an earlier attempt, this block has now overwritten all five, which is
fine before the containers exist and a problem afterwards: PostgreSQL keeps the password it was
created with, so a changed `DB_PASSWORD` against an existing volume shows up in step 7 as
`"database":false` rather than as anything about passwords.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/opnform/compose.yml <<'EOF'
# OpnForm · the deterministic fallback. Authored by caniselfhostit from
# https://docs.opnform.com/deployment/docker,
# https://docs.opnform.com/configuration/environment-variables and
# https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker-compose.yml
#
# Seven services, upstream's own shape. The api image is php-fpm on 9000, so
# the nginx ingress speaks FastCGI to it and proxies the rest to the Nuxt
# client under one origin; the host's Caddy fronts that on 8186. api, worker
# and scheduler are one image under three commands, and the queue is not
# optional: an ordinary submission is dispatched to it, not written during the
# request. Digests read from Docker Hub on 2026-08-14; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

x-api: &api
  image: jhumanj/opnform-api:2.3.0@sha256:4b71e200d420c7cd2f3bbc7d8d9431de922c5edb8e49a7679c2d09c858fa7329
  restart: unless-stopped
  env_file: /srv/opnform/.env
  environment:
    APP_ENV: production
    APP_DEBUG: "false"
    SELF_HOSTED: "true"
    LOG_CHANNEL: errorlog
    LOG_LEVEL: warning
    DB_CONNECTION: pgsql
    DB_HOST: db
    DB_DATABASE: opnform
    DB_USERNAME: opnform
    REDIS_HOST: redis
    CACHE_DRIVER: redis
    QUEUE_CONNECTION: redis
    SESSION_DRIVER: redis
    LOCAL_FILESYSTEM_VISIBILITY: public
    # Mail to the container log, not nowhere. Upstream's setup script refuses
    # a production deploy with JWT validation skipped. The bridge range lets
    # Laravel read the forwarded visitor address; never "*".
    MAIL_MAILER: log
    JWT_SKIP_IP_UA_VALIDATION: "false"
    TRUSTED_PROXIES: 172.16.0.0/12
    OPNFORM_ANONYMOUS_TELEMETRY_DISABLED: "true"
  volumes:
    - opnform-storage:/usr/share/nginx/html/storage

services:
  db:
    image: postgres:16.15-alpine@sha256:ab5c955e9e57ae9879d4411ab49a912be9d162455676f7bf56e951b11ac73785
    restart: unless-stopped
    environment:
      POSTGRES_DB: opnform
      POSTGRES_USER: opnform
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - opnform-postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U opnform -d opnform"]
      interval: 10s
      retries: 30

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"$$REDIS_PASSWORD\""]
    volumes:
      - opnform-redis:/data
    healthcheck:
      test: ["CMD-SHELL", 'redis-cli -a "$$REDIS_PASSWORD" --no-auth-warning ping | grep -q PONG']
      interval: 10s
      retries: 30

  api:
    <<: *api
    depends_on:
      db: {condition: service_healthy}
      redis: {condition: service_healthy}
    healthcheck:
      test: ["CMD-SHELL", "php /usr/share/nginx/html/artisan about || exit 1"]
      interval: 30s
      timeout: 15s
      retries: 5
      # Long: it migrates before it answers, and the other four wait here.
      start_period: 300s

  worker:
    <<: *api
    command: ["php", "artisan", "queue:work"]
    depends_on:
      api: {condition: service_healthy}

  scheduler:
    <<: *api
    command: ["php", "artisan", "schedule:work"]
    depends_on:
      api: {condition: service_healthy}

  client:
    image: jhumanj/opnform-client:2.3.0@sha256:1b46bef02db59525e21c9e403805c50839af8c257883430702f1157c6946c1c8
    restart: unless-stopped
    environment:
      NUXT_PUBLIC_APP_URL: ${APP_URL}
      NUXT_PUBLIC_API_BASE: ${APP_URL}/api
      # Rendering on the server goes back through the ingress: Node cannot
      # speak FastCGI. NUXT_API_SECRET is FRONT_API_SECRET renamed.
      NUXT_PRIVATE_API_BASE: http://ingress/api
      NUXT_API_SECRET: ${FRONT_API_SECRET}
      NUXT_PUBLIC_ENV: production
    depends_on:
      api: {condition: service_healthy}

  ingress:
    image: nginx:1.30.4-alpine@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46
    restart: unless-stopped
    volumes:
      - /srv/opnform/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      api: {condition: service_healthy}
      client: {condition: service_started}
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8186.
      - "127.0.0.1:8186:80"
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/api/healthcheck || exit 1"]
      interval: 30s
      retries: 5
      start_period: 30s

volumes:
  opnform-postgres:
  opnform-redis:
  opnform-storage:
EOF
cd /srv/opnform && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/opnform/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal, so
run `rm /srv/opnform/compose.yml` and paste again in one go. A warning that `DB_PASSWORD` is not set
means Compose is not reading the `.env` next to the compose file, which happens when you run the
command from a directory other than /srv/opnform. The `x-api` block at the top is not an eighth
service: Compose ignores keys beginning `x-`, and the three PHP containers merge it in, which is why
`api`, `worker` and `scheduler` differ only in the command they run.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error here
takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-opnform
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# OpnForm · the Caddy site block for this service. Authored by caniselfhostit
# from https://docs.opnform.com/deployment/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is APP_URL, FRONT_URL and
# NUXT_PUBLIC_APP_URL at once, and every form link is it plus /forms/ and a
# slug, so it is the one value here you cannot change your mind about later.

<DOMAIN> {
	# No X-Frame-Options on purpose: OpnForm ships an embed script, so a form
	# is meant to run inside somebody else's page.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# Matches the ingress and the api image's own 50M PHP upload ceiling.
	request_body {
		max_size 50MB
	}

	# 8186 is the loopback port compose publishes for the nginx ingress: not a
	# container port, and not open in the firewall. TRUSTED_PROXIES is what
	# lets Laravel believe the X-Forwarded-For and -Proto that Caddy sends.
	reverse_proxy 127.0.0.1:8186
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-opnform /etc/caddy/Caddyfile`, reload, and
paste again. The hostname in this block and the hostname in `APP_URL` have to be the same string.
OpnForm builds every form link and every redirect from that value, and a mismatch gives you a
sign-in page that works and a session that never sticks.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8186`.

If you do not: delete anything for 8186 with `sudo ufw delete allow 8186`. That port is bound to
127.0.0.1 by the compose file, and PostgreSQL, Redis, php-fpm and the Nuxt client publish no host
port at all, so no firewall rule could apply to them. 80/tcp is there to answer the ACME challenge
and redirect to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

First boot is slow on purpose. The api container waits for PostgreSQL, runs every migration and
then caches its configuration, and the worker, the scheduler, the client and the ingress all wait
for it to report healthy before they start. Five minutes is normal on a cold pull.

```bash
cd /srv/opnform
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/healthcheck
curl -sS https://<DOMAIN>/api/content/feature-flags | grep -o '"setup_required":true'
curl -sSL https://<DOMAIN>/ | grep -c 'Create your admin account'
docker compose ps
```

You should see, in order: the loop counting up and ending on `200`; the JSON body
`{"status":"ok","dependencies":{"database":true,"redis":true}}`; the line
`"setup_required":true`; a number of at least `1`; and seven services listed with no restart loop.

If you do not: the health body is the one worth reading, because it names the two dependencies
separately. `"database":false` with `"redis":true` is an authentication problem rather than a
container that never started, and it points back at step 3. If the loop never reaches `200` at all,
run `docker compose logs --tail 60 api` and `docker compose logs --tail 20 ingress` in that order:
`host not found in upstream` from the ingress means it started before the client container existed,
and `docker compose up -d ingress` again fixes it, while a `502` from Caddy with healthy containers
means the reverse-proxy line is pointing somewhere other than 8186. A running container is not
success.

The first screen at https://<DOMAIN> is the setup page: the heading `OpnForm`, then a name, email
and password form under the line `Create your admin account`. Read this before you open it. Anybody
who reaches your hostname right now can fill that form in and own this instance, and there is no
second chance, because OpnForm refuses public registration permanently once the first account
exists. Do it now rather than tomorrow.

Open https://<DOMAIN> in a browser and create your admin account. No confirmation mail arrives,
because this install has no mail server and the account works without one, so save the password in
a manager before you submit the form. You land on your workspace.

Then prove the door is shut:

```bash
curl -sS https://<DOMAIN>/api/content/feature-flags | grep -o '"setup_required":false'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
```

You should see: `"setup_required":false`, then `404`, then `302`.

If you do not: an empty first line with a `200` from `/setup` means the account was not created, so
go back and create it. Nothing in this install configured any of that. Upstream's own register
controller refuses anyone without a workspace invitation once a single user exists, the setup page
throws a not-found, and `/register` redirects a stranger to the landing page, which is why all three
flip together. From here everyone else joins by invitation from inside your workspace, and upstream
caps a licence-free self-hosted instance at two users in total, counting pending invitations.

## 8. First backup and restore

Three artifacts. The database holds every form, every submission and your account. The storage
archive holds the files respondents attached, which a database dump does not contain. The config
archive holds what rebuilds the service around both, `.env` included.

```bash
cd /srv/opnform
docker compose exec -T db pg_dump -U opnform -d opnform | gzip > /srv/opnform/backups/opnform-db-$(date +%F).sql.gz
docker compose exec -T api tar -czf - -C /usr/share/nginx/html storage > /srv/opnform/backups/opnform-storage-$(date +%F).tar.gz
sudo tar -czf /srv/opnform/backups/opnform-config-$(date +%F).tar.gz -C /srv/opnform compose.yml .env nginx -C /etc/caddy Caddyfile
ls -lh /srv/opnform/backups/
```

You should see: three files, all of them a few kilobytes on a fresh install. Nothing goes offline,
because `pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and the
shell created the file anyway. Re-run that line without the redirect to read the error. Redis is
deliberately absent from all three archives: it holds cache and the job queue rather than data, so a
submission still sitting in the queue when you ran this is not in the backup.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/opnform
scp vps:/srv/opnform/backups/* ~/backups/opnform/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/opnform/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one empty workspace. Order matters,
because the api container runs migrations the moment it can reach a database:

```bash
cd /srv/opnform
docker compose down -v
docker compose up -d db redis
sleep 30
gunzip -c /srv/opnform/backups/opnform-db-$(date +%F).sql.gz | docker compose exec -T db psql -U opnform -d opnform
docker compose up -d
sleep 120
gunzip -c /srv/opnform/backups/opnform-storage-$(date +%F).tar.gz | docker compose exec -T api tar -xzf - -C /usr/share/nginx/html
curl -sS https://<DOMAIN>/api/healthcheck
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then a health body with both
dependencies `true`, and your account still works when you sign in.

If you do not: `docker compose down -v` drops all three volumes on purpose, which is the whole point
of the drill, and it is also why `-v` belongs on no other command in this file. `psql` refusing to
connect means the database container had not finished initialising, so wait longer and run the
`gunzip` line again. If you had already untarred the config archive over /srv/opnform, that is
correct: `.env` has to be back before anything starts, because PostgreSQL takes its password from it
the moment it initialises an empty volume. Understand the stakes before you skip this: every answer
anyone ever sends you is a row in that dump.

## 9. Updating later

New versions are listed at https://github.com/OpnForm/OpnForm/releases. The release tag is `v2.3.0`
and the image tag is `2.3.0`, the same digits without the `v`. Take all three backup artifacts
first, then edit the `jhumanj/opnform-api` line in the `x-api` block and the `jhumanj/opnform-client`
line in /srv/opnform/compose.yml to the new tag and its digest.

```bash
cd /srv/opnform
docker compose pull
docker compose up -d
docker compose logs --tail 40 api
docker compose restart ingress
```

You should see: the api logging its migrations and settling, then no output from the restart.

If you do not: put the old tag and digest back and run the same four commands. The last line is not
optional, and step 10 explains why. Move the api and the client together: a client built against a
different API is the failure that looks like a broken login. Leave the postgres and redis lines
alone, because a database major version is a separate migration with its own dump and restore.

## 10. What will probably go wrong

The ingress will lie to you. I changed one line in .env, recreated the client the way upstream's
documentation says to, and every page went to `502` while `docker compose ps` showed seven healthy
containers and the api answered its own health check perfectly from inside the network. nginx had
resolved `client:3000` to an address once at start-up and kept it, and the recreated container had
come back on a different one. Nothing says so except the ingress log, which reads `connect()
failed`. Any time you recreate `api` or `client`, run `docker compose restart ingress` straight
after, and read `docker compose logs --tail 20 ingress` before concluding anything else is broken.

## 11. Out of scope

- Do not configure SMTP. Your account is created, the sign-in holds and submissions land with no
  mail server, and MAIL_MAILER is `log` so nothing is silently swallowed. Mail buys password reset,
  email verification and response notifications, and outbound mail from a fresh VPS is a fight for
  another day. That one account is your whole way back in.
- Do not set `NUXT_PUBLIC_ROOT_REDIRECT_URL`. The root of your hostname shows OpnForm's own landing
  page to anyone not signed in, which is upstream's default rather than a fault, and where the bare
  domain sends a stranger is your editorial call.
- Do not set `OPEN_AI_API_KEY`, the hCaptcha or reCAPTCHA keys, `GOOGLE_CLIENT_ID` or the `AWS_`
  variables. Each is an account somewhere else and a second failure mode, and the builder, the
  logic, the file uploads and the submissions inbox all work without them.
- Do not activate a self-hosted Enterprise licence and do not set `CUSTOM_CODE_ENABLE_SELF_HOSTED`.
  The first is a purchase you make, the second turns user-supplied code loose in a page that
  strangers load.
