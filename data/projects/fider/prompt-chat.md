This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Fider v0.36.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. Fider has no passwords. You sign in by following a link it mails you,
and the container will not start at all until it is told where to post mail, so this install
needs an SMTP relay from a transactional mail provider before it needs anything else. Have the
host, port, username, password and a from-address in front of you. `<DOMAIN>` also becomes
`BASE_URL`, which Fider prints inside every link it sends, so pick the hostname you intend to
keep.

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
hostname while the certificate is issued.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/fider /srv/fider/backups
sudo install -d -m 700 /srv/fider/postgres
ls -la /srv/fider
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. There is no uploads directory here and that is not an omission:
`BLOB_STORAGE` defaults to `sql`, so logos and images uploaded to a post are rows in the
database like everything else.

## 3. Secrets

Two secrets: the PostgreSQL password and the token-signing key. Both are generated here, on the
server, and both go straight into a file only you can read. Hex for both, because one rides
inside a connection string where escaping would bite, and 64 bytes of it clears the 512 bits
upstream's own secret generator recommends for `JWT_SECRET`.

```bash
umask 077
cat > /srv/fider/.env <<EOF
BASE_URL=https://<DOMAIN>
POSTGRES_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 64)
SIGNUP_DISABLED=false
EMAIL_NOREPLY=CHANGE_ME
EMAIL_SMTP_HOST=CHANGE_ME
EMAIL_SMTP_PORT=587
EMAIL_SMTP_USERNAME=CHANGE_ME
EMAIL_SMTP_PASSWORD=CHANGE_ME
EOF
chmod 600 /srv/fider/.env
umask 022
ls -l /srv/fider/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

Now open `nano /srv/fider/.env` and replace every `CHANGE_ME` with the matching value from your
relay. Correct `EMAIL_SMTP_PORT` if your relay is not 587, and add a line reading
`EMAIL_SMTP_ENABLE_IMPLICIT_TLS=true` if it is 465. Then count what is left:

```bash
grep -c CHANGE_ME /srv/fider/.env || true
```

You should see: `0`. That command counts lines, never values.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/fider/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten both
secrets, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed one on an existing volume shows up as an
authentication failure in the Fider log rather than as anything about passwords.

Do not paste that file, either secret, your relay password, or any output containing them into
this chat window. The agent path never sees those values, and this one will hand them to a third
party unless you keep them out.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/fider/compose.yml <<'EOF'
# Fider · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker hosting ... https://docs.fider.io/hosting-instance
#   configuration .... https://github.com/getfider/fider/blob/v0.36.0/app/pkg/env/env.go
#   health route ..... https://github.com/getfider/fider/blob/v0.36.0/app/cmd/routes.go
#   image entrypoint . https://github.com/getfider/fider/blob/v0.36.0/Dockerfile
#
# Two services: Fider and the PostgreSQL that holds every post, vote, comment,
# account and uploaded image, because BLOB_STORAGE defaults to sql. Upstream
# requires PostgreSQL 12 or newer; this pins 16. Upstream's guide runs
# getfider/fider:stable, a tag that moves under you, so this pins the newest
# version tag the registry carries, v0.36.0, by digest. LOG_SQL is off:
# upstream defaults it to true, inserting every log line into a logs table
# nothing reads or trims. `fider migrate` runs before the server listens, which
# the health check's start period allows for. Digests read on 2026-08-07; both
# images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: fider-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: fider
      POSTGRES_USER: fider
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/fider/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U fider -d fider"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  fider:
    image: getfider/fider:v0.36.0@sha256:466669b3c932158d7fc082d4037ad881fce6c5cd49cf973e15d9bcaedc27889a
    container_name: fider
    restart: unless-stopped
    env_file: /srv/fider/.env
    environment:
      DATABASE_URL: postgres://fider:${POSTGRES_PASSWORD}@postgres:5432/fider?sslmode=disable
      # Upstream's default is true, which writes every log line into a logs
      # table nothing reads. The console log is unaffected.
      LOG_SQL: "false"
    healthcheck:
      # The image ships `fider ping`, which asks its own /_health route.
      test: ["CMD", "./fider", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    ports:
      - "127.0.0.1:8181:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/fider && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/fider/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/fider/compose.yml` and paste again in one go. No password appears in that file:
compose reads `${POSTGRES_PASSWORD}` out of /srv/fider/.env to build the connection string.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-fider
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Fider · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.fider.io/hosting-instance,
# https://docs.fider.io/how-to-enable-ssl and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also BASE_URL in .env, and Fider builds every sign-in link it mails out of
# BASE_URL, so the two have to agree exactly.

<DOMAIN> {
	# Fider already sets Content-Security-Policy, X-Content-Type-Options and
	# Referrer-Policy itself, so this adds only the two it does not: HSTS,
	# because the way in is a link that arrives by mail, and a framing rule,
	# because Fider ships no embeddable widget.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Frame-Options "SAMEORIGIN"
		-Server
	}

	encode zstd gzip

	# 8181 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8181
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-fider /etc/caddy/Caddyfile`, reload, and
paste again. Caddy asks for the certificate on the first request and renews it itself, and it
sets X-Forwarded-Proto, which is how Fider knows the request arrived over https even though it
speaks plain http on 8181.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8181` or `5432`.

If you do not: delete anything for `8181` or `5432` with `sudo ufw delete allow 8181`. 8181 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The image runs `fider migrate` before the server listens, so the first boot takes minutes.

```bash
cd /srv/fider
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/_health
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/signup | grep -c 'Sign up for Fider and let your customers share'
```

You should see, in order: the loop reaching `200`, then exactly `{"status":"Healthy"}`, then
`307`, then `1`.

If you do not: the `307` is the one worth understanding. No board exists yet, so Fider redirects
the bare hostname to its installer, and seeing that redirect is good news rather than a
misconfiguration. A `panic: could not find environment variable named` line in
`docker compose logs --tail 60 fider` points straight back at step 3, where a `CHANGE_ME`
survived. If the loop never reaches `200`, run `docker compose logs --tail 20 postgres` first,
because a database that never reports healthy is step 2 done wrong. A running container is not
success.

The first screen at https://<DOMAIN>/signup is the installer, headed `1. Who are you?` above a
name and email box, with `2. What is this Feedback Forum for?` below it. Open it in a browser,
fill in your name, your email address and the name of the board, and submit. Fider then mails
you a confirmation link and shows `Pending Activation` on every page until you follow it. That
mail arriving is the only proof your relay works; if nothing lands within two minutes, read step
10 before touching anything.

Once the board has opened, close the installer and prove it is closed:

```bash
sed -i 's/^SIGNUP_DISABLED=false$/SIGNUP_DISABLED=true/' /srv/fider/.env
cd /srv/fider
docker compose up -d --force-recreate fider
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/signup
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: the loop reaching `200` again, then `404` for /signup, then `200` for the bare
hostname.

If you do not: a `307` from /signup instead of `404` means the `sed` did not match, so check
that the line in .env reads `SIGNUP_DISABLED=true` and recreate the container again. This pair
is the security assert of the whole install. Left open on a public hostname, the installer is a
board anyone who finds your address can claim.

## 8. First backup and restore

Two artifacts. The database holds every post, vote, comment, account and image. The config
archive rebuilds the service around it.

```bash
cd /srv/fider
docker compose exec -T postgres pg_dump -U fider -d fider | gzip > /srv/fider/backups/fider-db-$(date +%F).sql.gz
sudo tar -czf /srv/fider/backups/fider-config-$(date +%F).tar.gz -C /srv/fider compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/fider/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/fider
scp vps:/srv/fider/backups/* ~/backups/fider/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/fider/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty board:

```bash
cd /srv/fider
docker compose down
sudo rm -rf /srv/fider/postgres
sudo install -d -m 700 /srv/fider/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/fider/backups/fider-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U fider -d fider
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200`, which means the board
survived a database that was deleted and rebuilt.

If you do not: `role "fider" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand why the config archive
matters as much as the dump: `JWT_SECRET` lives in .env, every session and every unexpired
sign-in link is signed with it, and a database restored beside a freshly generated key logs
everybody out at once.

## 9. Updating later

New versions are listed at https://github.com/getfider/fider/releases, and the tags that exist
as images at https://hub.docker.com/r/getfider/fider/tags. Check the second list too: on
2026-08-07 the newest release was v0.36.1 and the registry carried no image under that name,
which is why this pins v0.36.0. Do not answer that with the `stable` tag upstream's guide uses;
it moves without telling you. Take both backups first, then edit the `image:` line in
/srv/fider/compose.yml to the new tag and its digest.

```bash
cd /srv/fider
docker compose pull
docker compose up -d
docker compose logs --tail 40 fider
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/_health` check from step 7 before you call the update done, and open the board as well,
because a service that answers `Healthy` can still be failing to render if a migration stopped
halfway.

## 10. What will probably go wrong

The confirmation mail. I filled in the installer, the page turned into `Pending Activation`, and
I sat there for ten minutes with a healthy container, a `200` from `/_health` and an empty inbox,
because Fider had handed the message to the relay and the relay had refused it out of sight. The
board is half-created at that point: not empty, not usable, and reloading fixes nothing. Read
`docker compose logs --tail 60 fider` first, then the spam folder. Mine was a from-address the
relay had not verified, so `EMAIL_NOREPLY` had to change. Upstream documents the reset if you
must start over: `TRUNCATE TABLE tenants RESTART IDENTITY CASCADE;` piped through
`docker compose exec -T postgres psql -U fider -d fider`, which deletes the board and everything
on it. Safe on the day you install, and never again.

## 11. Out of scope

- Do not configure Google, Facebook, GitHub or any other OAuth sign-in. Each is an app
  registered in somebody else's console, and this install signs people in by email.
- Do not set `SSL_AUTO`, `SSL_CERT` or `SSL_CERT_KEY`. Caddy terminates TLS here, and upstream's
  own certificate integration requires that Fider not sit behind a proxy.
- Do not switch `BLOB_STORAGE` to `s3` or `fs`. The database default keeps the whole install in
  one dump; an object store is a second thing to back up and to secure.
- Do not set `HOST_MODE` to multi-tenant. One board per install is what these steps assert
  against, and multi-tenant wants a wildcard certificate.
