You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Typebot 3.17.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.

Typebot is two applications, so this install answers on two names: the builder, where bots are
designed and the user signs in, on `<DOMAIN>`, and the viewer, what a visitor loads when they open
a published bot, on `bot.<DOMAIN>`. Both are Next.js servers owning the root path, so they cannot
share a hostname. Tell the user now: both names go into links they hand out, and both need an A
record on this server.

Settle one thing more, because step 3 stops dead without it: Typebot registers no sign-in method
at all until a mail relay or an outside identity provider is configured, and this install uses
mail. Tell the user to have a host, port, username, password and a from-address from a
transactional mail provider in front of them.

Typebot and its PostgreSQL need 2048 MB of RAM available and 15 GB free on /srv: the two
application images are over a gigabyte each compressed. All three publish amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
dig +short bot.<DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 15 GB, print both numbers and stop. If
either `dig +short` prints nothing, print which one and stop: Caddy cannot issue a certificate for
a name that will not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/typebot /srv/typebot/backups
sudo install -d -m 700 /srv/typebot/postgres
ls -la /srv/typebot
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root. The PostgreSQL image chowns its own data directory on first start, so leave that alone.
Nothing else of Typebot's lives on disk: bots, results and credentials are rows.

## 3. Secrets

Two secrets: the PostgreSQL password and `ENCRYPTION_SECRET`. Generate both on the server. Do not
print either, do not repeat them in your summary, and do not put them in a log line. Upstream
documents `openssl rand -base64 24` for `ENCRYPTION_SECRET`, and its schema rejects anything that
is not exactly 32 characters, which is what 24 random bytes of base64 come to.

```bash
umask 077
cat > /srv/typebot/.env <<EOF
NEXTAUTH_URL=https://<DOMAIN>
NEXT_PUBLIC_VIEWER_URL=https://bot.<DOMAIN>
NODE_OPTIONS=--no-node-snapshot
DISABLE_SIGNUP=true
DEFAULT_WORKSPACE_PLAN=UNLIMITED
ENCRYPTION_SECRET=$(openssl rand -base64 24)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
ADMIN_EMAIL=CHANGE_ME
NEXT_PUBLIC_SMTP_FROM=CHANGE_ME
SMTP_HOST=CHANGE_ME
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USERNAME=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
EOF
chmod 600 /srv/typebot/.env
umask 022
ls -l /srv/typebot/.env
```

Assert: the file exists with mode `-rw-------`, with `<DOMAIN>` on the first two lines replaced by
the real hostname. `DISABLE_SIGNUP` is true from the first boot and upstream's sign-in callback
lets exactly one address past it, whatever is in `ADMIN_EMAIL`, so there is no open-registration
window and nothing to close later. `DEFAULT_WORKSPACE_PLAN=UNLIMITED` overrides a `FREE` default
upstream's constants cap at 200 chats a month and one seat, and `NEXT_PUBLIC_SMTP_FROM` is what
registers the email sign-in provider at all.

STOP: tell the user to open `nano /srv/typebot/.env`, replace every `CHANGE_ME`, put their own
address in `ADMIN_EMAIL` because it is the only one that can create an account, correct
`SMTP_PORT` if their relay is not 587, set `SMTP_SECURE=true` if it is 465, and save. Do not
continue until they confirm, and never ask them to paste a value.

```bash
grep -c CHANGE_ME /srv/typebot/.env || true
```

Assert: that prints `0`. It counts lines, never values.

## 4. compose.yml

```bash
cat > /srv/typebot/compose.yml <<'EOF'
# Typebot · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install .. https://docs.typebot.com/self-hosting/deploy/docker
#   configuration ... https://docs.typebot.com/self-hosting/configuration
#
# Three services: builder, viewer, and the PostgreSQL holding both. Builder and
# viewer are Next.js servers that each own the root path, so each needs its own
# hostname and its own loopback port, and only the builder migrates the
# database. Neither image ships curl, so the health checks use node. Digests
# read 2026-08-07, all multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_DB: typebot
      POSTGRES_USER: typebot
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/typebot/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U typebot -d typebot"]
      interval: 10s
      retries: 12

  builder:
    image: baptistearno/typebot-builder:3.17.2@sha256:a67edf944eb64e885a3660d8bbd11102b9d468d31dbf4b7f6170e4cd2ceaa9d3
    restart: unless-stopped
    env_file: /srv/typebot/.env
    environment:
      DATABASE_URL: postgresql://typebot:${POSTGRES_PASSWORD}@postgres:5432/typebot
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/auth/providers').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
      interval: 15s
      retries: 24
      start_period: 120s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8177.
      - "127.0.0.1:8177:3000"
    depends_on:
      postgres:
        condition: service_healthy

  viewer:
    image: baptistearno/typebot-viewer:3.17.2@sha256:70f1dd949f2246432650cfda082c01e45089fb129369ceee6632d57b9c5f2b7e
    restart: unless-stopped
    env_file: /srv/typebot/.env
    environment:
      DATABASE_URL: postgresql://typebot:${POSTGRES_PASSWORD}@postgres:5432/typebot
    ports:
      # Loopback only: Caddy is the only thing that reaches 8977.
      - "127.0.0.1:8977:3000"
    depends_on:
      builder:
        condition: service_healthy
EOF
cd /srv/typebot && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No password sits in that file: compose reads
`${POSTGRES_PASSWORD}` from /srv/typebot/.env to build both connection strings.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced everywhere
it appears. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-typebot
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Typebot · the Caddy site blocks for this service.
#
# Authored by caniselfhostit from
# https://docs.typebot.com/self-hosting/deploy/docker and
# https://caddyserver.com/docs/automatic-https
#
# Two site blocks, because Typebot is two applications that cannot share a
# hostname. Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the
# hostname pointed at this box; bot.<DOMAIN> needs its own A record on the
# same address.

<DOMAIN> {
	# The builder. Sign-in codes land here and every bot design sits behind
	# that session, so nothing on this name should be framed by another site.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8177 is a loopback port, not a container port, and not in the firewall.
	reverse_proxy 127.0.0.1:8177
}

bot.<DOMAIN> {
	# The viewer, embedded in other people's pages on purpose, so no frame
	# restriction. An AI block streams, so this route flushes every write.
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	reverse_proxy 127.0.0.1:8977 {
		flush_interval -1
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-typebot, reload, and report what it objected to. Caddy issues both
certificates on the first request to each name and renews them itself.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box nothing changes:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8177 and 8977 stay closed because compose binds both to loopback, 5432 because compose
never publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8177, 8977 or 5432.

## 7. Start and verify

The first pull is over two gigabytes, and the builder applies its Prisma migrations before it
listens, so the first boot takes minutes.

```bash
cd /srv/typebot
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/auth/providers); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/auth/providers
curl -sS https://bot.<DOMAIN>/api/healthz
curl -sS -o /dev/null -w '%{http_code}\n' https://bot.<DOMAIN>/api/typebots
grep -c '^DISABLE_SIGNUP=true$' /srv/typebot/.env
```

Assert all five, and print what you received for each. The loop ends printing `200`. The providers
response is JSON containing `"nodemailer"`, the email sign-in method, which proves step 3's relay
settings were read. The viewer answers `{"status":"ok"}`. The unauthenticated call to
the viewer's API prints `401`, upstream's answer to a request with no bearer token, and that is
the security assert. The grep prints `1`. If any of the five misses, stop, run
`docker compose logs --tail 60 builder` and `docker compose logs --tail 20 postgres`, and name the
likely cause: a database that never reports healthy points at step 2; `Invalid environment
variables` points at step 3, where an `ENCRYPTION_SECRET` that is not exactly 32 characters stops
the process before it listens; a `502` means migrations are still going; `{}` from providers means
`NEXT_PUBLIC_SMTP_FROM` is empty. A running container is not success.

The first screen at https://<DOMAIN>/signin is headed `Sign In`, with `Don't have an account?`
under it and one box asking for an email address next to a `Submit` button.

STOP: tell the user to open https://<DOMAIN>/signin, enter the address they put in `ADMIN_EMAIL`,
and type in the six-digit code Typebot mails to it. Do not continue until they confirm they see an
empty bot list. That code arriving is the only proof the relay works; if nothing lands within two
minutes, read step 10 first. Any other address is refused with `Unauthorized`, which is what
`DISABLE_SIGNUP` does.

## 8. First backup and restore

Two artifacts. The database holds every bot, result and stored credential; the config archive
holds what rebuilds the service around it.

```bash
cd /srv/typebot
docker compose exec -T postgres pg_dump -U typebot -d typebot | gzip > /srv/typebot/backups/typebot-db-$(date +%F).sql.gz
sudo tar -czf /srv/typebot/backups/typebot-config-$(date +%F).tar.gz -C /srv/typebot compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/typebot/backups/
```

Assert: both files exist and are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database. A backup on the same disk is not a backup, so run this from the
user's machine:

```bash
mkdir -p ~/backups/typebot
scp vps:/srv/typebot/backups/* ~/backups/typebot/
```

To restore: `docker compose down`, `sudo rm -rf /srv/typebot/postgres`, recreate it as in step 2,
untar the config archive into /srv/typebot so .env is back before anything starts,
`docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U typebot -d typebot`, then `docker compose up -d`. The
archive matters as much as the dump: `ENCRYPTION_SECRET` in .env decrypts the provider keys in the
database, so a dump restored beside a freshly generated secret is unreadable.

## 9. Updating later

New versions are listed at https://github.com/baptisteArno/typebot.io/releases. Take both backups
first, then edit both `image:` lines in /srv/typebot/compose.yml to the new tag and digest,
keeping builder and viewer on the same version:

```bash
cd /srv/typebot
docker compose pull
docker compose up -d
docker compose logs --tail 40 builder
```

The builder migrates the database on the way up, so watch that log until it settles, then re-run
step 7's five checks. Leave the postgres tag alone unless a release note says so.

## 10. What will probably go wrong

The sign-in code will not arrive and nothing will look broken. I sat on the login-code screen with
three healthy containers, a `200` from the providers endpoint and an empty inbox, because the
relay had refused the message out of sight: Typebot only logs `Magic link email could not be sent`
when the send itself throws. Read `docker compose logs --tail 60 builder` first, since a rejected
from-address or a failed relay login shows up there. Mine was the from-address, on a domain the
relay had not verified. Check spam second, and only then suspect the install.

## 11. Out of scope

- Do not configure Google, GitHub, GitLab, Facebook, Azure AD or Keycloak sign-in. Each needs a
  client registered in somebody else's console; this install signs people in by email.
- Do not add S3 storage or a MinIO container. Media uploads inside bots want an object store on a
  third hostname, and an unset `S3_ACCESS_KEY` switches those blocks off.
- Do not add upstream's Redis container. It buys a per-IP rate limit on sign-ins.
- Do not install a mail server here. Use the relay from step 3; port 25 on a fresh VPS is a fight
  with no prize.
