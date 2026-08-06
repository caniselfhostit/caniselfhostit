This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing GlitchTip 6.2.3 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `GLITCHTIP_DOMAIN`, and every DSN this server hands
out is built from it. Change it later and you edit the configuration of every application that
reports here. Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. On the disk number, take
20 GB as a floor rather than a target: the events are the product, and upstream puts a million
events a month at roughly 30 GB with the default 90-day retention. On RAM, upstream recommends
512 MB for GlitchTip alone, and this install runs PostgreSQL 18 and Valkey beside it.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/glitchtip /srv/glitchtip/backups
sudo install -d -m 700 /srv/glitchtip/postgres
sudo install -d -m 750 -o 5000 -g 5000 /srv/glitchtip/uploads
ls -la /srv/glitchtip
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`uploads` owned by uid `5000`.

If you do not: leave those two alone on purpose. The PostgreSQL image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. The GlitchTip image runs as uid 5000, which is the account inside the container
that writes source maps into `uploads`; owned by you, those uploads fail with a permission
error.

## 3. Secrets

Two secrets: the Django `SECRET_KEY` and the PostgreSQL password. Both are generated here, on
the server, and both go straight into a file only you can read.

```bash
umask 077
cat > /srv/glitchtip/.env <<EOF
GLITCHTIP_DOMAIN=https://<DOMAIN>
ALLOWED_HOSTS=<DOMAIN>,localhost
CSRF_TRUSTED_ORIGINS=https://<DOMAIN>
SECRET_KEY=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/glitchtip/.env
umask 022
ls -l /srv/glitchtip/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the three lines that carry it with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/glitchtip/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
both secrets, which is fine before the database exists and a problem afterwards: PostgreSQL
keeps the credential it was created with, so a changed `DB_PASSWORD` on an existing volume
produces an authentication failure in the GlitchTip log rather than anything about credentials.

Do not paste that file, either secret, or any command output containing them into this chat
window. The three plain lines matter too: `ALLOWED_HOSTS` is the only set of names Django will
answer on, and it carries `localhost` because the container health check calls
`http://localhost:8000/_health/` from inside itself. `CSRF_TRUSTED_ORIGINS` is what upstream
documents as required behind a reverse proxy, and without it the login form is rejected.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/glitchtip/compose.yml <<'EOF'
# GlitchTip · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install guide ....... https://glitchtip.com/documentation/install
#   sample compose ...... https://glitchtip.com/assets/compose.sample.yml
#   backend at v6.2.3 ... https://gitlab.com/glitchtip/glitchtip-backend/-/tree/v6.2.3
#
# Three services. SERVER_ROLE all_in_one is upstream's own sample shape: one
# container applies the migrations, maintains the Postgres partitions, then
# serves with the background worker inside it. No separate worker, no migrate
# job. PostgreSQL 18 keeps its data under /var/lib/postgresql, where the
# official image declares its volume. Valkey gets no volume, matching
# upstream's sample: cache and task queue, worth having available rather than
# worth keeping. Digests read 2026-08-06; all three are multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: glitchtip

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    restart: unless-stopped
    environment:
      POSTGRES_DB: glitchtip
      POSTGRES_USER: glitchtip
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/glitchtip/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U glitchtip -d glitchtip"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the web container.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 12
    # No volume and no ports: cache and queue, reachable in-network only.

  web:
    image: glitchtip/glitchtip:6.2.3@sha256:95e0e2d6b1bc18446902ae0cb47910cc55d7c0d6756ee901b0cd8dce9f8ef5a9
    restart: unless-stopped
    env_file: /srv/glitchtip/.env
    environment:
      SERVER_ROLE: all_in_one
      DATABASE_URL: postgres://glitchtip:${DB_PASSWORD}@postgres:5432/glitchtip
      VALKEY_URL: redis://valkey:6379
      # One account can be created while the user table is empty, then
      # self-signup closes. Step 7 asserts the door shut.
      ENABLE_USER_REGISTRATION: "False"
      # Django Admin and the OpenAPI schema default to on in the code and to
      # off in upstream's sample. Off here too: neither is needed to use this.
      ENABLE_ADMIN: "False"
      ENABLE_OPENAPI: "False"
    volumes:
      - /srv/glitchtip/uploads:/code/uploads
    healthcheck:
      test: ["CMD", "python", "healthcheck.py"]
      interval: 15s
      retries: 20
      start_period: 90s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8123.
      - "127.0.0.1:8123:8000"
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy
EOF
cd /srv/glitchtip && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/glitchtip/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/glitchtip/compose.yml` and paste again in one go. `SERVER_ROLE: all_in_one` is
upstream's own sample shape for a single server: the web container runs the migrations and the
partition maintenance itself, then serves with the background worker embedded, so there is no
fourth container to sequence and nothing to run by hand after an upgrade.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-glitchtip
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# GlitchTip · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://glitchtip.com/documentation/install and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also GLITCHTIP_DOMAIN and ALLOWED_HOSTS in .env, and every DSN this server
# hands out is built from it, so changing it later means editing every
# application that reports here.

<DOMAIN> {
	# GlitchTip sends its own Content-Security-Policy, so nothing here
	# touches that header. HSTS, nosniff and a same-origin frame rule are
	# the additions.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# Upstream's nginx example raises client_max_body_size to 40M because
	# nginx caps a body at 1M. Caddy has no such cap, so nothing to raise.
	#
	# 8123 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8123
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-glitchtip /etc/caddy/Caddyfile`, reload,
and paste again. Caddy requests the certificate on the first request and renews it on its own,
so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8123`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8123`. 8123 is bound
to 127.0.0.1 by the compose file, and PostgreSQL and Valkey publish no host port at all, so
neither has a port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to
answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers
by default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled,
so something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

On a cold start the web container applies every migration and builds the event partitions before
it binds a port, so the first health check takes minutes rather than seconds.

```bash
cd /srv/glitchtip
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_health/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/_health/; echo
curl -sS https://<DOMAIN>/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/0/organizations/
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/admin/
```

You should see, in order: the loop reaching `200`, then `ok`, then
`"enableUserRegistration":true`, then `401`, then `404`.

If you do not: a `502` from Caddy while the loop is still running is the migrations, not a
broken proxy, so let all forty attempts run. A `400` where a `200` was expected is
`ALLOWED_HOSTS` in step 3 not matching your hostname. If the loop never reaches `200`, run
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy is
step 2 done wrong, and `docker compose logs --tail 40 web` second. The `401` is the one worth
understanding: it means the API is up and refusing a call with no credential, so seeing it is
good news. The `404` from `/admin/` means Django Admin is not routed at all, which is what
`ENABLE_ADMIN: "False"` in the compose file buys you.

The first screen at https://<DOMAIN> is a login card headed `Login`, with a `New to GlitchTip?`
line and a `Sign Up` link under the form.

Open https://<DOMAIN>, follow `Sign Up`, create your account with an email address and a
password you have saved in a password manager first, then the organization GlitchTip asks for
next, then a first project inside it. This is the only moment that account can be made:
`ENABLE_USER_REGISTRATION` is False, which upstream defines as self-signup closing once the
first user exists. This install also sends no mail, so a lost password has no reset link. The
project's settings show its DSN; point your application's sentry-sdk at that string and the
first real event arrives from your own code, which is the whole reason this server exists.

Then prove the door shut:

```bash
curl -sS https://<DOMAIN>/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
```

You should see: `"enableUserRegistration":false`. Reload https://<DOMAIN> and confirm the
`Sign Up` link is gone.

If you do not: a `true` here means the account was not actually created, so go back and finish
the sign-up form. A running container is not success; these two checks are.

## 8. First backup and restore

Two artifacts. The database holds every account, project, issue and event. The config archive
holds the files that rebuild the service around them.

```bash
cd /srv/glitchtip
docker compose exec -T postgres pg_dump -U glitchtip -d glitchtip | gzip > /srv/glitchtip/backups/glitchtip-db-$(date +%F).sql.gz
sudo tar -czf /srv/glitchtip/backups/glitchtip-config-$(date +%F).tar.gz -C /srv/glitchtip compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/glitchtip/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently. Valkey is not in the backup: it holds the
cache and the task queue, and upstream says that data is worth having available rather than
worth keeping.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/glitchtip
scp vps:/srv/glitchtip/backups/* ~/backups/glitchtip/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/glitchtip/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty issue list:

```bash
cd /srv/glitchtip
docker compose down
sudo rm -rf /srv/glitchtip/postgres
sudo install -d -m 700 /srv/glitchtip/postgres
sudo tar -xzf /srv/glitchtip/backups/glitchtip-config-$(date +%F).tar.gz -C /srv/glitchtip compose.yml .env uploads
docker compose up -d postgres
sleep 30
gunzip -c /srv/glitchtip/backups/glitchtip-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U glitchtip -d glitchtip
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `"enableUserRegistration":false`
from the last command, which means your account survived a database that was deleted and rebuilt.

If you do not: `role "glitchtip" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. The reason the config archive gets
untarred before PostgreSQL starts is that PostgreSQL reads `DB_PASSWORD` out of .env the moment
it initialises an empty directory, so a dump restored without its .env is a database the new
container cannot open. The two files travel together.

## 9. Updating later

GlitchTip develops on GitLab, and released versions are tagged at
https://gitlab.com/glitchtip/glitchtip-backend/-/tags. The Docker Hub tag drops the leading `v`,
so `v6.2.4` there is `6.2.4` in the image line. Take both backup artifacts first, then edit the
image line in /srv/glitchtip/compose.yml to the new tag and its digest.

```bash
cd /srv/glitchtip
docker compose pull
docker compose up -d
docker compose logs --tail 40 web
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, because a container that answers `ok`
on health can still be failing to ingest events if a migration stopped halfway.

## 10. What will probably go wrong

The wait on the first start. I saw the web container sit at `starting`, opened https://<DOMAIN>,
got a `502` from Caddy, and went to read the Caddyfile looking for what I had typed wrong.
Nothing was wrong. The container was still applying migrations and building event partitions
against an empty database, and it binds its port only after that finishes. It took about four
minutes. Let the loop in step 7 run all forty times before concluding anything is broken.

## 11. Out of scope

- Do not configure SMTP and do not set `EMAIL_URL` or `DEFAULT_FROM_EMAIL`. With no mail
  transport GlitchTip turns email off on purpose: account verification and password reset leave
  the interface, and alerts go to a webhook recipient instead. That is the trade here, not an
  oversight to fix.
- Do not set `GLITCHTIP_ENABLE_DUCKDB` or configure S3 cold storage. That is a second storage
  backend and a bucket on another host, and PostgreSQL holds everything at this size.
- Do not set `ENABLE_ADMIN` back to True and do not run `manage.py createsuperuser`. The account
  made in step 7 administers this instance from the normal interface.
- Do not split the worker into its own container. `SERVER_ROLE: all_in_one` runs it inside the
  web process, which is upstream's own shape for a single server.
