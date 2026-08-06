This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing listmonk 6.2.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Two things to settle before step 1. `<DOMAIN>` goes inside every campaign you send, in the
unsubscribe link and the archive URL, and a hostname you swap out later starts its sending
reputation from zero. And listmonk delivers no mail itself: it hands finished messages to
somebody else's SMTP server, so have a relay account ready with a host, a port, a username and
a password. Step 7 stops and waits for those four.

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
hostname, because listmonk builds tracking and unsubscribe URLs on it and a second hop in front
of them is a second thing that can break a link inside somebody's inbox.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/listmonk /srv/listmonk/backups
sudo install -d -m 700 /srv/listmonk/postgres
sudo install -d -m 755 /srv/listmonk/uploads
ls -la /srv/listmonk
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`uploads` at `drwxr-xr-x`.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `uploads` ends up owned by root too, because the listmonk entrypoint
chowns /listmonk to PUID:PGID and that defaults to 0:0. That is why step 8 uses `sudo tar`.

## 3. Secrets

Two secrets: the PostgreSQL password and the Super Admin password. Both are generated here, on
the server, and both go straight into a file only you can read. Hex for the database one,
because it travels inside a connection string; base64 for the admin one, because you will paste
it into a login form.

```bash
umask 077
cat > /srv/listmonk/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
LISTMONK_ADMIN_USER=admin
LISTMONK_ADMIN_PASSWORD=$(openssl rand -base64 30)
EOF
chmod 600 /srv/listmonk/.env
umask 022
ls -l /srv/listmonk/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Read the admin
password once with `sudo grep LISTMONK_ADMIN_PASSWORD /srv/listmonk/.env` and put it in your
password manager. Your username is `admin`.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/listmonk/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
both values, which is fine before the database exists and a problem afterwards: PostgreSQL
keeps the password it was created with, so a changed one against an existing volume shows up as
an authentication failure in the listmonk log rather than as anything about passwords.

Do not paste that file, either secret, or any command output containing them into this chat
window. The same goes for the SMTP relay password you enter in step 7: it lives in the
database, and a database dump you paste here is a credential you have handed to a third party.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/listmonk/compose.yml <<'EOF'
# listmonk · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://listmonk.app/docs/installation/
#   variable reference . https://listmonk.app/docs/configuration/
#   upgrade path ....... https://listmonk.app/docs/upgrade/
#   health route ....... https://github.com/knadh/listmonk/blob/v6.2.0/cmd/handlers.go
#
# Two services: listmonk and the PostgreSQL it keeps subscribers, campaigns and
# click records in. Upstream states Postgres 12 or newer is the only dependency.
# The three-phase command is upstream's own: --install --idempotent lays the
# schema down once on an empty database, --upgrade applies migrations when the
# image moves, the third invocation runs the server, and --config '' means "no
# TOML file, read the LISTMONK_ environment variables". The root URL and the
# SMTP relay are settings rows a human fills in from the admin UI. Digests read
# on 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: listmonk-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: listmonk
      POSTGRES_USER: listmonk
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/listmonk/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U listmonk -d listmonk"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  app:
    image: listmonk/listmonk:v6.2.0@sha256:f535d59e14991337a9f2d570273685378ae86b0d7698c3e00da444e3bc205286
    container_name: listmonk-app
    restart: unless-stopped
    env_file: /srv/listmonk/.env
    command: [sh, -c, "./listmonk --install --idempotent --yes --config '' && ./listmonk --upgrade --yes --config '' && ./listmonk --config ''"]
    environment:
      # Every interface inside the container; the way in is the port below.
      LISTMONK_app__address: 0.0.0.0:9000
      LISTMONK_db__host: db
      LISTMONK_db__port: 5432
      LISTMONK_db__user: listmonk
      LISTMONK_db__database: listmonk
      LISTMONK_db__password: ${POSTGRES_PASSWORD}
      LISTMONK_db__ssl_mode: disable
      LISTMONK_db__max_open: 25
      LISTMONK_db__max_idle: 25
      LISTMONK_db__max_lifetime: 300s
      TZ: Etc/UTC
    volumes:
      # Images uploaded through Admin -> Media. The entrypoint chowns /listmonk
      # to PUID:PGID, default 0:0, so this ends up root-owned on the host.
      - /srv/listmonk/uploads:/listmonk/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8096.
      - "127.0.0.1:8096:9000"
    depends_on:
      db:
        condition: service_healthy
EOF
cd /srv/listmonk && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/listmonk/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/listmonk/compose.yml` and paste again in one go. The long `command:` line is
upstream's three-phase form and all of it matters: pass one creates the schema and is
idempotent, so it does nothing on later boots; pass two applies database migrations, which is
what makes step 9 three commands; pass three runs the server.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-listmonk
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# listmonk · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://listmonk.app/docs/configuration/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That same hostname goes
# into listmonk's Root URL setting after the first login: unsubscribe links and
# archive URLs are built from that setting, not from the request. Upstream splits
# its routes into private admin paths (/admin/*, /api/*) and public ones
# (/subscription/*, /link/*, /campaign/*, /archive) that subscribers have to
# reach; both halves answer on this one hostname.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# SAMEORIGIN rather than DENY: the campaign editor previews a campaign
		# in an iframe served from this same origin.
		X-Frame-Options "SAMEORIGIN"
		# A subscription URL carries the subscriber's UUID in the path, so a
		# full Referer on an outbound click hands that UUID to a third party.
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8096 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8096
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-listmonk /etc/caddy/Caddyfile`, reload,
and paste again. One thing in that block is worth knowing before a subscriber complains: the
admin half of listmonk (/admin and /api) and the public half (/subscription, /link, /campaign,
/archive) answer on the same hostname by design, because the links inside your campaigns point
at the public half and they have to resolve for strangers.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8096` or `5432`.

If you do not: delete anything for `8096` or `5432` with `sudo ufw delete allow 8096`. 8096 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp answers the ACME challenge and redirects,
443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default. Nothing here
opens a mail port: the connection to your relay is outbound, and ufw allows outbound already.
`Status: inactive` is a different problem, and `sudo ufw enable` puts it back.

## 7. Start and verify

```bash
cd /srv/listmonk
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/admin/login | grep -o '<h2>Login</h2>'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/lists
```

You should see, in order: the loop reaching `200`, then `{"data":true}`, then
`<h2>Login</h2>`, then `403`.

If you do not: the `403` is the one worth understanding. It means the admin API is up and
refusing a call with no session, so seeing it is good news. If the grep prints nothing, open
https://<DOMAIN>/admin/login in a browser and look at the heading. `New user` there means the
database was not empty when the app first started, so the Super Admin from step 3 was never
created; `docker compose down`, `sudo rm -rf /srv/listmonk/postgres`, recreate that directory
as in step 2, and run this block again. If the loop never reaches `200`, run `docker compose
logs --tail 20 db` first, because a database that never reports healthy is step 2 done wrong,
and `docker compose logs --tail 40 app` second.

The first screen is https://<DOMAIN>/admin/login, and it shows the heading `Login` with a
username and a password field. Log in as `admin` with the password from step 3, then do these
three things, because nothing else can do them for you:

- Settings -> General: set Root URL to `https://<DOMAIN>`. It ships as `http://localhost:9000`,
  and every unsubscribe link, archive URL and tracking pixel in an outgoing campaign is built
  from it.
- Settings -> General: set the default from-address to one on a domain you control. It ships as
  an example address.
- Settings -> SMTP: the seeded first entry is switched on and points at `smtp.yoursite.com`
  with placeholder credentials. Replace its host, port, username and password with your
  relay's, and press Test connection before you save.

listmonk reloads itself when settings are saved. Then confirm the three values actually moved:

```bash
cd /srv/listmonk
docker compose exec -T db psql -U listmonk -d listmonk -tAc "SELECT key, value FROM settings WHERE key IN ('app.root_url', 'app.from_email')"
docker compose exec -T db psql -U listmonk -d listmonk -tAc "SELECT count(*) FROM settings, jsonb_array_elements(value) AS s WHERE key = 'smtp' AND (s->>'enabled')::boolean AND s->>'host' = 'smtp.yoursite.com'"
curl -sS https://<DOMAIN>/health
```

You should see: a root URL of `"https://<DOMAIN>"`, a from-address with no
`listmonk.yoursite.com` in it, then `0`, then `{"data":true}`.

If you do not: a count above `0` means an enabled SMTP entry still points at the placeholder
host, and every campaign you send will fail. Go back to Settings -> SMTP and save it properly.
A root URL still reading `http://localhost:9000` means the General page was not saved; it is
the single most expensive thing to get wrong here, because the mistake only shows up in
somebody else's inbox. A running container is not success.

## 8. First backup and restore

Two artifacts. The database holds subscribers, campaigns, settings and click history; the file
archive holds compose.yml, .env, the uploads and the host's Caddyfile, which is the file that
puts the site on your hostname.

```bash
cd /srv/listmonk
docker compose exec -T db pg_dump -U listmonk -d listmonk | gzip > /srv/listmonk/backups/listmonk-db-$(date +%F).sql.gz
sudo tar -czf /srv/listmonk/backups/listmonk-files-$(date +%F).tar.gz -C /srv/listmonk compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/listmonk/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline,
because `pg_dump` snapshots a running database consistently. Both files carry live credentials:
.env is in the archive, and your SMTP relay's password is inside the settings table in the
dump. Keep them where you would keep a password-manager export.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/listmonk
scp vps:/srv/listmonk/backups/* ~/backups/listmonk/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/listmonk/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty list:

```bash
cd /srv/listmonk
docker compose down
sudo rm -rf /srv/listmonk/postgres
sudo install -d -m 700 /srv/listmonk/postgres
docker compose up -d db
sleep 30
gunzip -c /srv/listmonk/backups/listmonk-db-$(date +%F).sql.gz | docker compose exec -T db psql -U listmonk -d listmonk
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/health
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `{"data":true}` from the last
command, and your settings still in place when you reload the admin page.

If you do not: `role "listmonk" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand the stakes before you
skip this step: the consent record for every subscriber, who opted in and when, is in that
database, and a list restored from nothing is a list you are no longer allowed to mail.

## 9. Updating later

New versions are listed at https://github.com/knadh/listmonk/releases. Upstream's instruction
is to back up the database before every upgrade, so run step 8 first, then edit the `image:`
line in /srv/listmonk/compose.yml to the new tag and its digest.

```bash
cd /srv/listmonk
docker compose pull
docker compose up -d
docker compose logs --tail 30 app
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and log in as well, because a service
answering on /health can still be failing on something the admin UI needs.

## 10. What will probably go wrong

Mail, and not listmonk. I had the app up, a list made and a test campaign written inside half
an hour, then watched the send sit at zero delivered behind a green container and a cheerful
dashboard. The relay was refusing the connection and the campaign screen never says so: the
error is in Settings -> Logs, several screens from where the problem looks like it is.
Upstream warns that some hosting providers block outbound SMTP ports 25 and 465, which is a
support ticket rather than a setting. Send one campaign to a list holding only your own
address before anyone else is imported, and read Settings -> Logs when nothing arrives.

## 11. Out of scope

- Do not import a subscriber list until a test campaign has arrived. A list imported into an
  instance that cannot send is a list that gets imported twice.
- Do not configure bounce processing or a bounce mailbox. That wants a second mailbox with its
  own POP credentials and is an install-sized job of its own.
- Do not enable OIDC single sign-on. It needs an identity provider registered somewhere else.
- Do not move media uploads to S3. The uploads directory from step 2 is the choice here and it
  is inside the backup.
