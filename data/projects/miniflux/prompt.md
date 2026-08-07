You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Miniflux 2.3.3 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say one thing to them when you ask: that
hostname becomes `BASE_URL`, and Miniflux builds its session cookie and every link it renders
from `BASE_URL`, so a hostname that does not match the address in the browser produces a login
page that will not log anyone in.

Miniflux needs 1024 MB of RAM available and 5 GB free on /srv. The reader is a single Go binary
and costs almost nothing; PostgreSQL is the heavier half of that floor, and the entry history
is what grows the disk. Both images publish amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a hostname that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/miniflux /srv/miniflux/backups
sudo install -d -m 700 /srv/miniflux/postgres
ls -la /srv/miniflux
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root. The PostgreSQL image chowns its own data directory on first start, so leave that one
alone. There is no data directory for Miniflux itself, and that is not an omission: feeds,
entries, read state and the account are all rows in PostgreSQL.

## 3. Secrets

Two secrets: the PostgreSQL password and the password for the user's own Miniflux account.
Generate both on the server. Do not print either, do not repeat them in your summary, and do
not put them in any log line.

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

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the
real hostname before running the block. The database password is hex because upstream warns
that special characters can be rejected inside a URL-style connection string unless they are
URL encoded, and hex has nothing to encode. Tell the user their username is `admin`, that they
read the password once with `sudo grep ADMIN_PASSWORD /srv/miniflux/.env`, and that they should
put it in their password manager now.

## 4. compose.yml

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

Assert: that prints `compose OK`. `docker compose` reads /srv/miniflux/.env for the
`${DB_PASSWORD}` substitutions, which is why the working directory matters on every command in
this prompt that touches compose.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-miniflux, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own. Nothing to schedule.

## 6. Firewall

Two ports open, both of them Caddy's. Idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8180 stays closed because it is bound to 127.0.0.1, and 5432 stays closed
because compose never publishes it. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule for 8180 or 5432.

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

Assert, all five, and print what you received for each. The loop ends printing `200`. The
health body is `OK`, which upstream returns only when the database answers as well. The
unauthenticated API call prints `401`, and that is the security assert here: the REST API is on
by default and refuses a call carrying no token. The page grep prints `1`, because the login
screen's title is `Sign In - Miniflux`. The log grep prints `1` or more, matching either
`Created new admin user` on a first start or `Skipping admin user creation because it already
exists` on a repeat. If any of the five misses, stop, run
`docker compose logs --tail 40 miniflux` and `docker compose logs --tail 20 postgres`, and name
the likely earlier step: a database that never reports healthy is step 2, a Miniflux container
that exits after a line about the password is step 3, and a `404` where a `401` was expected
means Caddy is not reaching the container. A running container is not success.

The first screen at https://<DOMAIN> is a sign-in form with `Username` and `Password` fields
and a `Login` button, and the browser tab reads `Sign In - Miniflux`. There is no sign-up link,
because Miniflux has none to show.

STOP: tell the user to open https://<DOMAIN>, sign in as `admin` with the password from step 3,
and wait. Do not continue until they confirm they are looking at the reader.

Then tell them the next step is theirs, concretely. A phone reader app talks to Miniflux
through the Google Reader or Fever API, and each is switched on under `Settings` then
`Integrations` by choosing a second username and password there. The server address the app
asks for is https://<DOMAIN>. Upstream names Capy Reader, NetNewsWire and Reeder Classic as
Google Reader clients, and Unread, FeedMe and NewsFlash as Fever ones. That credential is
theirs to pick and this install does not create it.

## 8. First backup and restore

Two artifacts. The database holds every feed, entry, read mark and the account. The config
archive holds the files that rebuild the service around it.

```bash
cd /srv/miniflux
docker compose exec -T postgres pg_dump -U miniflux -d miniflux | gzip > /srv/miniflux/backups/miniflux-db-$(date +%F).sql.gz
sudo tar -czf /srv/miniflux/backups/miniflux-config-$(date +%F).tar.gz -C /srv/miniflux compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/miniflux/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. A backup on the same disk is not a backup,
so run this from the user's machine:

```bash
mkdir -p ~/backups/miniflux
scp vps:/srv/miniflux/backups/* ~/backups/miniflux/
```

To restore: `docker compose down`, `sudo rm -rf /srv/miniflux/postgres`, recreate it as in step
2, untar the config archive back into /srv/miniflux so .env is in place before anything starts,
`docker compose up -d postgres`, wait for it to report healthy, then pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U miniflux -d miniflux`, then
`docker compose up -d`. Tell the user plainly what the stakes are: the subscriptions, the
folders and years of read history are all in that one dump, and the OPML export under
`Settings` is a list of feeds, not a copy of what they have read.

## 9. Updating later

New versions are listed at https://github.com/miniflux/v2/releases. Take both backup artifacts
first, then edit the image line in /srv/miniflux/compose.yml to the new tag and its digest:

```bash
cd /srv/miniflux
docker compose pull
docker compose up -d
docker compose logs --tail 30 miniflux
```

Miniflux migrates its own schema on the way up and exits at start-up if the schema is behind
the binary, which is why `RUN_MIGRATIONS` stays set rather than being a one-off. Watch that
log until it settles, then re-run step 7's health check before calling the update done.

## 10. What will probably go wrong

The login form will accept the password and hand back the login form again, with no error
message anywhere. I lost twenty minutes to that. Miniflux redirects a failed CSRF check back to
the login page silently, and the usual reason the check fails is that the browser never kept
the session cookie: `HTTPS` is set in compose.yml, so the cookie carries the secure flag, and
it is dropped if the page was reached over plain http or on any address other than the one in
`BASE_URL`. If a sign-in loops without complaining, run
`sudo grep BASE_URL /srv/miniflux/.env` and compare it character for character with what is in
the address bar before you read a single log line.

## 11. Out of scope

- Do not enable the Google Reader or Fever API from the command line or by editing the
  database. Each is switched on in the user's own settings by choosing a credential, and that
  choice is theirs.
- Do not configure OAUTH2 or OIDC. Registering an application with an outside identity provider
  is a second install, and `OAUTH2_USER_CREATION` opens a second way for accounts to appear.
- Do not set `METRICS_COLLECTOR`. It publishes a Prometheus endpoint, and nothing on this box
  is scraping one.
- Do not lower `POLLING_FREQUENCY` below its 60 minute default to make feeds arrive faster.
  That multiplies outbound requests to sites that did not ask for them.
