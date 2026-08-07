You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Rallly 4.12.1 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname becomes
`NEXT_PUBLIC_BASE_URL`, it is printed inside every invitation this instance mails, and changing
it later breaks links other people are already holding.

Rallly needs 2048 MB of RAM available and 5 GB free on /srv, upstream's own floor. Both images
publish amd64 and arm64. Measure four things:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop.

Settle one thing more, because step 3 stops dead without it. Rallly signs people in by mailing a
six-digit code, so this instance needs an SMTP relay. Upstream names Resend, Postmark, Mailgun and
Brevo, and says not to run your own mail server and not to point this at a Gmail or Proton
mailbox, because consumer inboxes rate-limit automated senders and eventually block the sign-in
mail. Tell the user to have a host, port, username and password from a transactional provider in
front of them.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/rallly /srv/rallly/backups
sudo install -d -m 700 /srv/rallly/postgres
ls -la /srv/rallly
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root. The PostgreSQL image chowns its own data directory on first start, so leave that one alone.
Rallly keeps nothing else on disk: polls, options, votes, comments and accounts are all rows.

## 3. Secrets

Two secrets: the PostgreSQL password and the session key. Generate both on the server. Do not
print either, do not repeat them in your summary, and do not put them in any log line. Upstream
documents `openssl rand -hex 32` for `SECRET_PASSWORD` and rejects anything under 32 characters;
hex also keeps the connection string free of characters that would need escaping.

```bash
umask 077
cat > /srv/rallly/.env <<EOF
NEXT_PUBLIC_BASE_URL=https://<DOMAIN>
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SECRET_PASSWORD=$(openssl rand -hex 32)
REGISTRATION_ENABLED=true
SUPPORT_EMAIL=CHANGE_ME
INITIAL_ADMIN_EMAIL=CHANGE_ME
SMTP_HOST=CHANGE_ME
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=CHANGE_ME
SMTP_PWD=CHANGE_ME
EOF
chmod 600 /srv/rallly/.env
umask 022
ls -l /srv/rallly/.env
```

Assert: the file exists with mode `-rw-------`. `SUPPORT_EMAIL` is validated as an email address
at start-up, so the container refuses to boot while it reads `CHANGE_ME`. `INITIAL_ADMIN_EMAIL`
is the one address allowed to claim the admin role in step 7, and it should be the user's own.
`REGISTRATION_ENABLED` is true only until step 7 closes it.

STOP: tell the user to open `nano /srv/rallly/.env`, replace every `CHANGE_ME` with the matching
value, correct `SMTP_PORT` if their relay is not 587 and set `SMTP_SECURE=true` if it is 465,
save, and confirm. Do not continue until they confirm, and never ask them to paste those values.

```bash
grep -c CHANGE_ME /srv/rallly/.env || true
```

Assert: that prints `0`. It counts lines, never values.

## 4. compose.yml

```bash
cat > /srv/rallly/compose.yml <<'EOF'
# Rallly · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://support.rallly.co/self-hosting/installation/docker
#   configuration ...... https://support.rallly.co/self-hosting/configuration
#   entrypoint ......... https://github.com/lukevella/rallly/blob/v4.12.1/scripts/docker-start.sh
#   status endpoint .... https://github.com/lukevella/rallly/blob/v4.12.1/apps/web/src/app/api/status/route.ts
#
# Two services: Rallly and the PostgreSQL that holds every poll, vote, comment
# and account. Upstream's own stack adds a bundled Traefik and a Garage object
# store, and this file runs neither: Caddy on the host terminates TLS, and the
# S3 variables are optional, so leaving them unset costs avatar and logo
# uploads and nothing else. The container runs its own Prisma migrations before
# the server listens, which the health check's start period allows for. Digests
# read on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: rallly-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: rallly
      POSTGRES_USER: rallly
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/rallly/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U rallly -d rallly"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  rallly:
    image: lukevella/rallly:4.12.1@sha256:6049260ff6d3accd86730372a650b5e8063c373a09f253c45f7e4a8dc9202752
    container_name: rallly
    restart: unless-stopped
    env_file: /srv/rallly/.env
    environment:
      # Built here rather than kept in .env so the password appears once.
      DATABASE_URL: postgres://rallly:${POSTGRES_PASSWORD}@postgres:5432/rallly
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:3000/api/status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8153.
      - "127.0.0.1:8153:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/rallly && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No password sits in that file: compose reads
`${POSTGRES_PASSWORD}` out of /srv/rallly/.env to build the connection string. Upstream's stack
runs two containers this one does not, a Traefik and a Garage object store, and dropping Garage
costs avatar and logo uploads.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-rallly
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Rallly · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://support.rallly.co/self-hosting/installation/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also NEXT_PUBLIC_BASE_URL in .env, and the container reads it to build the
# poll links it mails out, so the two have to agree exactly.

<DOMAIN> {
	# Every invitee opens a page served from here, and the sign-in code arrives
	# by mail, so a downgrade attack has a real audience. Nothing here is meant
	# to be embedded in another site, so framing stays same-origin.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8153 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8153
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-rallly, reload, and report what it objected to. Caddy asks for the
certificate on the first request and renews it itself, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8153 stays closed because compose binds it to 127.0.0.1, and 5432 because compose never
publishes it, so the database has no host port a rule could apply to. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8153 or 5432.

## 7. Start and verify

The container applies its own Prisma migrations before the server listens, so the first boot takes
a few minutes on a small box.

```bash
cd /srv/rallly
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/status
curl -sS https://<DOMAIN>/login | grep -c '>Log in to your account or create a new one</p>'
```

Assert all three, and print what you received for each. The loop ends printing `200`. The status
body is a small JSON object containing `"status":"ok"` and `"database":"connected"`. The grep
prints `1`. If any misses, stop, run `docker compose logs --tail 60 rallly` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a database that never
reports healthy points at step 2; an `Invalid environment variables` line points at step 3, where
a `CHANGE_ME` left in `SUPPORT_EMAIL` or a short `SECRET_PASSWORD` stops the process before it
listens; a `502` while the loop still runs means migrations are still going. A running container
is not success.

The first screen at https://<DOMAIN>/login is headed `Welcome`, with
`Log in to your account or create a new one` under it and one box asking for an email address.

STOP: tell the user to open https://<DOMAIN>/login, enter the address they put in
`INITIAL_ADMIN_EMAIL`, type in the six-digit code Rallly mails to it, then open
https://<DOMAIN>/control-panel and press the button that makes them an admin.
Do not continue until they confirm both. That code arriving is the only proof the relay from
step 3 works; if nothing lands within two minutes, read step 10 before touching anything.

Once they confirm, close registration and prove it is closed:

```bash
sed -i 's/^REGISTRATION_ENABLED=true$/REGISTRATION_ENABLED=false/' /srv/rallly/.env
cd /srv/rallly
docker compose up -d --force-recreate rallly
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/login | grep -c '>Login to your account to continue</p>'
curl -sS https://<DOMAIN>/login | grep -c '>Log in to your account or create a new one</p>' || true
```

Assert: the loop reaches `200` again, the first grep prints `1` and the second prints `0`. That
pair is the security assert here. Registration left open on a public hostname is an account for
anyone who can receive mail, and voting on a poll never needed an account. Both asserts must pass
before you report success.

## 8. First backup and restore

Two artifacts. The database holds every poll, vote, comment and account. The config archive holds
what rebuilds the service around it.

```bash
cd /srv/rallly
docker compose exec -T postgres pg_dump -U rallly -d rallly | gzip > /srv/rallly/backups/rallly-db-$(date +%F).sql.gz
sudo tar -czf /srv/rallly/backups/rallly-config-$(date +%F).tar.gz -C /srv/rallly compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/rallly/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. A backup on the same disk is not a backup, so run this
from the user's machine:

```bash
mkdir -p ~/backups/rallly
scp vps:/srv/rallly/backups/* ~/backups/rallly/
```

To restore: `docker compose down`, `sudo rm -rf /srv/rallly/postgres`, recreate that directory as
in step 2, untar the config archive into /srv/rallly so .env is back before anything starts,
`docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U rallly -d rallly`, then `docker compose up -d`. Tell the
user why the archive matters as much as the dump: `SECRET_PASSWORD` lives in .env, every session
is sealed with it, and a database restored beside a new key logs everybody out at once.

## 9. Updating later

New versions are listed at https://github.com/lukevella/rallly/releases. Take both backup
artifacts first, then edit the image line in /srv/rallly/compose.yml to the new tag and its
digest:

```bash
cd /srv/rallly
docker compose pull
docker compose up -d
docker compose logs --tail 40 rallly
```

Rallly migrates its own database on the way up, so watch that log until it settles, then re-run
the `/api/status` check from step 7 before calling the update done. Stay inside the 4.x line: the
licence upstream sells is perpetual for 4.x and a major bump is a separate decision.

## 10. What will probably go wrong

The sign-in code will not arrive, and nothing will look broken. I sat on the `Verify your email`
screen for ten minutes with a healthy container, a `200` from `/api/status` and an empty inbox,
and the Rallly log said nothing, because the app had handed the message to the relay and the
relay had refused it out of sight. Make that conversation visible: add `SMTP_DEBUG=true` to
/srv/rallly/.env, run `docker compose up -d --force-recreate rallly`, try the sign-in again, and
read `docker compose logs --tail 60 rallly`. Mine was rejecting the from-address because the
domain was not verified with the relay yet. Take `SMTP_DEBUG` out once mail lands: it prints the
whole SMTP exchange into the log.

## 11. Out of scope

- Do not configure single sign-on. OIDC, Google and Microsoft each need a client registered in
  somebody else's console, and this install signs people in by email.
- Do not add upstream's bundled Traefik or Garage containers. Caddy already terminates TLS here,
  and the object store buys avatar and logo uploads at the price of a third service to operate.
- Do not set `APP_NAME`, `LOGO_URL` or `HIDE_ATTRIBUTION`. Those need a purchased licence key,
  and this install runs the free one.
- Do not install a mail server on this box. Upstream tells you to use a transactional provider,
  and port 25 on a fresh VPS is a fight with no prize.
