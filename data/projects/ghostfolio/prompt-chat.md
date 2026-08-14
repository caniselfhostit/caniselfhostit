This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Ghostfolio 3.50.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. Ghostfolio tracks investments: holdings, allocation, performance,
dividends and net worth. It has no spending feed, no categories and no budgets, so the half of
a money app that watches where your money goes is not in here. It connects to no bank either:
activities are typed in or imported from a CSV you export yourself. And prices come from public
market-data sources, mainly Yahoo Finance, over an interface nobody promises you, so a symbol
that goes blank for a day is weather rather than a broken install.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. If RAM is short, this is
not a service to squeeze onto a 1 GB box: the application alone idles near 500 MB and the
portfolio calculations spike above that.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ghostfolio /srv/ghostfolio/backups
sudo install -d -m 700 /srv/ghostfolio/postgres
ls -la /srv/ghostfolio
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. There is no directory for Ghostfolio itself, and that is correct: every
account, activity and cached price is a row in PostgreSQL, and Redis holds cache and job queues
that rebuild themselves.

## 3. Secrets

Four secrets, all generated here on the server. `POSTGRES_PASSWORD` and `REDIS_PASSWORD` guard
the two data services. `ACCESS_TOKEN_SALT` is what Ghostfolio hashes your security token with
before storing it. `JWT_SECRET_KEY` signs the session tokens your browser carries. Hex rather
than base64, because the database password goes into a connection URL where `+` and `/` would
have to be percent-encoded.

Replace `<DOMAIN>` on the first line with your real hostname before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/ghostfolio/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all four
secrets, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed `POSTGRES_PASSWORD` on an existing data directory
produces an authentication failure in the Ghostfolio log rather than anything about passwords.

Do not paste that file, any of those four values, or any command output containing them into this
chat window. `ACCESS_TOKEN_SALT` deserves one more sentence: it hashes the security token step 7
gives you, so a database restored beside a different .env accepts nobody, and changing it locks
every token out at once. There is no mail here and no account password, so there is nothing to
fall back on.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/ghostfolio/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/ghostfolio/compose.yml` and paste again in one go. `DATABASE_URL` is built inside
this file rather than in .env so the password lives in one place, and compose reads
`${POSTGRES_PASSWORD}` out of /srv/ghostfolio/.env when you run it from that directory, which is
why every command below starts with `cd /srv/ghostfolio`.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `1` from the grep, `Valid configuration` from validate, and no output at all from
reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-ghostfolio /etc/caddy/Caddyfile`, reload,
and paste again. Check the site address on the line that opens the block: if it still reads the
literal placeholder, you pasted before replacing it, and Ghostfolio will hand out `ROOT_URL`
links pointing at a hostname Caddy does not serve.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8196`, `5432`, `6379` or `3333`.

If you do not: delete anything for those four with `sudo ufw delete allow 8196`. 8196 is bound to
127.0.0.1 by the compose file and neither 5432 nor 6379 is published at all, so none of them has
a host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and answer the
ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The first boot applies 117 database migrations and a seed before the server answers anything, so
this takes minutes rather than seconds. The loop is the point; do not replace it with a sleep.

```bash
cd /srv/ghostfolio
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/health; echo
curl -sS https://<DOMAIN>/en | grep -c '<title>Ghostfolio'
curl -sS https://<DOMAIN>/api/v1/info | grep -c createUserAccount
```

You should see, in order: the loop climbing and ending on `200`, then `{"status":"OK"}`, then a
number above `0`, then `1`.

If you do not: that health response is worth understanding, because upstream returns `OK` only
when the database and the Redis cache both answer, so one line covers all three containers. If
the loop never reaches `200`, run `docker compose logs --tail 40 ghostfolio` and read what it is
doing: a log still printing `Applying migration` is working and wants more time, and one that
stopped at `Can't reach database server` is step 3, where a changed `POSTGRES_PASSWORD` on an
existing data directory never matches. A `502` from Caddy with all three containers up is step 5.
A running container is not success.

That final `1` is the reason this step is not over. Account creation is open right now, and the
first account created on this hostname becomes the administrator, so anybody who reaches your
domain before you do owns your instance. Close it in the next two blocks.

```bash
umask 077
curl -sS -X POST https://<DOMAIN>/api/v1/user -o /srv/ghostfolio/first-user.json
grep -o '"role":"[A-Z]*"' /srv/ghostfolio/first-user.json
grep -o '"accessToken":"[^"]*"' /srv/ghostfolio/first-user.json | cut -d'"' -f4 > /srv/ghostfolio/security-token.txt
chmod 600 /srv/ghostfolio/first-user.json /srv/ghostfolio/security-token.txt
wc -c /srv/ghostfolio/security-token.txt
```

You should see: `"role":"ADMIN"`, then `129` bytes, which is a 128-character token plus its
newline.

If you do not: `"role":"USER"` means somebody already created the administrator account on this
hostname. Stop there. The instance is not yours, and the honest fix is to tear the database down
(`docker compose down`, `sudo rm -rf /srv/ghostfolio/postgres`, recreate it as in step 2) and
start step 7 again with the hostname already resolving. Do not paste the contents of either file
into this chat window.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X PUT -H "Authorization: Bearer $(grep -o '"authToken":"[^"]*"' /srv/ghostfolio/first-user.json | cut -d'"' -f4)" -H 'Content-Type: application/json' -d '{"value":"false"}' https://<DOMAIN>/api/v1/admin/settings/IS_USER_SIGNUP_ENABLED
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/v1/user
rm /srv/ghostfolio/first-user.json
curl -sS https://<DOMAIN>/api/v1/info | grep -c createUserAccount
```

You should see: `200`, then `403`, then `0`.

If you do not: a `401` on the first line means the session token in first-user.json was not read
correctly, so run the first command again exactly as written. A `201` on the second line means
account creation is still open and the setting did not take, and you should not go any further
until it prints `403`. The `403` is upstream refusing to create an account at all, the `0` is the
same fact from the public info endpoint, and both together are the proof that your instance is
now yours alone. The `rm` drops the short-lived session token, which is why it runs before the
last call; the lasting credential is in security-token.txt.

Read your security token once, put it in your password manager, then sign in:

```bash
sudo cat /srv/ghostfolio/security-token.txt
```

You should see: one long line of hex. Open https://<DOMAIN>, press `Sign in` in the header, paste
that token, and you are looking at your own empty portfolio.

If you do not: there is no password reset and no email address on this account, so that token is
the only way in. Do not paste it into this chat window. If you have lost it before signing in
once, the fastest recovery is to delete the database as described above and repeat step 7.

## 8. First backup and restore

Two artifacts. The dump holds the accounts, activities and cached prices. The config archive
holds what rebuilds the service around it, including the security token, because losing that
locks you out of a database that is otherwise intact.

```bash
cd /srv/ghostfolio
docker compose exec -T postgres pg_dump -U ghostfolio -d ghostfolio | gzip > /srv/ghostfolio/backups/ghostfolio-db-$(date +%F).sql.gz
sudo tar -czf /srv/ghostfolio/backups/ghostfolio-config-$(date +%F).tar.gz -C /srv/ghostfolio compose.yml .env security-token.txt -C /etc/caddy Caddyfile
ls -lh /srv/ghostfolio/backups/
```

You should see: two files, the dump around 16 KB on a fresh install and the config archive a
couple of kilobytes. Nothing goes offline: `pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/ghostfolio
scp vps:/srv/ghostfolio/backups/* ~/backups/ghostfolio/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/ghostfolio/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty portfolio:

```bash
cd /srv/ghostfolio
docker compose down
sudo rm -rf /srv/ghostfolio/postgres
sudo install -d -m 700 /srv/ghostfolio/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/ghostfolio/backups/ghostfolio-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U ghostfolio -d ghostfolio
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/v1/user
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `403` from the last command,
which means the closed-signup setting came back with the database rather than resetting to open.

If you do not: `role "ghostfolio" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand the stakes before you
skip this: the dump alone is not enough. Your token is stored hashed with `ACCESS_TOKEN_SALT`
from .env, so a database restored beside a freshly generated .env is a portfolio nobody can open.
The two files travel together or neither is worth anything.

## 9. Updating later

New versions are listed at https://github.com/ghostfolio/ghostfolio/releases, and the release tag
is the image tag, so release `3.51.0` is image tag `3.51.0`. Upstream ships most weeks and often
several times in one week, so treat this pin as a snapshot rather than a resting place, and read
the changelog before crossing several minor versions at once. PostgreSQL stays on the 15 line
because that is what upstream's own compose file pins; moving it is a database upgrade, not an
image bump. Take both backup artifacts first, then edit the `image:` line in
/srv/ghostfolio/compose.yml to the new tag and its digest.

```bash
cd /srv/ghostfolio
docker compose pull
docker compose up -d
docker compose logs --tail 30 ghostfolio
```

You should see: migration output, then the version banner, then `Listening at
http://0.0.0.0:3333`, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, because a container that starts can
still be failing if a migration stopped halfway.

## 10. What will probably go wrong

The first boot looks like a hang. I watched `curl` return nothing for minutes while
`docker compose ps` showed the container up, and I was blaming Caddy before I read the log and
found it applying 117 Prisma migrations one line at a time. That is why step 7 loops forty times
rather than sleeping once. The other thing that looks broken and is not is blank prices: ask
https://<DOMAIN>/api/v1/health/data-provider/YAHOO, which answers `200` when Yahoo Finance is up
and `503` when it is rate-limiting. Nothing in this install can fix that second one. It is the
cost of getting market data from a source that never promised you any.

## 11. Out of scope

- Do not set `ENABLE_FEATURE_AUTH_OIDC` or any `OIDC_` variable. Upstream marks that path
  experimental, it needs an identity provider you do not have, and the token already works.
- Do not add `API_KEY_` variables for paid market-data providers, and do not set
  `ENABLE_FEATURE_SUBSCRIPTION` or `STRIPE_SECRET_KEY`. The defaults need no account, and those
  switches exist for running Ghostfolio as a service for other people.
- Do not configure SMTP. Ghostfolio sends no mail here, and there is no password reset to carry.
- Do not publish 3333, 5432 or 6379 on the host. Caddy is the only way in.
