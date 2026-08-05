This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Shlink 5.1.5 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A
record already points at the box.

Read this before step 1, because it is the one decision here you cannot undo. `<DOMAIN>`
becomes `DEFAULT_DOMAIN`, the domain on the front of every short link you will ever hand
out. Change it later and every link you have shared, on other people's pages, stops
working. Pick the short domain you intend to keep.

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
minute, run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname
that does not resolve, and failed attempts count against a rate limit you cannot see. An
IP that is not your server's usually means a proxying CDN sits in front of the record;
turn that off for this hostname, because a short link that is redirected twice is slower
for no benefit and the certificate will be issued to somebody else's edge.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/shlink /srv/shlink/backups
sudo install -d -m 700 /srv/shlink/postgres
ls -la /srv/shlink
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its
own data directory the first time it starts, and one you have already chowned to yourself
makes it refuse to initialise.

## 3. Secrets

Two secrets: the PostgreSQL password and the initial API key. Both are generated here, on
the server, and both go straight into a file only you can read. Hex rather than base64,
because one travels in an HTTP header and the other inside a connection string.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace
`<DOMAIN>` on the first line with your real hostname before you paste. Read the API key
once with `sudo grep INITIAL_API_KEY /srv/shlink/.env` and put it in your password
manager: it is the only credential this install has, and every app you point at this
server will ask for it.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens
if you pasted the lines separately in different shells. Run `chmod 600 /srv/shlink/.env`
and carry on. If the file already existed from an earlier attempt, this block has now
overwritten both secrets, which is fine before the database exists and a problem
afterwards: the database keeps the password it was created with, so a changed
`DB_PASSWORD` on an existing volume produces an authentication failure in the Shlink log
rather than anything about passwords.

Do not paste that file, either secret, or any output containing them into this chat
window. And do not run the CLI command that lists API keys while a chat window is open: it
prints their values straight to your terminal, which is exactly what step 3 exists to
avoid.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/shlink/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your
terminal: run `rm /srv/shlink/compose.yml` and paste again in one go. The image does ship
a working SQLite database, and this file ignores it, because upstream says SQLite is for
testing rather than production and closed the request to make its file mountable as a
volume. A database that cannot survive recreating the container is not a database.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>`
in the block with your hostname before you paste. The first line takes a copy, because a
syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-shlink /etc/caddy/Caddyfile`,
reload, and paste again. Caddy terminates TLS and speaks plain http to the container,
which is why `IS_HTTPS_ENABLED` is true in the compose file: without it Shlink would
generate `http://` links for a service that is only reachable over https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8086` or `5432`.

If you do not: delete anything for `8086` or `5432` with `sudo ufw delete allow 8086`.
8086 is bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the
database has no host port a firewall rule could apply to. 80/tcp is there to redirect to
HTTPS and to answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3,
which Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left
this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it
back before you go any further.

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

You should see, in order: the loop reaching `200`, a small JSON object containing
`"status":"pass"`, then `401`, then a line printing `https://<DOMAIN>/selfhost-check`,
then `302`.

If you do not: the `401` is the one worth understanding. It means the API is up and
refusing a call with no key, which is what upstream documents for a missing or invalid
key, so seeing it is good news. A `404` in its place means Caddy is not reaching the
container: check `docker compose ps`. If the loop never reaches `200`, run
`docker compose logs --tail 20 postgres` first, because a database that never reports
healthy is step 2 done wrong, and `docker compose logs --tail 40 shlink` second. That
final `302` is the whole product working end to end.

There is no first screen and no web interface, and https://<DOMAIN>/ answers `404`. That
is correct rather than broken. The page to look at in a browser is
https://<DOMAIN>/rest/health, which returns a small JSON object whose `status` field reads
`pass`. The test link can go whenever you like, with
`docker compose exec -T shlink shlink short-url:delete selfhost-check`.

## 8. First backup and restore

Two artifacts. The database holds the links, the slugs and the visit counts. The config
archive holds the files that rebuild the service around them.

```bash
cd /srv/shlink
docker compose exec -T postgres pg_dump -U shlink -d shlink | gzip > /srv/shlink/backups/shlink-db-$(date +%F).sql.gz
sudo tar -C /srv/shlink -czf /srv/shlink/backups/shlink-config-$(date +%F).tar.gz compose.yml Caddyfile .env
ls -lh /srv/shlink/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump`
failed and the shell created the file anyway. Run the dump line without `| gzip` to read
the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine,
not the server:

```bash
mkdir -p ~/backups/shlink
scp vps:/srv/shlink/backups/* ~/backups/shlink/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/shlink/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives. `No such file or directory` means the wildcard matched nothing, so check the
listing on the server again.

Now prove the restore, today, while the only thing at risk is a test link:

```bash
cd /srv/shlink
docker compose down
sudo rm -rf /srv/shlink/postgres
sudo install -d -m 700 /srv/shlink/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/shlink/backups/shlink-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U shlink -d shlink
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/selfhost-check
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `302` from the last
command, which means the link survived a database that was deleted and rebuilt.

If you do not: `role "shlink" does not exist` means the database container had not
finished initialising, so wait longer and run the `gunzip` line again. Understand the
stakes before you skip this: every short link you have ever shared is a row in that
database, and losing it means every one of those links is dead, on pages you do not
control, permanently.

## 9. Updating later

New versions are listed at https://github.com/shlinkio/shlink/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/shlink/compose.yml to the new tag and
its digest.

```bash
cd /srv/shlink
docker compose pull
docker compose up -d
docker compose logs --tail 30 shlink
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then
re-run the health check from step 7 before you call the update done, and follow one real
link as well, because a service that answers `pass` on health can still be failing to
resolve slugs if a migration stopped halfway.

## 10. What will probably go wrong

You will open https://<DOMAIN> in a browser, get a bare `404`, and conclude the install
failed. I did. It had not: Shlink is a redirector with no home page, and nothing here is
configured to redirect its base URL, so `404` at the root is the correct answer. The
endpoint that tells you the truth is https://<DOMAIN>/rest/health. Do not fix the `404` by
pointing the base URL somewhere; check health, create a link, and follow it.

## 11. Out of scope

- Do not install shlink-web-client. The dashboard is a separate application with its own
  container and hostname, and this install gives you the server it would talk to.
- Do not set `GEOLITE_LICENSE_KEY` or enable IP tracking. That means a MaxMind account,
  and this install trades country charts for not having one.
- Do not set `DEFAULT_BASE_URL_REDIRECT`. Where the bare domain sends a visitor is your
  editorial decision, not a fix for step 10.
- Do not configure SMTP. Shlink sends no mail, so there is nothing for it to do.
