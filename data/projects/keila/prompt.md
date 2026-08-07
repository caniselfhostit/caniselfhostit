You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Keila 0.30.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` is the hostname whose A record already points here, and it becomes
`URL_HOST`: unsubscribe links, form URLs and opt-in confirmations are built from it, so changing
it later breaks links already in somebody's inbox. `<ADMIN_EMAIL>` is what the root account logs
in with.

Ask a third question in the same breath: do they have an SMTP relay account, with a host, port,
username, password and a from-address on a domain they control. Keila delivers nothing itself,
and unlike most apps it will not start without one: upstream reads the relay host, from-address
and password while the release boots, and halts when any is missing.

Keila plus PostgreSQL needs 1024 MB of RAM available and 5 GB free on /srv. The Keila image is
published for linux/amd64 only. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If the architecture is anything but `amd64`, print it and stop: there is
no arm64 image to fall back to. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/keila /srv/keila/backups
sudo install -d -m 700 /srv/keila/postgres
sudo install -d -m 755 /srv/keila/uploads
ls -la /srv/keila
```

Assert: `ls -la` shows `backups` owned by the login user, `postgres` at mode `700` owned by
root, and `uploads` at `755`. Leave the last two alone: PostgreSQL chowns its data directory to
the uid it runs as, and the Keila image declares no `USER`, so the release runs as root and
writes campaign images there.

## 3. Secrets

Three secrets, generated here: the PostgreSQL password, the Phoenix secret key base and the
root account's password. Do not print any of them, do not repeat them in your summary, and do
not put them in any log line.

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

Assert: the file exists with mode `-rw-------`. Hex for the database password and for the key
base, which upstream wants at least 64 characters long and this is 96; base64 for the root
password, which a human types into a form. The seed that creates the root account reads
`KEILA_USER` and `KEILA_PASSWORD` on the first start against an empty database. Left unset,
upstream invents a random password and writes it into the container log in clear text, where it
sits in `docker compose logs` forever. The relay lines are
empty on purpose: those values are the user's, not this prompt's.

STOP: tell the user to fill the relay settings in themselves and wait. Do not continue until
they confirm. Tell them to run `sudo nano /srv/keila/.env` and fill in the four blank lines at
the bottom: the relay hostname on `MAILER_SMTP_HOST`, the account name on `MAILER_SMTP_USER`, a
sending address on a domain they control on `MAILER_SMTP_FROM_EMAIL`, and the relay password on
`MAILER_SMTP_PASSWORD`. Port 587 with STARTTLS is already set and is what most relays want; one
documenting 465 wants that port, `MAILER_ENABLE_STARTTLS=false` and `MAILER_ENABLE_SSL=true`.
Tell them not to paste any of it back to you.

## 4. compose.yml

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

Assert: that prints `compose OK`. Compose reads /srv/keila/.env twice: `env_file` hands it to
the container, and `${POSTGRES_PASSWORD}` above is substituted from it because .env sits here.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. The copy on line one matters: a syntax error takes down every other site.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-keila, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it itself; nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero already configured.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the only way in, 443/udp is HTTP/3.
8145 stays closed because compose binds it to 127.0.0.1, and 5432 because compose publishes no
host port at all. Nothing opens for mail: the relay connection is outbound, which default-deny
already permits. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8145 or 5432.

## 7. Start and verify

Check first that step 3's relay lines were filled in. Upstream halts the release when one is
absent; a blank one is worse, because the service starts and cannot send. This prints key names
and whether each has a value, never a value:

```bash
sudo awk -F= '/^MAILER_SMTP_(HOST|USER|PASSWORD|FROM_EMAIL)=/ {print $1 "=" (length($2) ? "set" : "EMPTY")}' /srv/keila/.env
```

Assert: four lines, all reading `set`. If any reads `EMPTY`, stop and send the user back to step
3. Then start:

```bash
cd /srv/keila
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/auth/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/auth/login | grep -o 'Sign in with your email address and password here.'
curl -sS https://<DOMAIN>/auth/register | grep -o 'Registration disabled.'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/contacts
```

Assert all four and print what you received for each. The loop ends printing `200`. The first
grep prints `Sign in with your email address and password here.`, the line under the heading on
the first screen. The second prints `Registration disabled.`, the security assert here: the
sign-up form is shut, so a public hostname is not handing accounts to strangers. The last prints `403`, what upstream's API authorization plug returns to a caller
with no bearer token. If any of the four misses, stop, run
`docker compose logs --tail 40 keila` and `docker compose logs --tail 20 db`, and name the
likely cause: a missing-mailer-variable line is step 3 unfinished, a database that never reports
healthy is step 2, a `502` while the container is up is step 5. A running container is not
success.

STOP: tell the user to read their root password with
`sudo grep KEILA_PASSWORD /srv/keila/.env`, put it in their password manager, log in at
https://<DOMAIN>/auth/login as `<ADMIN_EMAIL>`, and wait. Do not continue until they confirm
they are inside. The next screen asks for a project, and a sender has to be added inside it
before any campaign can go out: the relay in .env carries system mail only.

## 8. First backup and restore

Two artifacts. The database holds contacts, their consent, campaigns, forms and click history.
The archive holds the config, the uploaded images and the host's Caddy site block.

```bash
cd /srv/keila
docker compose exec -T db pg_dump -U keila -d keila | gzip > /srv/keila/backups/keila-db-$(date +%F).sql.gz
sudo tar -czf /srv/keila/backups/keila-files-$(date +%F).tar.gz -C /srv/keila compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/keila/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently. Tell the user what they will not guess: the
archive contains .env, with the relay password and the key base in it, so treat it like a
password-manager export.

A backup on the same disk is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/keila
scp vps:/srv/keila/backups/* ~/backups/keila/
```

To restore: `docker compose down`, `sudo rm -rf /srv/keila/postgres`, recreate it as in step 2,
untar the archive back into /srv/keila, `docker compose up -d db`, wait about 30 seconds for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db psql -U keila -d keila`, then `docker compose up -d` and re-run step
7's asserts. Say what is at stake: who opted in and when is a row in that database, and a list
restored from nothing is a list the user may no longer mail.

## 9. Updating later

New versions are at https://github.com/pentacent/keila/releases. Back up first, then edit the
image line in /srv/keila/compose.yml to the new tag and digest:

```bash
cd /srv/keila
docker compose pull
docker compose up -d
docker compose logs --tail 30 keila
```

Keila migrates on the way up: watch that log settle, then re-run step 7's asserts.

## 10. What will probably go wrong

Mail, and not the install. I had Keila answering on its hostname in twenty minutes and spent the
rest of the afternoon on the sending path, because there are two mail settings here that look
like one. The relay in .env carries system mail: password resets and opt-in
confirmations. The sender added inside a project is what campaigns go out as, and it lives in the
web interface, not in that file. An install with the first right and the second missing looks
healthy and sends nothing. Add a sender, mail one campaign to the user's own address, and open
what arrives before anybody else is imported.

## 11. Out of scope

- Do not import a contact list before a test campaign has arrived in a real inbox. A list
  imported into an instance that cannot send gets imported twice.
- Do not configure hCaptcha or Friendly Captcha keys. Those protect a sign-up form this install
  has switched off.
- Do not add AWS SES, Mailgun or Postmark as a second sending path, and do not serve uploads
  from a second hostname. Each is a second thing to keep working.
