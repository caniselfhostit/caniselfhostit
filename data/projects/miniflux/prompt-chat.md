This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Miniflux 2.3.3 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `BASE_URL`, and Miniflux builds its session cookie
and every link it renders from `BASE_URL`. A hostname that does not match what is in your
address bar produces a login page that takes your password and hands you the login page back,
with no error message. Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that
does not resolve, and failed attempts count against a rate limit you cannot see. On RAM, the
reader itself is one Go binary that costs almost nothing; PostgreSQL is the heavier half of
that 1024 MB floor, and the entry history is what grows the 5 GB.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/miniflux /srv/miniflux/backups
sudo install -d -m 700 /srv/miniflux/postgres
ls -la /srv/miniflux
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. There is no `data` directory here for Miniflux itself, and that is not a
missing step: feeds, entries, read state and your account are all rows in PostgreSQL.

## 3. Secrets

Two secrets: the PostgreSQL password and the password for your own Miniflux account. Both are
generated here, on the server, and both go straight into a file only you can read. Replace
`<DOMAIN>` on the first line with your real hostname before you paste.

```bash
umask 077
cat > /srv/miniflux/.env <<EOF
BASE_URL=https://<DOMAIN>
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$(openssl rand -base64 24)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/miniflux/.env
umask 022
ls -l /srv/miniflux/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Your Miniflux
username is `admin`. Read the password once with
`sudo grep ADMIN_PASSWORD /srv/miniflux/.env` and put it in your password manager.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/miniflux/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
both secrets, which is fine before the database exists and a problem afterwards: PostgreSQL
keeps the password it was created with, so a changed `DB_PASSWORD` on an existing volume
produces an authentication failure in the Miniflux log rather than anything about passwords.
The database password is hex rather than base64 because upstream warns that special characters
can be rejected inside a URL-style connection string unless they are URL encoded.

Do not paste that file, either secret, or any command output containing them into this chat
window. The agent path never sees those values; this window will hand them to a third party
unless you keep them out of it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/miniflux/compose.yml <<'EOF'
# Miniflux · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://miniflux.app/docs/docker.html
#   configuration ...... https://miniflux.app/docs/configuration.html
#   database ........... https://miniflux.app/docs/database.html
#   requirements ....... https://miniflux.app/docs/requirements.html
#
# Two services: Miniflux and the PostgreSQL that holds every feed, every entry
# and the one account. Miniflux keeps nothing of its own on disk, so there is no
# application data volume in this file and the database is the whole backup
# surface. Upstream supports PostgreSQL 11 and above. The regular image is used
# rather than the -distroless one: both publish amd64 and arm64, but the regular
# image is built on Alpine and has a shell, so `docker compose exec` can look
# inside it when something is wrong. Tags and digests were read from the
# registries on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: miniflux-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: miniflux
      POSTGRES_USER: miniflux
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/miniflux/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U miniflux -d miniflux"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  miniflux:
    image: miniflux/miniflux:2.3.3@sha256:49d7b60987616387c306a8023087b31f2c9b7b21288b523026cb04058e8b6dbb
    container_name: miniflux
    restart: unless-stopped
    env_file: /srv/miniflux/.env
    environment:
      # Hex rather than base64 in the connection string on purpose: upstream
      # warns that a password carrying special characters can be rejected in
      # this URL form unless it is URL encoded, and hex has none to encode.
      DATABASE_URL: postgres://miniflux:${DB_PASSWORD}@postgres:5432/miniflux?sslmode=disable
      # Miniflux runs its own SQL migrations and exits at start-up when the
      # schema is behind the binary, so this stays set through every upgrade.
      RUN_MIGRATIONS: "1"
      # The single account is built from ADMIN_USERNAME and ADMIN_PASSWORD in
      # .env on the first start, and every start after that logs that it is
      # skipping because the user exists. Miniflux has no self-registration, so
      # this is the only door into the instance.
      CREATE_ADMIN: "1"
      # Caddy terminates TLS and speaks plain http to this container, so the
      # session cookie has to be told it travels over https or the browser
      # will not keep it.
      HTTPS: "1"
    healthcheck:
      # Upstream's own health check: the binary asks its own /healthcheck
      # route, which answers 200 only when the database answers as well.
      test: ["CMD", "/usr/bin/miniflux", "-healthcheck", "auto"]
      interval: 10s
      retries: 12
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8180.
      - "127.0.0.1:8180:8080"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/miniflux && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/miniflux/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your
terminal: run `rm /srv/miniflux/compose.yml` and paste again in one go. Note the `cd` on the
last line, and keep it on every later compose command: `docker compose` reads
/srv/miniflux/.env from the working directory to fill in `${DB_PASSWORD}`, and from anywhere
else that substitution comes out empty.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-miniflux
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Miniflux · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://miniflux.app/docs/howto.html,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also BASE_URL in .env, and Miniflux builds its session cookie and every link
# it renders from BASE_URL, so the two have to agree exactly.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# Upstream asks a proxy for X-Forwarded-Proto and X-Forwarded-For, and
	# Caddy's reverse_proxy sends both by default, so there is nothing to add
	# here. 8180 is the loopback port compose publishes on this host. It is
	# not a container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8180
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-miniflux /etc/caddy/Caddyfile`,
reload, and paste again. Check that the `<DOMAIN>` inside the block is your real hostname and
that it matches `BASE_URL` in .env character for character, because those two disagreeing is
the failure in step 10 and it does not announce itself.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8180` or `5432`.

If you do not: delete anything for `8180` or `5432` with `sudo ufw delete allow 8180`. 8180 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

Miniflux runs its database migrations on the way up and creates the one account from the
environment during that same start-up.

```bash
cd /srv/miniflux
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthcheck; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/v1/me
curl -sS https://<DOMAIN>/ | grep -c 'Sign In - Miniflux'
docker compose logs miniflux | grep -c 'admin user'
```

You should see, in order: the loop reaching `200`, then `OK`, then `401`, then `1`, then `1`
or more.

If you do not: the `401` is the one worth understanding. Miniflux's REST API is on by default
and answers 401 to a call carrying no token, so seeing it means the API is up and refusing
strangers. A `404` in its place means Caddy is not reaching the container: check
`docker compose ps`. If the loop never reaches `200`, run
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy
is step 2 done wrong, and `docker compose logs --tail 40 miniflux` second. The last count is
`1` on a first install, where the log line reads `Created new admin user`, and also `1` on a
second run, where it reads `Skipping admin user creation because it already exists`. A `0`
there means no account was made and nobody can log in.

Open https://<DOMAIN> in a browser. The first screen is a sign-in form with `Username` and
`Password` fields and a `Login` button, and the browser tab reads `Sign In - Miniflux`. Sign
in as `admin` with the password from step 3. There is no sign-up link on that page, because
Miniflux has none to show: accounts are made by you in the admin screen and nowhere else, and
that is why this install does not have a registration door to close afterwards.

The next step is yours, and it is the reason most people run this. A phone reader app talks to
Miniflux through the Google Reader or Fever API, and each is switched on under `Settings` then
`Integrations` by choosing a second username and password there. The server address the app
asks for is https://<DOMAIN>. Upstream names Capy Reader, NetNewsWire and Reeder Classic as
Google Reader clients, and Unread, FeedMe and NewsFlash as Fever ones.

## 8. First backup and restore

Two artifacts. The database holds every feed, entry, read mark and the account. The config
archive holds the files that rebuild the service around it.

```bash
cd /srv/miniflux
docker compose exec -T postgres pg_dump -U miniflux -d miniflux | gzip > /srv/miniflux/backups/miniflux-db-$(date +%F).sql.gz
sudo tar -czf /srv/miniflux/backups/miniflux-config-$(date +%F).tar.gz -C /srv/miniflux compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/miniflux/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/miniflux
scp vps:/srv/miniflux/backups/* ~/backups/miniflux/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/miniflux/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives. `No such file or directory` means the wildcard matched nothing, so check the listing on
the server again.

Now prove the restore, today, while the only thing at risk is an empty reader:

```bash
cd /srv/miniflux
docker compose down
sudo rm -rf /srv/miniflux/postgres
sudo install -d -m 700 /srv/miniflux/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/miniflux/backups/miniflux-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U miniflux -d miniflux
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/healthcheck; echo
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `OK` from the last command,
and you can still sign in as `admin` with the same password.

If you do not: `role "miniflux" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what is at stake
before you skip this: your subscriptions, your folders and years of read history are all in
that one dump, and the OPML export under `Settings` is a list of feeds, not a copy of what you
have read.

## 9. Updating later

New versions are listed at https://github.com/miniflux/v2/releases. Take both backup artifacts
first, then edit the `image:` line in /srv/miniflux/compose.yml to the new tag and its digest.

```bash
cd /srv/miniflux
docker compose pull
docker compose up -d
docker compose logs --tail 30 miniflux
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Miniflux
migrates its own schema on the way up and exits at start-up if the schema is behind the binary,
which is why `RUN_MIGRATIONS` stays set in the compose file rather than being a one-off. Re-run
the health check from step 7 before you call the update done.

## 10. What will probably go wrong

The login form will accept your password and hand you back the login form, with no error
message anywhere. I lost twenty minutes to that. Miniflux redirects a failed CSRF check back to
the login page silently, and the usual reason the check fails is that the browser never kept
the session cookie: `HTTPS` is set in compose.yml, so the cookie carries the secure flag, and
it is dropped if you reached the page over plain http or on any address other than the one in
`BASE_URL`. If a sign-in loops without complaining, run
`sudo grep BASE_URL /srv/miniflux/.env` and compare it character for character with what is in
your address bar before you read a single log line.

## 11. Out of scope

- Do not enable the Google Reader or Fever API from the command line or by editing the
  database. Each is switched on in your own settings by choosing a credential, and that choice
  is yours.
- Do not configure OAUTH2 or OIDC. Registering an application with an outside identity provider
  is a second install, and `OAUTH2_USER_CREATION` opens a second way for accounts to appear.
- Do not set `METRICS_COLLECTOR`. It publishes a Prometheus endpoint, and nothing on this box
  is scraping one.
- Do not lower `POLLING_FREQUENCY` below its 60 minute default to make feeds arrive faster.
  That multiplies outbound requests to sites that did not ask for them.
