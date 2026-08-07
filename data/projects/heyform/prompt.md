You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install HeyForm v3.0.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. That hostname becomes `APP_HOMEPAGE_URL`, and
every form link is it plus `/form/` and an id, so changing it later breaks links already in
other people's inboxes.

HeyForm with MongoDB and Valkey needs 2048 MB of RAM available and 10 GB free on /srv. All
three images publish amd64 and arm64. MongoDB 7 also needs the AVX instruction set on x86:
mongod exits at start-up without it, and no variable fixes that. Measure all five:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
grep -c -w avx /proc/cpuinfo || true
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. Stop as well if the architecture is `amd64` and the AVX count is `0`, or
if `dig +short` prints nothing.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/heyform /srv/heyform/backups /srv/heyform/uploads
ls -la /srv/heyform
```

Assert: `ls -la` shows `backups` and `uploads` owned by the login user. There is no database
directory: the mongo image chowns /data/db to its own uid, so both databases live in named
volumes that step 8 dumps. `uploads` is real because it holds the files respondents attach,
the one thing a dump does not contain.

## 3. Secrets

Four secrets: the session key, the form-token key, the MongoDB password and the Valkey
password. Generate all four on the server. Do not print any of them, do not repeat them in
your summary, and do not put them in a log line. Hex, because two travel in connection
strings.

```bash
umask 077
cat > /srv/heyform/.env <<EOF
APP_HOMEPAGE_URL=https://<DOMAIN>
SESSION_KEY=$(openssl rand -hex 32)
FORM_ENCRYPTION_KEY=$(openssl rand -hex 32)
MONGO_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/heyform/.env
umask 022
ls -l /srv/heyform/.env
```

Replace `<DOMAIN>` on the first line with the real hostname first. Assert: mode
`-rw-------`. It does two jobs: Compose fills the `${MONGO_PASSWORD}` and `${REDIS_PASSWORD}`
slots in the next step from it, and the HeyForm container reads it as its environment.
`SESSION_KEY` encrypts the login cookie, `FORM_ENCRYPTION_KEY` the token a live form page
carries, so rotating either signs everyone out and breaks open form pages.

## 4. compose.yml

```bash
cat > /srv/heyform/compose.yml <<'EOF'
# HeyForm · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   self-hosting ... https://docs.heyform.net/open-source/self-hosting
#   image and port . https://github.com/heyform/heyform/blob/v3.0.0/Dockerfile
#   variables ...... https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/environments/index.ts
#   health ......... https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/controller/health.controller.ts
#
# Three services: HeyForm, the MongoDB holding every form and answer, and the
# Valkey carrying sessions and the job queue. Upstream's compose names
# percona/percona-server-mongodb:4.4 and eqalpha/keydb; this file pins mongo
# 7.0, because MongoDB 4.4 left support on 2024-02-29 and HeyForm's Mongoose
# 7.8.7 covers server 7.x, and Valkey, because KeyDB ships no multi-arch
# versioned tag and last released in 2023. Both databases are named volumes:
# the mongo image chowns /data/db to its own uid. Digests read on 2026-08-07;
# all three images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mongo:
    image: mongo:7.0.39@sha256:35a5926f71f8b6cb19206bee928c5a85f241a8be99f20c81abe35ae78a73415d
    restart: unless-stopped
    command: ["mongod", "--bind_ip_all", "--quiet"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: heyform
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD}
    volumes:
      - heyform-mongo:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "quit(db.adminCommand({ping:1}).ok === 1 ? 0 : 1)"]
      interval: 10s
      retries: 30
      start_period: 20s
    # No `ports:` on either database: both stay on the compose network.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    restart: unless-stopped
    environment:
      VALKEY_PASSWORD: ${REDIS_PASSWORD}
    command: ["sh", "-c", "exec valkey-server --appendonly yes --requirepass \"$$VALKEY_PASSWORD\""]
    volumes:
      - heyform-valkey:/data
    healthcheck:
      test: ["CMD-SHELL", 'valkey-cli -a "$$VALKEY_PASSWORD" --no-auth-warning ping | grep -q PONG']
      interval: 10s
      retries: 30

  heyform:
    image: heyform/community-edition:v3.0.0@sha256:27507032eb39ddb23dcadb4490ad383a104d1a32a6b368ad0f2e78538a187877
    restart: unless-stopped
    env_file: /srv/heyform/.env
    environment:
      # authSource=admin: the credential is the root user mongo makes there.
      MONGO_URI: mongodb://mongo:27017/heyform?authSource=admin
      MONGO_USER: heyform
      REDIS_HOST: valkey
      REDIS_PORT: 6379
      ENABLE_GOOGLE_FONTS: "false"
    volumes:
      - /srv/heyform/uploads:/app/packages/server/static/upload
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8170.
      - "127.0.0.1:8170:9157"
    depends_on:
      mongo:
        condition: service_healthy
      valkey:
        condition: service_healthy

volumes:
  heyform-mongo:
  heyform-valkey:
EOF
cd /srv/heyform && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. HeyForm serves on 9157 inside its container, the port its
own Dockerfile exposes; 8170 is bound to 127.0.0.1, so Caddy is the only route in.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-heyform
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# HeyForm · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.heyform.net/open-source/self-hosting and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_HOMEPAGE_URL in .env, and HeyForm builds its cookie domain and its
# CORS allowlist from that one value, so the two have to match or the dashboard
# signs you straight back out.

<DOMAIN> {
	# No X-Frame-Options on purpose: HeyForm ships an embed library and turns
	# frameguard off itself, so a form is meant to run inside another page.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8170 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. HeyForm sets Express
	# trust-proxy to 1, so it reads the visitor address Caddy forwards.
	reverse_proxy 127.0.0.1:8170
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-heyform, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, and idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3. 8170 stays closed because it is bound to 127.0.0.1, and neither 27017 nor
6379 has a host port to firewall. Assert: `ufw status verbose` prints `Status: active`, shows
80, 443/tcp and 443/udp, and no rule for the other three.

## 7. Start and verify

MongoDB creates its root user the first time it initialises an empty volume, and HeyForm waits
for both databases to be healthy.

```bash
cd /srv/heyform
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health/ready); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health/ready
curl -sS https://<DOMAIN>/login | grep -o '<title>HeyForm</title>'
```

Assert all three, and print what you received for each. The loop ends printing `200`. The
readiness body contains `"checks":{"mongo":"up","redis":"up"}`, the only line that proves both
databases answered rather than one failing authentication silently. The grep prints
`<title>HeyForm</title>`, which the server writes into every page it renders. If any of the
three misses, stop, run `docker compose logs --tail 40 heyform` and
`docker compose logs --tail 20 mongo`, and name the cause: `"mongo":"down"` points at step 3,
where a `.env` rewritten after the volume existed leaves the old password in the database. A
running container is not success.

The first screen at https://<DOMAIN>/login is a sign-in form with an `Email address` field and
a `create an account` link under the heading. Registration is open to anyone who reaches this
hostname until the next step closes it.

STOP: tell the user to open https://<DOMAIN>/sign-up now, create their account with a real
email address, and confirm once they are signed in on the workspace screen.
Do not continue until they confirm. Tell them HeyForm refuses disposable-address domains, and
that no confirmation mail arrives: there is no mail server and the account works without one.

Once they confirm, close registration and restart:

```bash
cd /srv/heyform
echo 'APP_DISABLE_REGISTRATION=true' >> /srv/heyform/.env
docker compose up -d --force-recreate heyform
sleep 20
curl -sS https://<DOMAIN>/api/config | grep -o '"appDisableRegistration":true'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/sign-up
```

Assert: the grep prints `"appDisableRegistration":true` and the last curl prints `302`, the
redirect a visitor with no workspace invitation now gets. The sign-up mutation refuses too, so
this is not a hidden button. Then have the user reload https://<DOMAIN>/login and confirm the
`create an account` link is gone. All three land before you report success.

## 8. First backup and restore

Two artifacts. The database holds every form, every submission and the account. The config
archive holds what rebuilds the service, plus the uploads a dump misses.

```bash
cd /srv/heyform
docker compose exec -T mongo sh -c 'mongodump --quiet --archive --gzip --db=heyform -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > /srv/heyform/backups/heyform-db-$(date +%F).archive.gz
sudo tar -czf /srv/heyform/backups/heyform-config-$(date +%F).tar.gz -C /srv/heyform compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/heyform/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing goes offline:
`mongodump` reads a running database consistently, and the credentials stay inside the
container. A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/heyform
scp vps:/srv/heyform/backups/* ~/backups/heyform/
```

To restore: untar the config archive into /srv/heyform first, so compose.yml and .env are back
before any container starts: mongo takes its root password from .env the moment it initialises
an empty volume. Then `docker compose down -v`, the one place `-v` belongs, then
`docker compose up -d mongo`, wait for healthy, and feed the archive in:

```bash
gunzip -c ~/backups/heyform/heyform-db-*.archive.gz | docker compose exec -T mongo sh -c 'mongorestore --archive --drop -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
```

Then `docker compose up -d`. Tell the user the stakes: every answer anyone sent them is a row
in that dump, and a form whose responses nobody copied off the box dies with the disk.

## 9. Updating later

New versions are listed at https://github.com/heyform/heyform/releases. Take both backups
first, then edit the image line in /srv/heyform/compose.yml to the new tag and digest:

```bash
cd /srv/heyform
docker compose pull
docker compose up -d
docker compose logs --tail 30 heyform
```

HeyForm applies its own schema changes on the way up, so watch that log until it settles, then
re-run step 7's three asserts. Leave the mongo line alone: a database major version is a
separate migration.

## 10. What will probably go wrong

`APP_HOMEPAGE_URL`. I wrote the hostname in without the scheme, the sign-in page rendered
perfectly over https, and I believed the install had worked. Then every login bounced back to
the sign-in screen with nothing in any log. HeyForm builds the cookie domain and the
credentialed-CORS allowlist from that string, so a value the browser does not read as the
origin it is talking to means the session cookie is set and then ignored. If sign-in loops, run
`docker compose exec -T heyform printenv APP_HOMEPAGE_URL` first. It must read `https://` and
the hostname, no trailing slash, no port.

## 11. Out of scope

- Do not configure SMTP. HeyForm creates the account, signs the user in and records
  submissions with no mail server. Mail adds verification, password reset and response
  notifications, and outbound mail from a fresh VPS is a fight for another day.
- Do not set `GOOGLE_LOGIN_CLIENT_ID` or the Apple login variables. Each is an account
  somewhere else and a second failure mode; this install has a working sign-in.
- Do not set the `S3_` variables. Attachments belong in /srv/heyform/uploads, which step 8
  puts in the backup archive.
- Do not set `OPENAI_API_KEY`, `AKISMET_KEY` or the reCAPTCHA keys. Each is a third-party
  subscription, and the builder, the logic and storage work without them.
