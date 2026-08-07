You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Fider v0.36.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname becomes
`BASE_URL`, Fider builds every sign-in link it mails out of that value, and changing it later
invalidates links people already hold.

Fider needs 1024 MB of RAM available and 5 GB free on /srv. Both images publish amd64 and arm64.
Measure four things:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop.

Settle one thing more, because step 3 stops dead without it. Fider has no passwords: you sign in
by following a link it mails you, and the container refuses to boot until it is told where to
post mail. Upstream states that without a valid SMTP server you get
`panic: could not find environment variable named 'EMAIL_SMTP_HOST'`. Tell the user to have a
host, port, username and password from a transactional mail provider in front of them, and an
address for outgoing mail.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/fider /srv/fider/backups
sudo install -d -m 700 /srv/fider/postgres
ls -la /srv/fider
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root. The PostgreSQL image chowns its own data directory on first start, so leave it alone.
There is no uploads folder: `BLOB_STORAGE` defaults to `sql`, so logos and post images are rows
too.

## 3. Secrets

Two secrets: the PostgreSQL password and the token-signing key. Generate both on the server. Do
not print either, do not repeat them in your summary, and do not put them in any log line. Hex
for both: one rides inside a connection string where escaping would bite, and 64 bytes of it
clears the 512 bits upstream's own secret generator recommends for `JWT_SECRET`.

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

Assert: the file exists with mode `-rw-------`. `JWT_SECRET` signs every session and sign-in
link, so rotating it signs everybody out. `SIGNUP_DISABLED` is false only until step 7 closes
it: while it is false, whoever reaches the hostname first can claim this board.

STOP: tell the user to open `nano /srv/fider/.env`, replace every `CHANGE_ME` with the matching
value, correct `EMAIL_SMTP_PORT` if their relay is not 587, add a line reading
`EMAIL_SMTP_ENABLE_IMPLICIT_TLS=true` if it is 465, and save. Do not continue until they
confirm, and never ask them to paste those values to you.

```bash
grep -c CHANGE_ME /srv/fider/.env || true
```

Assert: that prints `0`. It counts lines, never values.

## 4. compose.yml

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

Assert: that prints `compose OK`. No password sits in that file: compose reads
`${POSTGRES_PASSWORD}` out of /srv/fider/.env.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-fider, reload, and report what it objected to. Caddy asks for the
certificate on the first request, renews it itself, and sets X-Forwarded-Proto, which is how
Fider knows the request arrived over https.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8181 stays closed because compose binds it to 127.0.0.1, 5432 because compose never
publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8181 or 5432.

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

Assert all four, and print what you received for each. The loop ends printing `200`. The health
body is exactly `{"status":"Healthy"}`, Fider answering after a database ping. The bare hostname
prints `307`, because no board exists yet and Fider redirects to the installer. The grep prints
`1`. If any of the four misses, stop, run `docker compose logs --tail 60 fider` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a
`panic: could not find environment variable named` line points at step 3, where a `CHANGE_ME`
survived; a database that never reports healthy points at step 2; a `502` while the loop still
runs means migrations are going. A running container is not success.

The first screen at https://<DOMAIN>/signup is the installer, headed `1. Who are you?` above a
name and email box, with `2. What is this Feedback Forum for?` below.

STOP: tell the user to open https://<DOMAIN>/signup, fill in their name, their email and the
name of the board, submit it, then follow the link in the confirmation mail Fider sends. Do not
continue until they confirm the board has opened. That mail is the only proof the relay from
step 3 works, and until the link is followed every page says `Pending Activation`. If nothing
lands within two minutes, read step 10 first.

Once they confirm, close the installer and prove it is closed:

```bash
sed -i 's/^SIGNUP_DISABLED=false$/SIGNUP_DISABLED=true/' /srv/fider/.env
cd /srv/fider
docker compose up -d --force-recreate fider
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/signup
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert: the loop reaches `200` again, /signup prints `404` and the bare hostname prints `200`.
That pair is the security assert here. Both must pass before you report success.

## 8. First backup and restore

Two artifacts. The database holds every post, vote, comment, account and image. The config
archive rebuilds the service around it.

```bash
cd /srv/fider
docker compose exec -T postgres pg_dump -U fider -d fider | gzip > /srv/fider/backups/fider-db-$(date +%F).sql.gz
sudo tar -czf /srv/fider/backups/fider-config-$(date +%F).tar.gz -C /srv/fider compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/fider/backups/
```

Assert: both files exist and are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. A backup on the same disk is not a backup, so run
this from the user's machine:

```bash
mkdir -p ~/backups/fider
scp vps:/srv/fider/backups/* ~/backups/fider/
```

To restore: `docker compose down`, `sudo rm -rf /srv/fider/postgres`, recreate that directory as
in step 2, untar the config archive into /srv/fider so .env is back before anything starts,
`docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U fider -d fider`, then `docker compose up -d`. Tell the
user why the archive matters as much as the dump: `JWT_SECRET` lives in .env, every session and
sign-in link is signed with it, and a database restored beside a new key logs everybody out.

## 9. Updating later

New versions are listed at https://github.com/getfider/fider/releases, and the tags that exist
as images at https://hub.docker.com/r/getfider/fider/tags. Check the second list too: on
2026-08-07 the newest release was v0.36.1 and the registry carried no image under that name,
which is why this pins v0.36.0. Do not answer that with the `stable` tag upstream's guide uses;
it moves without telling you. Take both backups first, then edit the image line in
/srv/fider/compose.yml to the new tag and its digest:

```bash
cd /srv/fider
docker compose pull
docker compose up -d
docker compose logs --tail 40 fider
```

Fider migrates its database on the way up, so watch that log until it settles, then re-run the
`/_health` check from step 7 before calling the update done.

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
- Do not set `HOST_MODE` to multi-tenant. One board per install is what this prompt asserts
  against, and multi-tenant wants a wildcard certificate.
