You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Mattermost 11.9.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. That hostname becomes
`MM_SERVICESETTINGS_SITEURL`, and every invite link and permalink is built from it.

Mattermost needs 2048 MB of RAM available and 10 GB free on /srv. Upstream supports 64-bit x86
processors and publishes the Team Edition image for amd64 only, so this install refuses an arm64
box rather than emulating one. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dpkg --print-architecture` prints anything other than `amd64`, print it
and stop: there is no arm64 image to pull. If `dig +short` prints nothing, print that and stop,
because Caddy cannot get a certificate for a name that does not resolve.

## 2. Layout

The server image is distroless and runs as uid 2000, and writes to four directories. Create those
with that owner and leave the PostgreSQL directory alone: the database image chowns its own
cluster on first start.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mattermost /srv/mattermost/backups
sudo install -d -m 750 -o 2000 -g 2000 /srv/mattermost/config /srv/mattermost/data /srv/mattermost/plugins /srv/mattermost/client-plugins
sudo install -d -m 700 /srv/mattermost/postgres
ls -la /srv/mattermost
```

Assert: `ls -la` shows `backups` owned by the login user, four directories owned by `2000`, and
`postgres` at mode `700` owned by root. If `config` belongs to anyone else the container exits
saying it cannot load its configuration, and that log line never mentions ownership.

## 3. Secrets

One secret: the PostgreSQL password. Generate it on the server. Do not print it, do not repeat it
in your summary, and do not put it in any log line. Hex rather than base64, because it is pasted
into a connection string where `+` and `/` would need escaping.

```bash
umask 077
cat > /srv/mattermost/.env <<EOF
DOMAIN=<DOMAIN>
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/mattermost/.env
umask 022
ls -l /srv/mattermost/.env
```

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the real
hostname before you write it. Compose reads this file for both `${DOMAIN}` and `${DB_PASSWORD}`,
so no secret is written into compose.yml. Mattermost writes its own at-rest encryption key and
public-link salt into `config/config.json` on first start, so there is nothing else to make here.

## 4. compose.yml

```bash
cat > /srv/mattermost/compose.yml <<'EOF'
# Mattermost · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   container deploy ... https://docs.mattermost.com/deployment-guide/server/deploy-containers.html
#   variable reference . https://github.com/mattermost/docker/blob/main/env.example
#
# Two services: Mattermost and the PostgreSQL that holds every message. The
# image is the Team Edition build, the compiled edition Mattermost, Inc.
# licenses under MIT; upstream's own compose file reaches for the enterprise
# build instead and runs it with no licence key. That image is distroless and
# runs as uid 2000, so the four directories it writes are made with that owner
# in step 2, while PostgreSQL 18 chowns its own cluster on first start.
# Upstream's /mattermost/logs mount is left out because `docker compose logs`
# already reads the console log, and an unrotated second copy on the same disk
# is a slow disk-full rather than a feature. Digests read 2026-08-06;
# PostgreSQL publishes amd64 and arm64, Mattermost only amd64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: mattermost-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: mattermost
      POSTGRES_USER: mmuser
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/mattermost/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mmuser -d mattermost"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 never leaves the compose network.

  mattermost:
    image: mattermost/mattermost-team-edition:11.9.0@sha256:1c538cf33c2144ba2c825571cd414aaaebf8d8c231d4b18081b811cd0ca0ef2a
    container_name: mattermost
    platform: linux/amd64
    restart: unless-stopped
    environment:
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: "postgres://mmuser:${DB_PASSWORD}@postgres:5432/mattermost?sslmode=disable&connect_timeout=10"
      # Caddy terminates TLS, so this says https although the container
      # speaks plain http. Every invite link is built from it.
      MM_SERVICESETTINGS_SITEURL: https://${DOMAIN}
      # Anonymous signup stays shut; the server exempts the first account.
      MM_TEAMSETTINGS_ENABLEOPENSERVER: "false"
      # No SMTP and no telemetry: no mail, nothing reported to Sentry.
      MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS: "false"
      MM_LOGSETTINGS_ENABLEDIAGNOSTICS: "false"
    volumes:
      - /srv/mattermost/config:/mattermost/config
      - /srv/mattermost/data:/mattermost/data
      - /srv/mattermost/plugins:/mattermost/plugins
      - /srv/mattermost/client-plugins:/mattermost/client/plugins
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8113.
      - "127.0.0.1:8113:8065"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/mattermost && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. A setting given as an `MM_` environment variable overrides
config.json and shows greyed out in the System Console, so the four hardening choices above
cannot be undone from a browser session.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-mattermost
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Mattermost · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.mattermost.com/deployment-guide/server/deploy-containers.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also MM_SERVICESETTINGS_SITEURL in compose.yml, and Mattermost builds every
# invite link and websocket address from it, so the two have to agree.

<DOMAIN> {
	encode zstd gzip

	# This server holds a team's messages, so nothing here should be sniffed
	# or handed to another site in a referrer. X-Frame-Options is absent on
	# purpose: Mattermost sets SAMEORIGIN and its own Content-Security-Policy,
	# and one set here would overwrite the application's answer.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8113 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. The webapp holds a
	# websocket open at /api/v4/websocket for as long as it is on screen, and
	# Caddy's reverse_proxy performs that upgrade with no extra directive.
	reverse_proxy 127.0.0.1:8113
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-mattermost, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own; nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8113 stays closed because it is bound to 127.0.0.1, and 5432 stays closed because
compose never publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80,
443/tcp and 443/udp, and no rule for 8113 or 5432.

## 7. Start and verify

Mattermost runs its own database migrations on the way up. The first start is much slower than
the second.

```bash
cd /srv/mattermost
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v4/system/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v4/system/ping
curl -sS https://<DOMAIN>/api/v4/config/client | tr ',' '\n' | grep NoAccounts
```

Assert, all three: the loop ends printing `200`; the ping response contains `"status":"OK"`; the
last line prints `"NoAccounts":"true"`, the server saying it has no users yet. Print what you
received for each. If any of the three misses, stop, run
`docker compose logs --tail 40 mattermost` and `docker compose logs --tail 20 postgres`, and
name the likely cause: a database that never reports healthy points at step 3, and a Mattermost
log that cannot load its configuration points at the ownership of /srv/mattermost/config in step
2. A running container is not success.

The first screen at https://<DOMAIN> is the account form, headed `Create your account`. The first
account made here becomes the system administrator, and until it exists that form is open to
anyone who loads the page.

STOP: tell the user to open https://<DOMAIN> now, create their account, and put that password in
their password manager, then wait. Do not continue until they confirm. There is no mail in this
install, so a forgotten administrator password has no reset link.

Once they confirm, prove the window is shut:

```bash
curl -sS https://<DOMAIN>/api/v4/config/client | tr ',' '\n' | grep NoAccounts
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"email":"signup-check@example.invalid","username":"signupcheck"}' https://<DOMAIN>/api/v4/users
```

Assert: the first prints `"NoAccounts":"false"`, and the second prints `403`, the server refusing
an anonymous signup now that an account exists. Both must pass before you report success.

## 8. First backup and restore

Two artifacts. The database holds every message, channel and account. The file archive holds the
uploads, the generated config and the pieces that rebuild the service around them.

```bash
cd /srv/mattermost
docker compose exec -T postgres pg_dump -U mmuser -d mattermost | gzip > /srv/mattermost/backups/mattermost-db-$(date +%F).sql.gz
sudo tar -czf /srv/mattermost/backups/mattermost-files-$(date +%F).tar.gz -C /srv/mattermost compose.yml .env config data -C /etc/caddy Caddyfile
ls -lh /srv/mattermost/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. A backup on the same disk is not a backup, so run this
from the user's machine:

```bash
mkdir -p ~/backups/mattermost
scp vps:/srv/mattermost/backups/* ~/backups/mattermost/
```

To restore: `docker compose down`, `sudo rm -rf /srv/mattermost/postgres`, recreate it as in step
2, `docker compose up -d postgres`, wait about 30 seconds for it to report healthy, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U mmuser -d mattermost`,
untar the file archive into /srv/mattermost, then `docker compose up -d`. Tell the user what
is at stake: a database without the `data` directory is every message with every attachment
broken, and `config` carries the at-rest encryption key the server made on day one.

## 9. Updating later

New versions are listed at https://github.com/mattermost/mattermost/releases. Mattermost also
publishes an extended-support line that takes patches for longer; this tag is the current feature
release, not that one. Take both backups first, then edit the image line in
/srv/mattermost/compose.yml to the new tag and its digest:

```bash
cd /srv/mattermost
docker compose pull
docker compose up -d
docker compose logs --tail 30 mattermost
```

Watch that log until the migrations settle, then re-run step 7's ping check before calling the
update done. Move one major version at a time.

## 10. What will probably go wrong

The gap between the container starting and the user creating their account is a real hole, and I
walked away during it. Caddy publishes the hostname to the certificate transparency logs the
moment it issues, those logs are scraped within seconds, and while `NoAccounts` reads `true` the
first stranger to load that page becomes the system administrator. Nothing happened to me, but
nothing had to. Do not run step 7 until the user is at their keyboard, and do not treat that
pause as a formality.

## 11. Out of scope

- Do not configure SMTP. Mattermost runs without it and invitations work as copyable links from
  the Invite People dialog. Say plainly that password reset stays broken until mail exists.
- Do not enable AD/LDAP, SAML or OpenID sign-on. Those are licensed features of the paid
  editions, and turning them on here produces an error rather than a login page.
- Do not install the Calls, Playbooks or any other plugin. Each is a separate decision with its
  own ports and storage; this prompt installs the chat server.
- Do not switch the image to mattermost-enterprise-edition. That is a different licence, and this
  install chose Team Edition on purpose.
