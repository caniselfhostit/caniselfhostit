This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Keila 0.30.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, replace `<DOMAIN>` with the hostname whose A record already points at the box,
and replace `<ADMIN_EMAIL>` with the address your admin account will log in with.

Read this before step 1. Keila does not deliver mail; it hands finished campaigns to an SMTP
relay you sign up for. Unlike most apps it will not even start without one, because upstream
reads the relay host, the from-address and the relay password out of the environment while the
release boots and stops the process when any of the three is missing. Have a relay account, with
a host, a port, a username, a password and a from-address on a domain you control, open in
another tab before you begin. And pick `<DOMAIN>` as a hostname you intend to keep: it becomes
`URL_HOST`, which is what every unsubscribe link and opt-in confirmation link in every message
you send is built from.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64`, and your server's IP
on the last line.

If you do not: `arm64` is a full stop rather than a slow path. The Keila image is published for
linux/amd64 only, so on an arm64 VPS there is nothing to pull and no fallback tag; rebuild the
box on an amd64 plan. An empty last line means the A record does not exist yet, so add it, wait
a minute and run `dig +short <DOMAIN>` again: Caddy cannot get a certificate for a name that
does not resolve, and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/keila /srv/keila/backups
sudo install -d -m 700 /srv/keila/postgres
sudo install -d -m 755 /srv/keila/uploads
ls -la /srv/keila
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`uploads` at `drwxr-xr-x`.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `uploads` stays root-writable because the Keila image declares no `USER`,
so the release inside it runs as root and writes campaign images there.

## 3. Secrets

Three secrets, all generated here on the server: the PostgreSQL password, the Phoenix secret key
base, and your admin password. Replace `<DOMAIN>` and `<ADMIN_EMAIL>` on lines three and four
before you paste, and paste the whole block at once.

```bash
umask 077
cat > /srv/keila/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 48)
URL_HOST=<DOMAIN>
KEILA_USER=<ADMIN_EMAIL>
KEILA_PASSWORD=$(openssl rand -base64 30)
MAILER_SMTP_PORT=587
MAILER_ENABLE_STARTTLS=true
MAILER_SMTP_HOST=
MAILER_SMTP_USER=
MAILER_SMTP_FROM_EMAIL=
MAILER_SMTP_PASSWORD=
# the four blank lines above are the relay account, filled in by hand
EOF
chmod 600 /srv/keila/.env
umask 022
ls -l /srv/keila/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when
the lines are pasted separately into different shells. Run `chmod 600 /srv/keila/.env` and carry
on. If the file already existed from an earlier attempt, this block has now replaced all three
secrets, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed one on an existing volume produces an authentication
failure in the Keila log rather than anything that mentions passwords.

Do not paste that file, any of the three values, or any command output containing them into this
chat window. The relay password you are about to add is the one that would cost you most: it can
send mail as you.

Now fill in the relay. Run `sudo nano /srv/keila/.env` and complete the four blank lines at the
bottom: the relay hostname on `MAILER_SMTP_HOST`, the account name on `MAILER_SMTP_USER`, a
sending address on a domain you control on `MAILER_SMTP_FROM_EMAIL`, and the relay password on
`MAILER_SMTP_PASSWORD`. Port 587 with STARTTLS is set already and is what most relays want; a
relay that documents 465 wants that port, `MAILER_ENABLE_STARTTLS=false` and a line reading
`MAILER_ENABLE_SSL=true`. Save, then check the four are populated without printing them:

```bash
sudo awk -F= '/^MAILER_SMTP_(HOST|USER|PASSWORD|FROM_EMAIL)=/ {print $1 "=" (length($2) ? "set" : "EMPTY")}' /srv/keila/.env
```

You should see: four lines, every one of them ending in `set`.

If you do not: an `EMPTY` means that line is still blank. A blank relay setting does not stop
the container, it starts a Keila that cannot send anything, which is harder to see than a crash.
Open the file again. A key that does not appear at all means the line was deleted, and that one
does stop the release at boot; add it back exactly as spelled above.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/keila/compose.yml <<'EOF'
# Keila · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installation ....... https://www.keila.io/docs/installation
#   configuration ...... https://www.keila.io/docs/configuration
#   root user seed ..... https://github.com/pentacent/keila/blob/v0.30.2/priv/repo/seeds.exs
#
# Two services: Keila and the PostgreSQL it keeps contacts, campaigns and forms
# in. Upstream states PostgreSQL is the only dependency besides a container
# engine, and the release migrates and seeds itself on the way up. The SMTP relay
# is not optional: upstream reads the relay host, from-address and password at
# boot and halts when one is missing. Digests read on 2026-08-06. The Keila image
# publishes linux/amd64 only; PostgreSQL publishes both.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: keila-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: keila
      POSTGRES_USER: keila
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/keila/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keila -d keila"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  keila:
    image: pentacent/keila:0.30.2@sha256:b2fdb45228c94a0df0d7d1597009edaa663ff455999ddcf1dc1483d06631762b
    container_name: keila
    restart: unless-stopped
    env_file: /srv/keila/.env
    environment:
      # Assembled from .env, so the two cannot disagree.
      DB_URL: postgres://keila:${POSTGRES_PASSWORD}@db:5432/keila
      # The release listens on 4000; the host port below is the only way in.
      PORT: "4000"
      # Caddy terminates TLS, so Keila has to be told the links it writes into
      # campaigns and forms are https. Upstream then defaults URL_PORT to 443.
      URL_SCHEMA: https
      # /auth/register is an open sign-up form on a public hostname otherwise.
      DISABLE_REGISTRATION: "true"
      # HOME here is /opt/app, and uploads default to a path under it.
      USER_CONTENT_DIR: /opt/app/uploads
      # The digest above is the pin; a check from inside cannot act on it.
      DISABLE_UPDATE_CHECKS: "true"
    volumes:
      - /srv/keila/uploads:/opt/app/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8145.
      - "127.0.0.1:8145:4000"
    depends_on:
      db:
        condition: service_healthy
EOF
cd /srv/keila && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/keila/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/keila/compose.yml` and paste again in one go. Note what this file does with
/srv/keila/.env twice over: `env_file` hands the whole thing to the container, and the
`${POSTGRES_PASSWORD}` in the two lines above is substituted by Compose itself, because .env sits
in the project directory. One password, written once, used by the database and by the connection
string that reaches it.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-keila
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Keila · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.keila.io/docs/installation and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# URL_HOST in .env: Keila builds unsubscribe links, form URLs and opt-in
# confirmation links from that setting, not from the request, so the two have to
# agree. Upstream asks that a reverse proxy forward WebSockets, which Caddy's
# reverse_proxy does with no extra configuration.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# SAMEORIGIN, the value Keila's own browser pipeline already sets
		# through Phoenix's secure-headers plug. Stated here so it does not
		# depend on that plug staying in the pipeline.
		X-Frame-Options "SAMEORIGIN"
		# An unsubscribe or confirmation URL carries a recipient token in
		# the path, and a full Referer would hand it to the next site.
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8145 is the loopback port compose publishes here. It is not a container
	# port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8145
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-keila /etc/caddy/Caddyfile`, reload, and
paste again. Caddy terminates TLS and speaks plain http to the container, which is why
`URL_SCHEMA` is `https` in the compose file: without it Keila would write `http://` links into
messages for a service only reachable over https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8145` or `5432`.

If you do not: delete anything for `8145` or `5432` with `sudo ufw delete allow 8145`. 8145 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has no
host port a firewall rule could apply to. Nothing opens for mail either: the relay connection is
outbound, which the default-deny policy already allows. `Status: inactive` is a different
problem, because Prompt Zero left this firewall enabled, so `sudo ufw enable` before you go on.

## 7. Start and verify

```bash
cd /srv/keila
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/auth/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/auth/login | grep -o 'Sign in with your email address and password here.'
curl -sS https://<DOMAIN>/auth/register | grep -o 'Registration disabled.'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/contacts
```

You should see, in order: the loop reaching `200`, then the line
`Sign in with your email address and password here.`, then `Registration disabled.`, then `403`.

If you do not: the second and third lines are the ones worth understanding. The first is the
sentence under the heading on the first screen, so seeing it means Caddy, the container and the
database are all doing their jobs. The second means the sign-up form at `/auth/register` is shut,
which matters because this hostname is public and an open form there would let strangers create
accounts on your server. The `403` is the API refusing a call with no bearer token. If the loop
never reaches `200`, run `docker compose logs --tail 20 db` first, because a database that never
reports healthy stops everything behind it, then `docker compose logs --tail 40 keila`: a line
there about a missing mailer variable means one of step 3's four relay values is still blank, and
the container will keep exiting until it is filled in. A running container is not success.

The first screen is at https://<DOMAIN>/auth/login and shows the heading `Sign in.` above that
sentence.

Now log in. Read your admin password once with `sudo grep KEILA_PASSWORD /srv/keila/.env`, put it
in your password manager, and sign in at https://<DOMAIN>/auth/login with the address you used as
`<ADMIN_EMAIL>`. The next screen asks you to create a project. Inside that project, add a sender
before you write anything: the relay in .env carries system mail, and the sender is what
campaigns actually go out as. They are two settings and they look like one.

## 8. First backup and restore

Two artifacts. The database holds contacts, their consent, campaigns, forms and click history.
The archive holds the config that rebuilds the service around it, the uploaded images, and the
host's Caddy site block.

```bash
cd /srv/keila
docker compose exec -T db pg_dump -U keila -d keila | gzip > /srv/keila/backups/keila-db-$(date +%F).sql.gz
sudo tar -czf /srv/keila/backups/keila-files-$(date +%F).tar.gz -C /srv/keila compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/keila/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error. Treat
both files as credentials once they exist: the archive contains .env, with the relay password and
the key base in it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/keila
scp vps:/srv/keila/backups/* ~/backups/keila/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/keila/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty list:

```bash
cd /srv/keila
docker compose down
sudo rm -rf /srv/keila/postgres
sudo install -d -m 700 /srv/keila/postgres
docker compose up -d db
sleep 30
gunzip -c /srv/keila/backups/keila-db-$(date +%F).sql.gz | docker compose exec -T db psql -U keila -d keila
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/auth/login | grep -o 'Sign in with your email address and password here.'
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then that sentence again from the last
command, which means the login page survived a database that was deleted and rebuilt.

If you do not: `role "keila" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand the stakes before you
skip this step: who opted in and when is a row in that database, and a contact list restored from
a backup you never took is a list you are no longer allowed to mail.

## 9. Updating later

New versions are listed at https://github.com/pentacent/keila/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/keila/compose.yml to the new tag and its
digest.

```bash
cd /srv/keila
docker compose pull
docker compose up -d
docker compose logs --tail 30 keila
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
four checks from step 7 before you call the update done, and send yourself one campaign as well,
because a login page that renders can still sit in front of a queue that has stopped moving.

## 10. What will probably go wrong

Mail, and not the install. I had Keila answering on its hostname in twenty minutes and spent the
rest of the afternoon on the sending path, because there are two mail settings here that look
like one. The relay in .env carries system mail: password resets and the opt-in confirmation. The
sender you add inside a project is what campaigns go out as, and it lives in the web interface,
not in that file. An install with the first right and the second missing looks healthy and sends
nothing. Add a sender, mail one campaign to your own address, and open what arrives before you
import anybody else.

## 11. Out of scope

- Do not import a contact list before a test campaign has arrived in a real inbox. A list
  imported into an instance that cannot send gets imported twice.
- Do not configure hCaptcha or Friendly Captcha keys. Those protect a sign-up form this install
  has switched off.
- Do not add AWS SES, Mailgun or Postmark as a second sending path, and do not serve uploads
  from a second hostname with `USER_CONTENT_BASE_URL`. Each is a second thing to keep working.
