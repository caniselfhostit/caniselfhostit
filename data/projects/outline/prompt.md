You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Outline 1.9.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer. Its
A record must already point here. Say this when you ask: `<DOMAIN>` becomes `URL`, and Outline
builds every mailed sign-in link, share link and passkey origin out of it.

Outline needs 2048 MB of RAM available and 10 GB free on /srv. All three images publish amd64 and
arm64. Measure four things:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both and stop, do not
install and hope. If `dig +short` prints nothing, print that and stop.

Settle one thing more, because step 3 stops dead without it. Outline has no password login: the
first workspace is claimed on a form offered only while none exists, and after that the way in is
a mailed link. Have the user hold relay host, port, username, password and a from-address ready.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/outline /srv/outline/backups
sudo install -d -m 700 /srv/outline/postgres /srv/outline/redis
sudo install -d -m 750 -o 1001 -g 1001 /srv/outline/data
ls -la /srv/outline
```

Assert: `backups` owned by the login user, `postgres` and `redis` at mode `700` owned by root,
`data` owned by uid `1001`. The first two images chown their own directories; `data` cannot, and
Outline runs as uid 1001, so any other owner gives an install where uploads fail and nothing
else does.

## 3. Secrets

Three secrets: the key that encrypts stored data, the utility secret, and the PostgreSQL password.
Generate all three on the server, print none, repeat none in your summary, keep all three out of
every log line. Hex, because upstream requires `SECRET_KEY` to be exactly 64 hex characters.

```bash
umask 077
cat > /srv/outline/.env <<EOF
URL=https://<DOMAIN>
SECRET_KEY=$(openssl rand -hex 32)
UTILS_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
SMTP_HOST=CHANGE_ME
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USERNAME=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
SMTP_FROM_EMAIL=CHANGE_ME
EOF
chmod 600 /srv/outline/.env
umask 022
ls -l /srv/outline/.env
```

Assert: mode `-rw-------`. Upstream states that changing `SECRET_KEY` later leaves users unable to
log in, so it must survive every restore.

STOP: tell the user to open `nano /srv/outline/.env`, replace every `CHANGE_ME` with the value
from their mail provider, set `SMTP_PORT` to 465 and `SMTP_SECURE` to true if their relay wants
that, and save. Do not continue until they confirm, and never ask them to paste those values to
you. Outline exits at start-up on a mailbox address it cannot parse, so a `CHANGE_ME` left behind
is a container that will not boot.

```bash
awk '/CHANGE_ME/ {n++} END {print n+0}' /srv/outline/.env
```

Assert: `0`. It counts lines, never values.

## 4. compose.yml

```bash
cat > /srv/outline/compose.yml <<'EOF'
# Outline · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation and source, not copied from a repository:
#   docker hosting ..... https://docs.getoutline.com/s/hosting/doc/docker-7pfeLP5a8t
#   variables and smtp . https://github.com/outline/outline/blob/v1.9.2/.env.sample
#   image .............. https://github.com/outline/outline/blob/v1.9.2/Dockerfile
#
# Three services: Outline, the PostgreSQL holding every document and revision,
# and the Redis carrying the collaborative editor, the job queue and the rate
# limiter. Upstream calls URL, DATABASE_URL, REDIS_URL and SECRET_KEY the
# minimum. Four settings below are not defaults and each breaks something if
# left out. FILE_STORAGE defaults to s3, so uploads fail until it says local.
# PGSSLMODE must say disable: Outline turns on SSL to Postgres in production
# and this Postgres speaks plain TCP. WEB_CONCURRENCY pins one web process,
# upstream's rule being memory divided by 512. ENABLE_UPDATES is false, its
# default posting a hashed install id and the user, team, collection and
# document counts to updates.getoutline.com daily.
#
# The image runs as uid 1001 and declares /var/lib/outline/data a VOLUME.
# Digests read on 2026-08-14; all three images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.6-alpine@sha256:432b3b824c0769275ec9b0947736ef8b376d6997bcaa9de29818f613819c2feb
    container_name: outline-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: outline
      POSTGRES_USER: outline
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/outline/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U outline -d outline"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: outline-redis
    restart: unless-stopped
    # appendonly writes every change to disk, and noeviction makes Redis refuse
    # writes rather than silently drop a queued job when memory runs out.
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - /srv/outline/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 6379 never leaves the compose network.

  outline:
    image: outlinewiki/outline:1.9.2@sha256:32d76719c378931dd65d93945930ca380d8376a0337d98a991fcc12b266f33cf
    container_name: outline
    restart: unless-stopped
    env_file: /srv/outline/.env
    environment:
      DATABASE_URL: postgres://outline:${DB_PASSWORD}@postgres:5432/outline
      PGSSLMODE: disable
      REDIS_URL: redis://redis:6379
      FILE_STORAGE: local
      WEB_CONCURRENCY: "1"
      ENABLE_UPDATES: "false"
    volumes:
      # Attachments, avatars and imports, in the path the image calls a VOLUME.
      - /srv/outline/data:/var/lib/outline/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8185.
      - "127.0.0.1:8185:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/outline && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Outline runs its own migrations on the way up, so nothing schedules one.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with every `<DOMAIN>` inside it
replaced by the real hostname. Copy the file first: a syntax error takes every other site down.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-outline
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Outline · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.getoutline.com/s/hosting/doc/docker-7pfeLP5a8t and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also URL in .env, and Outline builds
# every mailed sign-in link and share link out of it, so the two must agree.

<DOMAIN> {
	encode zstd gzip

	# No X-Frame-Options or CSP here: Outline sets both itself, per route.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8185 is the loopback port compose publishes, never open in the firewall.
	# The editor rides WebSockets on it, which Caddy upgrades unasked, and
	# Caddy's X-Forwarded-Proto is what lets Outline's FORCE_HTTPS settle.
	reverse_proxy 127.0.0.1:8185
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-outline, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it with nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent: on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the only way in, 443/udp is HTTP/3.
8185 binds to 127.0.0.1; 5432 and 6379 are never published. Assert: `Status: active`, rules for
80 and both 443s, none for the other three.

## 7. Start and verify

The first start runs the migrations, so it is slow. Read the security shape first: while no
workspace exists the server offers a `Create workspace` form to anyone, and the first to fill it
in becomes admin.

```bash
cd /srv/outline
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/_health; echo
curl -sS -H 'content-type: application/json' -d '{}' https://<DOMAIN>/api/auth.config; echo
```

Assert all three and print what you received. The loop ends printing `200`. `/_health` prints
`OK`, returned only after querying PostgreSQL and pinging Redis. The config call prints
`{"data":{"providers":[]},"status":200,"ok":true}`: no workspace yet, no sign-in option yet. If
any miss, stop, run `docker compose logs --tail 40 outline`, and name the cause.
`Environment configuration is invalid` is step 3; a line about the database not supporting SSL
means `PGSSLMODE` never arrived, which is step 4. A running container is not success.

STOP: tell the user to open https://<DOMAIN> now, fill in the `Create workspace` form with a
workspace name, their own name and their own email, and confirm they land inside the wiki.
Do not continue until they confirm. Tell them now, not later: until they do, that form is open to
anyone who reaches the hostname.

Once they confirm, prove the door is shut:

```bash
curl -sS -H 'content-type: application/json' -d '{}' https://<DOMAIN>/api/auth.config; echo
curl -sS -o /dev/null -w '%{http_code}\n' -H 'content-type: application/json' -d '{}' https://<DOMAIN>/api/documents.list
curl -sS -H 'content-type: application/json' -d '{"teamName":"closed","userName":"closed","userEmail":"closed@example.com"}' https://<DOMAIN>/api/installation.create; echo
```

Assert all three and print every response. The config call now carries the workspace name and a
provider whose `"id"` is `"email"`, the mail sign-in option, which proves the relay settings
reached the container. The documents call prints `401`: nothing is readable without a session. The
last prints `Installation already has existing teams`, the create-workspace route refusing to run
twice, and that refusal is the closure. Anything else, stop.

STOP: tell the user to sign out, enter their email on the sign-in page, open the link in the mail
that arrives, and confirm they are back inside. Do not continue until they confirm they are signed
in again. An install whose mail never arrives is one expired cookie from locking its owner out; if
nothing comes, `docker compose logs --tail 40 outline` carries the SMTP error. A passkey added
under Settings, Security is a second way in that needs no mail.

## 8. First backup and restore

Two artifacts: a dump of every document, revision, comment and account, and an archive of the
attachments plus the three files that rebuild the service around them.

```bash
cd /srv/outline
docker compose exec -T postgres pg_dump -U outline -d outline | gzip > /srv/outline/backups/outline-db-$(date +%F).sql.gz
sudo tar -czf /srv/outline/backups/outline-files-$(date +%F).tar.gz -C /srv/outline compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/outline/backups/
```

Assert: both exist and are non-empty. Print the sizes. Nothing stops: `pg_dump` snapshots a
running database consistently. A backup on the same disk is not a backup, so run this from the
user's machine:

```bash
mkdir -p ~/backups/outline
scp vps:/srv/outline/backups/* ~/backups/outline/
```

To restore: `docker compose down`, `sudo rm -rf /srv/outline/postgres /srv/outline/data`, recreate
both as in step 2, untar the archive with `sudo tar -xzf` into /srv/outline so `.env` and the
1001 owner on `data` come back before anything starts, `docker compose up -d postgres`, wait for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U outline -d outline`, then `docker compose up -d`. The two
travel together: `SECRET_KEY` decrypts columns in that dump, so a database beside a fresh key is a
wiki nobody can sign in to.

## 9. Updating later

New versions are listed at https://github.com/outline/outline/releases; release tag `v1.9.2` and
image tag `1.9.2` are the same number. This pins the newest stable line, not the `nightly` tag the
registry also carries, built from the day's commits. Back up first, then edit the image line in
/srv/outline/compose.yml to the new tag and digest:

```bash
cd /srv/outline
docker compose pull
docker compose up -d
docker compose logs --tail 40 outline
```

Watch that log until the migrations settle, then re-run step 7's `/_health` and `auth.config`
checks before calling the update done.

## 10. What will probably go wrong

Mail. I had a relay that accepted the connection and then refused the message, and Outline answers
the sign-in form with the same screen either way, deliberately, so nobody can use it to learn
which addresses have accounts. Nothing on the page told me. The install looked finished, and was
one browser session from being a wiki I could not get into: no password, and no reset link that
does not itself arrive by mail. That is why step 7 signs the user out and back in. The usual
causes are a relay wanting port 465 with `SMTP_SECURE=true`, or an unverified sender.

## 11. Out of scope

- Do not configure Google, Slack, Microsoft, Discord or generic OIDC sign-in. Each is an app
  registered with somebody else, and this install needs none of them.
- Do not set `FILE_STORAGE=s3` or any `AWS_` variable. Attachments live in /srv/outline/data,
  which keeps the backup at two files and no bucket policy.
- Do not run the `outlinewiki/outline-enterprise` image, which is the paid edition.
- Do not enable the Notion, GitHub, Linear or Figma integrations. Each is a separate developer
  application with its own client secret.
