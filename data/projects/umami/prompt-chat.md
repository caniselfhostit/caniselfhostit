This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Umami 3.2.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read this before step 1. That hostname ends up inside the tracking snippet you paste into every
page you measure, so changing it later means editing every one of those pages. Pick the
hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for this
hostname, because the certificate would be issued to somebody else's edge and the visitor
counts would be measured through it.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/umami /srv/umami/backups
sudo install -d -m 700 /srv/umami/postgres
ls -la /srv/umami
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. There is no directory for Umami itself, because Umami writes nothing to
disk: every account, website and pageview is a row in that database.

## 3. Secrets

Three secrets, all generated here on the server. `DB_PASSWORD` is the PostgreSQL password,
`APP_SECRET` signs the login tokens, and `ADMIN_PASSWORD` is what step 7 puts on the built-in
admin account in place of the password the image ships with. Hex rather than base64: two of
them travel inside a URL and the third inside a JSON body, and hex needs no escaping in either.

```bash
umask 077
cat > /srv/umami/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
APP_SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/umami/.env
umask 022
ls -l /srv/umami/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/umami/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all
three values, which is fine before the database exists and a problem afterwards: PostgreSQL
keeps the password it was created with, so a changed `DB_PASSWORD` against an existing data
directory produces an authentication failure in the Umami log rather than anything that
mentions passwords.

Do not paste that file, any of the three values, or any command output containing them into
this chat window. Nothing below asks you to read a secret out loud, and the one place you need
`ADMIN_PASSWORD` in step 7 pipes it into curl from the file rather than printing it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/umami/compose.yml <<'EOF'
# Umami · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install ............ https://docs.umami.is/docs/install
#   variable reference . https://docs.umami.is/docs/environment-variables
#   hosting shapes ..... https://docs.umami.is/docs/guides/hosting
#   heartbeat route .... https://github.com/umami-software/umami/blob/v3.2.0/src/app/api/heartbeat/route.ts
#
# Two services: Umami and the PostgreSQL holding every account, website and
# pageview. Version 3 is a PostgreSQL-only build, so the tag carries no database
# flavour and DATABASE_URL is a postgresql:// string. Umami writes nothing to
# disk, which is why only the database has a volume. Tags and digests were read
# from the registries on 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: umami-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: umami
      POSTGRES_USER: umami
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/umami/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U umami -d umami"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  umami:
    image: ghcr.io/umami-software/umami:3.2.0@sha256:8edfe4beaef13f9d1300619fa264ef250a3688df9cc54d24ca830ca31cb475ec
    container_name: umami
    restart: unless-stopped
    # init reaps the child processes the migration step leaves behind.
    init: true
    environment:
      # Docker Compose substitutes both values from /srv/umami/.env, which is
      # mode 600 and is never mounted into the container.
      DATABASE_URL: postgresql://umami:${DB_PASSWORD}@postgres:5432/umami
      APP_SECRET: ${APP_SECRET}
      # No anonymous usage pings leave this box.
      DISABLE_TELEMETRY: "1"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/api/heartbeat || exit 1"]
      interval: 10s
      retries: 18
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8105.
      - "127.0.0.1:8105:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/umami && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal, so run `rm /srv/umami/compose.yml` and paste again in one go. A warning that
`DB_PASSWORD` is not set means step 3 did not write the file, or you are running the command
from a directory other than /srv/umami, which is where compose looks for `.env`. The tag reads
`3.2.0` with no database prefix on purpose: version 3 dropped the MySQL build, so the
`postgresql-` prefix every older guide shows no longer exists.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-umami
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Umami · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.umami.is/docs/guides/hosting and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also the address inside the tracking snippet on every page you measure, so
# changing it later means editing every site you track.

<DOMAIN> {
	# The dashboard is a JavaScript bundle worth compressing. The tracker
	# script and /api/send ride the same site block; Umami sets its own
	# Access-Control-Allow-Origin on both, so there is no CORS work here.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy here: Umami sends its own on every response,
	# and a second one would be intersected with it rather than replace it.

	# 8105 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8105
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-umami /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you forgot to replace, which Caddy reads
as a literal hostname and then tries to get a certificate for.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8105` or `5432`.

If you do not: delete anything for `8105` or `5432` with `sudo ufw delete allow 8105`. 8105 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

Umami applies its own schema migrations on the way up, which is also what creates the built-in
admin account.

```bash
cd /srv/umami
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/heartbeat); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/heartbeat
curl -sS https://<DOMAIN>/login | grep -o '<title>[^<]*</title>'
```

You should see, in order: the loop climbing and ending on `200`, then `{"ok":true}`, then
`<title>Login | Umami</title>`.

If you do not: give the loop all 30 attempts before you touch anything, because the first start
runs every schema migration and answers nothing until it finishes. If it runs out, check
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy
is step 2 done wrong, then `docker compose logs --tail 40 umami`. A `502` from Caddy where you
expected `200` means nothing is listening on 8105 yet. A title of `<title>Umami</title>` with
no `Login |` in front of it means you fetched `/` rather than `/login`. A missing title with a
healthy heartbeat is the soft case: the framework can stream the title later into the page
body, so run `curl -sS https://<DOMAIN>/login | head -c 400`, confirm you are looking at HTML,
and carry on, because the login box below is the real check.

Now close the account the image ships with. Upstream documents it as username `admin` with a
fixed published password, which means it is a known credential on a public hostname until this
block runs. Paste it in one go:

```bash
cd /srv/umami
login=$(curl -sS -X POST https://<DOMAIN>/api/auth/login -H 'Content-Type: application/json' --data '{"username":"admin","password":"umami"}')
token=$(printf '%s' "$login" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
userid=$(printf '%s' "$login" | sed -n 's/.*"user":{"id":"\([^"]*\)".*/\1/p')
[ -n "$token" ] && [ -n "$userid" ] && echo "logged in"
printf '{"password":"%s"}' "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' /srv/umami/.env)" | curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://<DOMAIN>/api/users/${userid}" -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' --data-binary @-
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/auth/login -H 'Content-Type: application/json' --data '{"username":"admin","password":"umami"}'
unset login token userid
```

You should see: `logged in`, then `200`, then `401`.

If you do not: nothing printed in place of `logged in` means the login failed, so the two lines
below it ran against empty values and did nothing. Re-run the first curl on its own and read
the response. A final line that is anything other than `401` means the shipped password still
works and this server is not safe to leave running: stop and fix that before anything else. The
password never appeared on a command line, so it is not in your shell history and it was not in
the process list either.

The first screen at https://<DOMAIN>/login shows the wordmark `umami` over a `Username` box, a
`Password` box and a `Login` button. Read your password once with
`grep ADMIN_PASSWORD /srv/umami/.env`, put it straight into your password manager, and sign in
as `admin`. Do not paste it here.

## 8. First backup and restore

Two artifacts. The database holds the accounts, the websites and every pageview. The config
archive holds the files that rebuild the service around it.

```bash
cd /srv/umami
docker compose exec -T postgres pg_dump -U umami -d umami | gzip > /srv/umami/backups/umami-db-$(date +%F).sql.gz
sudo tar -czf /srv/umami/backups/umami-config-$(date +%F).tar.gz -C /srv/umami compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/umami/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/umami
scp vps:/srv/umami/backups/* ~/backups/umami/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/umami/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty dashboard:

```bash
cd /srv/umami
docker compose down
sudo rm -rf /srv/umami/postgres
sudo install -d -m 700 /srv/umami/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/umami/backups/umami-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U umami -d umami
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/api/heartbeat
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `{"ok":true}` from the last
command, and your admin password still works when you sign in.

If you do not: `role "umami" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. If you ever restore onto a box
without `.env` in place first, PostgreSQL initialises with a blank password and refuses to
start, which is why the config archive holds `.env` and why you untar it before anything else.

## 9. Updating later

New versions are listed at https://github.com/umami-software/umami/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/umami/compose.yml to the new tag and its
digest.

```bash
cd /srv/umami
docker compose pull
docker compose up -d
docker compose logs --tail 30 umami
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. After a major
version jump upstream tells you to run `ANALYZE;` against the database, because the migration
leaves the query planner with stale statistics and the dashboard stays slow until it does not.
Run it with `docker compose exec -T postgres psql -U umami -d umami -c 'ANALYZE;'`.

## 10. What will probably go wrong

The first `docker compose up -d` looked hung to me. The container runs every schema migration
before it answers anything, and on a small VPS that took over a minute during which
https://<DOMAIN> returned a Caddy `502` and the log printed nothing I recognised. I had already
started re-reading the compose file for a mistake that was not there. The health loop in step 7
exists for this: give it the full 30 attempts before touching anything, and start reading logs
only once the loop has run out.

## 11. Out of scope

- Do not configure SMTP. Umami sends no mail here, and scheduled email reports are a
  hosted-service feature rather than something a mail server would switch on.
- Do not set `TRACKER_SCRIPT_NAME` or `COLLECT_API_ENDPOINT` to dodge ad blockers. Those
  rename the script and the collector, so the snippet on every tracked page has to be rewritten
  to match, and you have not tracked anything yet.
- Do not add Redis. Umami runs without it, and the extra container buys session caching this
  install has no traffic to need.
- Do not create additional users or teams yet. You sign in as `admin` and decide that.
