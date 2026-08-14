You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Ghostfolio 3.50.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here, and that hostname becomes `ROOT_URL` in step 3.

Say three things first. Ghostfolio tracks investments: holdings, allocation, performance,
dividends, net worth, and has no spending feed, no categories, no budgets. It connects to no
bank, so activities are typed in or imported from a CSV. Prices come from public sources, mainly
Yahoo Finance, so a blank symbol is weather, not a broken install.

It needs 2048 MB of RAM available and 10 GB free on /srv, on amd64 or arm64. Measure:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If RAM is under 2048 MB or free disk under 10 GB, print both numbers and stop. Do not install and
hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a hostname that
does not resolve.

## 2. Layout

Two owners: the PostgreSQL image chowns its own data directory on first start, so that one stays
with root.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ghostfolio /srv/ghostfolio/backups
sudo install -d -m 700 /srv/ghostfolio/postgres
ls -la /srv/ghostfolio
```

Assert: `backups` owned by the login user, `postgres` mode `drwx------` owned by root. The app
container needs no volume: every account, activity and cached price is a PostgreSQL row, and
Redis holds cache and queues that rebuild.

## 3. Secrets

Four secrets, all made on the server. `POSTGRES_PASSWORD` and `REDIS_PASSWORD` guard the data
services, `ACCESS_TOKEN_SALT` hashes the user's security token before storage, and
`JWT_SECRET_KEY` signs the session tokens. Do not print them, repeat them in your summary, or log
them. Hex rather than base64: the password goes into a connection URL.
`ROOT_URL` shares the file and is not a secret: the public hostname, `https://`, no trailing
slash, which Ghostfolio builds page-head links and its sitemap from.

```bash
umask 077
cat > /srv/ghostfolio/.env <<EOF
ROOT_URL=https://<DOMAIN>
POSTGRES_DB=ghostfolio
POSTGRES_USER=ghostfolio
POSTGRES_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
ACCESS_TOKEN_SALT=$(openssl rand -hex 32)
JWT_SECRET_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/ghostfolio/.env
umask 022
ls -l /srv/ghostfolio/.env
```

Assert: mode `-rw-------`, `ROOT_URL` reads `https://` plus the real hostname. Tell the user what
`ACCESS_TOKEN_SALT` costs: a database restored beside a different .env accepts nobody, and
changing it locks every token out, with no mail and no password to fall back on.

## 4. compose.yml

```bash
cat > /srv/ghostfolio/compose.yml <<'EOF'
# Ghostfolio · the deterministic fallback. Authored by caniselfhostit from
# upstream's own packaging at the pinned tag, read rather than copied:
#   compose file ... https://github.com/ghostfolio/ghostfolio/blob/3.50.0/docker/docker-compose.yml
#   variables ...... https://github.com/ghostfolio/ghostfolio/blob/3.50.0/README.md
#
# Ghostfolio, the PostgreSQL holding every account and cached price, and the
# Redis it caches and queues in. Upstream ships floating tags on 3333; this
# pins every image by digest and publishes 8196 on loopback, with 5432 and
# 6379 published nowhere. Digests read 2026-08-14, amd64+arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:15.19-alpine@sha256:5d23207f297fbb632e375dd80b4631282086d18f537d5e981dd0058501963a43
    container_name: ghostfolio-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ghostfolio
      POSTGRES_USER: ghostfolio
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/ghostfolio/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ghostfolio -d ghostfolio"]
      interval: 10s
      retries: 12

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: ghostfolio-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    # Upstream's own command and probe; $$ passes a literal $ to the shell.
    command:
      - /bin/sh
      - -c
      - redis-server --requirepass "$$REDIS_PASSWORD"
    healthcheck:
      test:
        - CMD-SHELL
        - redis-cli --pass "$$REDIS_PASSWORD" ping | grep -q PONG
      interval: 10s
      retries: 12

  ghostfolio:
    image: ghostfolio/ghostfolio:3.50.0@sha256:9b8cab0eddcaecdfe1611a218f09567d39a660677b612e12837d2084d97e21a4
    container_name: ghostfolio
    restart: unless-stopped
    init: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    env_file: /srv/ghostfolio/.env
    environment:
      DATABASE_URL: postgresql://ghostfolio:${POSTGRES_PASSWORD}@postgres:5432/ghostfolio?connect_timeout=300
      REDIS_HOST: redis
      REDIS_PORT: 6379
      # Express reads the client address from the header Caddy sets.
      TRUST_PROXY: "1"
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8196.
      - "127.0.0.1:8196:3333"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:3333/api/v1/health"]
      interval: 10s
      retries: 30
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/ghostfolio && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port. Compose reads
`${POSTGRES_PASSWORD}` from /srv/ghostfolio/.env when run from that directory.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-ghostfolio
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Ghostfolio · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/ghostfolio/ghostfolio/blob/3.50.0/README.md and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# the placeholder replaced by the hostname pointed at this box. That hostname
# is ROOT_URL in .env too, and the two have to agree.

<DOMAIN> {
	# The client is an Angular bundle of several hundred kilobytes.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Nothing here is meant to be embedded anywhere.
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8196 is the loopback port compose publishes. Not open in the firewall.
	reverse_proxy 127.0.0.1:8196
}
EOF
sudo grep -c 'reverse_proxy 127.0.0.1:8196' /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert three and print each: the grep prints `1`, `caddy validate` exits 0, the reload exits 0.
The site address opening the block has to be the hostname from step 3, not the placeholder. If
validate fails, restore the copy taken above, reload, and report what it objected to.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box nothing changes:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8196 is bound to 127.0.0.1 and neither 5432 nor 6379 is published, so none has a host
port to firewall. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, nothing for 8196, 5432, 6379 or 3333.

## 7. Start and verify

First boot applies 117 Prisma migrations and a seed before the server answers. Use the loop, not
a sleep.

```bash
cd /srv/ghostfolio
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/health; echo
curl -sS https://<DOMAIN>/en | grep -c '<title>Ghostfolio'
curl -sS https://<DOMAIN>/api/v1/info | grep -c createUserAccount
```

Assert all four and print what you received. The loop ends on `200`. Health prints
`{"status":"OK"}`, which upstream returns only when the database and the Redis cache both answer,
so one line covers all three containers. The third prints a number above `0`. The fourth prints
`1`, the problem this block exists to fix: account creation is open and the first account created
becomes the administrator, so right now that is whoever reaches the hostname first. If any of the
four misses, stop, run `docker compose logs --tail 40 ghostfolio` then the same for `postgres`,
and name the earlier step: a Redis or database that never reports healthy holds the app in
`depends_on`, a 502 with all three up is step 5. A running container is not success.

Close that door now. Create the first account yourself, which makes it the administrator, and
keep the credential out of the chat:

```bash
umask 077
curl -sS -X POST https://<DOMAIN>/api/v1/user -o /srv/ghostfolio/first-user.json
grep -o '"role":"[A-Z]*"' /srv/ghostfolio/first-user.json
grep -o '"accessToken":"[^"]*"' /srv/ghostfolio/first-user.json | cut -d'"' -f4 > /srv/ghostfolio/security-token.txt
chmod 600 /srv/ghostfolio/first-user.json /srv/ghostfolio/security-token.txt
wc -c /srv/ghostfolio/security-token.txt
```

Assert: `"role":"ADMIN"`, and `wc -c` prints `129`, a 128-character token plus its newline. A
`"role":"USER"` means somebody already claimed the administrator account here: stop and tell the
user, the instance is not theirs. Never print the token.

Now shut account creation off and prove it:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X PUT -H "Authorization: Bearer $(grep -o '"authToken":"[^"]*"' /srv/ghostfolio/first-user.json | cut -d'"' -f4)" -H 'Content-Type: application/json' -d '{"value":"false"}' https://<DOMAIN>/api/v1/admin/settings/IS_USER_SIGNUP_ENABLED
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/v1/user
rm /srv/ghostfolio/first-user.json
curl -sS https://<DOMAIN>/api/v1/info | grep -c createUserAccount
```

Assert: `200`, then `403`, then `0`. The `403` is upstream refusing to create an account at all
and the `0` is the same fact from the public info endpoint; both must pass before you report
success. The `rm` runs before the last call because that token is short-lived;
security-token.txt holds the lasting credential.

STOP: tell the user to read their token with `sudo cat /srv/ghostfolio/security-token.txt`, save
it in their password manager, then open https://<DOMAIN>, press `Sign in`, and paste it.
Do not continue until they confirm they see their own empty portfolio.
That token is the only way in: the account has no email address and no password.

## 8. First backup and restore

Two artifacts. The dump holds the accounts, activities and cached prices. The config archive
holds what rebuilds the service around it, security token included: losing that locks the user
out of an intact database.

```bash
cd /srv/ghostfolio
docker compose exec -T postgres pg_dump -U ghostfolio -d ghostfolio | gzip > /srv/ghostfolio/backups/ghostfolio-db-$(date +%F).sql.gz
sudo tar -czf /srv/ghostfolio/backups/ghostfolio-config-$(date +%F).tar.gz -C /srv/ghostfolio compose.yml .env security-token.txt -C /etc/caddy Caddyfile
ls -lh /srv/ghostfolio/backups/
```

Assert: both exist, non-empty, sizes printed. The dump is around 16 KB on a fresh install, and
nothing stops: `pg_dump` snapshots a running database consistently. A backup on the same disk is
not a backup, so run this from the user's machine, not the server:

```bash
mkdir -p ~/backups/ghostfolio
scp vps:/srv/ghostfolio/backups/* ~/backups/ghostfolio/
```

To restore: `docker compose down`, `sudo rm -rf /srv/ghostfolio/postgres`, recreate it as in
step 2, untar the config archive into /srv/ghostfolio so .env is back before anything starts,
`docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U ghostfolio -d ghostfolio`, then `docker compose up -d`.
The dump alone is not enough: the token is hashed with `ACCESS_TOKEN_SALT`, so a database beside
a fresh .env is a portfolio nobody opens.

## 9. Updating later

New versions are at https://github.com/ghostfolio/ghostfolio/releases, and the release tag is the
image tag. Upstream ships most weeks and often several times in one, so treat this pin as a
snapshot and read the changelog before crossing minor versions. PostgreSQL stays on the 15 line,
which is what upstream's compose file pins. Back up, then edit the image line:

```bash
cd /srv/ghostfolio
docker compose pull
docker compose up -d
docker compose logs --tail 30 ghostfolio
```

The entrypoint applies new migrations on the way up and the log ends with the version banner and
`Listening at http://0.0.0.0:3333`. Watch it settle, then re-run step 7's health check.

## 10. What will probably go wrong

The first boot looks like a hang. I watched `curl` return nothing for minutes while
`docker compose ps` showed the container up, and I was blaming Caddy before I read the log and
found it applying 117 Prisma migrations one line at a time. That is why step 7 loops forty times
rather than sleeping once. If it still prints `000` or `502` after ten minutes, read
`docker compose logs --tail 40 ghostfolio` first: a log printing `Applying migration` is working,
one stopped at `Can't reach database server` is step 4. The other thing that looks broken and is
not is blank prices: ask
https://<DOMAIN>/api/v1/health/data-provider/YAHOO, which answers `200` when Yahoo Finance is up
and `503` when it is rate-limiting.

## 11. Out of scope

- Do not set `ENABLE_FEATURE_AUTH_OIDC` or any `OIDC_` variable. Upstream marks that path
  experimental, it needs an identity provider the user does not have, and the token works.
- Do not add `API_KEY_` variables for paid market-data providers, and do not set
  `ENABLE_FEATURE_SUBSCRIPTION` or `STRIPE_SECRET_KEY`. The defaults need no account, and those
  switches exist for running Ghostfolio as a service for other people.
- Do not configure SMTP. Ghostfolio sends no mail, and there is no password reset to carry.
