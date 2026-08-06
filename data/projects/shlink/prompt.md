You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Shlink 5.1.5 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. Say this to them when you ask, because it is the one decision in this install that
cannot be undone: `<DOMAIN>` becomes `DEFAULT_DOMAIN`, the domain on the front of every
short link they ever hand out, and changing it later breaks all of them. Its A record must
already point at this server.

Shlink needs 1024 MB of RAM available and 5 GB free on /srv. Both images publish amd64 and
arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop.
Do not install and hope. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/shlink /srv/shlink/backups
sudo install -d -m 700 /srv/shlink/postgres
ls -la /srv/shlink
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700`
owned by root. The PostgreSQL image chowns its own data directory on first start, so leave
that one alone. Shlink itself keeps nothing on disk that matters, because the links and
the visits are in the database.

## 3. Secrets

Two secrets: the PostgreSQL password and the initial API key. Generate both on the server.
Do not print either, do not repeat them in your summary, and do not put them in any log
line. Hex rather than base64, because one travels in an HTTP header and the other inside a
connection string.

```bash
umask 077
cat > /srv/shlink/.env <<EOF
DEFAULT_DOMAIN=<DOMAIN>
TIMEZONE=UTC
DB_PASSWORD=$(openssl rand -hex 32)
INITIAL_API_KEY=$(openssl rand -hex 24)
EOF
chmod 600 /srv/shlink/.env
umask 022
ls -l /srv/shlink/.env
```

Assert: the file exists with mode `-rw-------`. Upstream documents `INITIAL_API_KEY` as a
key created once during container start-up with admin permissions, so this is the
credential the user's apps will use. Do not run the CLI command that lists API keys at any
point: it prints their values straight to the terminal, which is the one thing this step
exists to avoid.

## 4. compose.yml

```bash
cat > /srv/shlink/compose.yml <<'EOF'
# Shlink · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://shlink.io/documentation/install-docker-image/
#   variable reference . https://shlink.io/documentation/environment-variables/
#   database engines ... https://shlink.io/documentation/supported-db-engines/
#   api health check ... https://shlink.io/documentation/api-docs/
#
# Two services: Shlink and the PostgreSQL it stores links and visits in. The image
# ships a working SQLite database, and this file ignores it, because upstream says
# SQLite is for testing and closed the request to make its file mountable as a
# volume. A database you cannot persist is not a database. Tags and digests were
# read from the registries on 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: shlink-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: shlink
      POSTGRES_USER: shlink
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/shlink/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U shlink -d shlink"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  shlink:
    image: shlinkio/shlink:5.1.5@sha256:77b8eb87bcb1a56bd0ecc590398d415545e5ba83414f28d37dc565a91c3c50b2
    container_name: shlink
    restart: unless-stopped
    env_file: /srv/shlink/.env
    environment:
      DB_DRIVER: postgres
      DB_HOST: postgres
      DB_NAME: shlink
      DB_USER: shlink
      # Shlink is behind Caddy, which terminates TLS, so it has to be told that
      # the links it generates are https even though it speaks plain http here.
      IS_HTTPS_ENABLED: "true"
      # No IP tracking, therefore no GeoLite2 download and no MaxMind account.
      # Visits are still counted; they are not placed on a map.
      DISABLE_IP_TRACKING: "true"
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8086.
      - "127.0.0.1:8086:8080"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/shlink && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The image ships a working SQLite database and this file
ignores it, because upstream says SQLite is for testing rather than production and closed
the request to make its file mountable as a volume. A database that cannot survive
recreating the container is not a database, so PostgreSQL it is.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by
the real hostname. Copy the file first: a syntax error here takes down every other site on
the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-shlink
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Shlink · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://shlink.io/documentation/install-docker-image/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# DEFAULT_DOMAIN in .env, and it is the domain every short link you hand out will
# carry, so it is the one value here you cannot change your mind about later.

<DOMAIN> {
	# Short links are redirects, so there is nothing worth compressing and no
	# frame to worry about. HSTS is here because every link is public and
	# permanent, and a downgrade on one of them is a downgrade on all of them.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8086 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8086
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-shlink, reload, and report what it objected to. Caddy
terminates TLS and speaks plain http to the container, which is why `IS_HTTPS_ENABLED` is
true in compose.yml: without it Shlink would print `http://` links for a service only
reachable over https.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8086 stays closed because it is bound to 127.0.0.1, and 5432 stays
closed because compose never publishes it: the database has no host port to firewall.
Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and
no rule for 8086 or 5432.

## 7. Start and verify

Shlink runs its own database migrations on the way up, and creates the API key named in
`INITIAL_API_KEY` once during that start-up.

```bash
cd /srv/shlink
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/rest/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/rest/health
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/rest/v3/short-urls
docker compose exec -T shlink shlink short-url:create https://example.com/ --custom-slug=selfhost-check
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/selfhost-check
```

Assert, all five. The loop ends printing `200`. The health response contains
`"status":"pass"`. The unauthenticated API call prints `401`, which upstream documents as
the answer to a missing or invalid key, and that is the security assert in this block. The
CLI prints a short URL on `<DOMAIN>`. The last curl prints `302`, which is the whole
product working end to end: a slug went into the database and came back out as a redirect.
Print what you received for each. If any of the five misses, stop, run
`docker compose logs --tail 40 shlink` and `docker compose logs --tail 20 postgres`, and
say which earlier step is the likely cause: a database container that never reports
healthy points at step 2, and a `404` where a `401` was expected means Caddy is not
reaching the container. A running container is not success.

There is no first screen. Shlink has no web interface, and https://<DOMAIN>/ answers `404`
because nothing has been configured to redirect the base URL. The screen a human should
look at is https://<DOMAIN>/rest/health, which returns a small JSON object whose `status`
field reads `pass`.

STOP: tell the user to read their API key with
`sudo grep INITIAL_API_KEY /srv/shlink/.env`, put it in their password manager, and wait.
Do not continue until they confirm. It is the only credential this install has, and every
app or script they point at this server will ask for it. Tell them the test link can go
whenever they like, with
`docker compose exec -T shlink shlink short-url:delete selfhost-check`.

## 8. First backup and restore

Two artifacts. The database holds the links, the slugs and the visit counts. The config
archive holds the files that rebuild the service around them.

```bash
cd /srv/shlink
docker compose exec -T postgres pg_dump -U shlink -d shlink | gzip > /srv/shlink/backups/shlink-db-$(date +%F).sql.gz
sudo tar -czf /srv/shlink/backups/shlink-config-$(date +%F).tar.gz -C /srv/shlink compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/shlink/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped,
because `pg_dump` snapshots a running database consistently. A backup on the same disk is
not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/shlink
scp vps:/srv/shlink/backups/* ~/backups/shlink/
```

To restore: `docker compose down`, `sudo rm -rf /srv/shlink/postgres`, recreate it as in
step 2, `docker compose up -d postgres`, wait for it to report healthy, then pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U shlink -d shlink`, untar the config archive into
/srv/shlink, and `docker compose up -d`. Tell the user plainly what the stakes are: every
short link they have ever shared is a row in that database, and losing it means every one
of those links is dead, on other people's pages, permanently.

## 9. Updating later

New versions are listed at https://github.com/shlinkio/shlink/releases. Take both backup
artifacts first, then edit the image line in /srv/shlink/compose.yml to the new tag and
its digest:

```bash
cd /srv/shlink
docker compose pull
docker compose up -d
docker compose logs --tail 30 shlink
```

Shlink migrates its own database on the way up, so watch that log until it settles, then
re-run the health check from step 7 before calling the update done.

## 10. What will probably go wrong

You will open https://<DOMAIN> in a browser, get a bare `404`, and conclude the install
failed. I did. It had not: Shlink is a redirector with no home page, and nothing is
configured to redirect its base URL, so `404` at the root is the correct answer rather
than a fault. The endpoint that tells you the truth is https://<DOMAIN>/rest/health. Do
not fix the `404` by pointing the base URL somewhere; check health, create a link, and
follow it.

## 11. Out of scope

- Do not install shlink-web-client. The dashboard is a separate application with its own
  container and its own hostname, and this prompt installs the server that it would talk
  to.
- Do not set `GEOLITE_LICENSE_KEY` or enable IP tracking. That means a MaxMind account,
  and this install trades country charts for not having one.
- Do not set `DEFAULT_BASE_URL_REDIRECT`. Where the bare domain sends a visitor is an
  editorial decision the user makes, not a fix for step 10.
- Do not configure SMTP. Shlink sends no mail, so there is nothing for it to do.
