This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Typebot 3.17.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise.

Two things to settle before step 1, because both stop this install dead.

Typebot is two applications and needs two hostnames. The builder, where you design bots and sign
in, answers on `<DOMAIN>`. The viewer, which is what a visitor loads when they open a published
bot, answers on `bot.<DOMAIN>`. Both are Next.js servers that own the root path, so they cannot
share one name. Point A records for both at this server before you start, and replace `<DOMAIN>`
with your hostname everywhere it appears below.

Typebot signs people in by mailing a six-digit code, and it registers no sign-in method at all
until a mail relay or an outside identity provider is configured. This install uses mail. Have a
host, port, username, password and a from-address from a transactional mail provider in front of
you before step 3.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
dig +short bot.<DOMAIN>
```

You should see: at least `2048` MB available, at least `15` G free, `amd64` or `arm64`, and your
server's IP twice on the last two lines. The disk floor is high because the two application images
are over a gigabyte each compressed.

If you do not: an empty line from either `dig` means that A record does not exist yet. Add it,
wait a minute, run the command again. Caddy cannot get a certificate for a name that does not
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for both names
while you install.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/typebot /srv/typebot/backups
sudo install -d -m 700 /srv/typebot/postgres
ls -la /srv/typebot
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. Nothing else of Typebot's lives on disk: bots, results and credentials are rows in
that database.

## 3. Secrets

Two secrets are generated here, on the server, and both go straight into a file only you can read.
Upstream documents `openssl rand -base64 24` for `ENCRYPTION_SECRET`, and its schema rejects
anything that is not exactly 32 characters, which is what 24 random bytes of base64 come to. The
database password is hex so it needs no escaping inside a connection string.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first two lines with your real hostname before you paste.

Do not paste that file, either generated secret, or any command output containing them into this
chat window. The agent path never sees those values; a chat window will hand them to a third party
unless you keep them out of it.

Now open `nano /srv/typebot/.env` and replace every `CHANGE_ME`. `ADMIN_EMAIL` is your own address,
and it is the only address in the world that can create an account on this instance.
`NEXT_PUBLIC_SMTP_FROM` is the from-address your relay is allowed to send as. Correct `SMTP_PORT`
if your relay is not 587, and set `SMTP_SECURE=true` if it is 465. Then:

```bash
grep -c CHANGE_ME /srv/typebot/.env
```

You should see: `0`. That counts lines, never values.

If you do not: three of those settings are load-bearing and worth understanding before you move
on. `DISABLE_SIGNUP` is true from the first boot, and upstream's sign-in callback lets exactly one
address past it, whatever is in `ADMIN_EMAIL`, so there is no open-registration window on this
install and nothing to close later. `DEFAULT_WORKSPACE_PLAN=UNLIMITED` overrides a `FREE` default
that upstream's own constants cap at 200 chats a month and one seat. `NEXT_PUBLIC_SMTP_FROM` is
what registers the email sign-in provider at all: leave it empty and the builder serves a sign-in
page with no way to sign in. A mode of `-rw-r--r--` instead means `umask 077` did not take effect,
which happens if you pasted the lines separately in different shells; run
`chmod 600 /srv/typebot/.env` and carry on.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/typebot/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal;
run `rm /srv/typebot/compose.yml` and paste again in one go. No password sits in that file:
compose reads `${POSTGRES_PASSWORD}` out of /srv/typebot/.env to build both connection strings.

## 5. Caddy and TLS

This appends two site blocks to the Caddy config Prompt Zero installed, one per application.
Replace `<DOMAIN>` in the block with your hostname everywhere it appears before you paste. The
first line takes a copy, because a syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-typebot /etc/caddy/Caddyfile`, reload, and
paste again. The most common cause is a `<DOMAIN>` you replaced in one of the three places and not
the others. Caddy asks for both certificates on the first request to each name and renews them
itself, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8177`, `8977` or `5432`.

If you do not: delete anything for those three with `sudo ufw delete allow 8177`. Both application
ports are bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the
database has no host port a rule could apply to. 80/tcp is there to redirect to HTTPS and answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first pull is over two gigabytes, and the builder applies its own Prisma migrations before it
listens, so the first boot takes minutes rather than seconds.

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

You should see, in order: the loop reaching `200`, a JSON object containing `"nodemailer"`, then
`{"status":"ok"}` from the viewer, then `401`, then `1`.

If you do not: the `401` is the one worth understanding. It means the viewer's API is up and
refusing a call with no bearer token, which is upstream's documented answer, so seeing it is good
news. A `404` in its place means Caddy is not reaching the viewer container: check
`docker compose ps`. If the providers response is `{}`, the email provider did not register, which
means `NEXT_PUBLIC_SMTP_FROM` is still empty in .env. If the loop never reaches `200`, run
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy is
step 2 done wrong, and `docker compose logs --tail 60 builder` second: an `Invalid environment
variables` line there points at step 3, where an `ENCRYPTION_SECRET` that is not exactly 32
characters stops the process before it listens, and a `502` while the loop is still running only
means migrations are still going.

The first screen at https://<DOMAIN>/signin is headed `Sign In`, with `Don't have an account?`
under it and one box asking for an email address next to a `Submit` button.

Now open https://<DOMAIN>/signin in a browser, enter the address you put in `ADMIN_EMAIL`, and
type in the six-digit code Typebot mails to it. You should land on an empty bot list. That code
arriving is the only proof your relay works; if nothing lands within two minutes, read step 10
before touching anything. Any other address is refused with `Unauthorized`, which is what
`DISABLE_SIGNUP` does, and it is the security assert on this install: registration left open on a
public hostname is an account for anyone who can receive mail.

## 8. First backup and restore

Two artifacts. The database holds every bot, result, workspace and stored credential. The config
archive holds what rebuilds the service around it.

```bash
cd /srv/typebot
docker compose exec -T postgres pg_dump -U typebot -d typebot | gzip > /srv/typebot/backups/typebot-db-$(date +%F).sql.gz
sudo tar -czf /srv/typebot/backups/typebot-config-$(date +%F).tar.gz -C /srv/typebot compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/typebot/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/typebot
scp vps:/srv/typebot/backups/* ~/backups/typebot/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/typebot/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty account:

```bash
cd /srv/typebot
docker compose down
sudo rm -rf /srv/typebot/postgres
sudo install -d -m 700 /srv/typebot/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/typebot/backups/typebot-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U typebot -d typebot
docker compose up -d
sleep 60
curl -sS https://bot.<DOMAIN>/api/healthz
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `{"status":"ok"}` again.

If you do not: `role "typebot" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand why the config archive
matters as much as the dump: `ENCRYPTION_SECRET` lives in .env, and it is what decrypts the
provider keys and integration credentials stored in the database, so a dump restored beside a
freshly generated secret comes back with credentials nobody can read.

## 9. Updating later

New versions are listed at https://github.com/baptisteArno/typebot.io/releases. Take both backup
artifacts first, then edit both `image:` lines in /srv/typebot/compose.yml to the new tag and its
digest, keeping the builder and the viewer on the same version.

```bash
cd /srv/typebot
docker compose pull
docker compose up -d
docker compose logs --tail 40 builder
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tags and digests back and run the same three commands. Then re-run the
five checks from step 7 before you call the update done. Leave the postgres tag alone unless a
release note says otherwise; a major PostgreSQL bump wants its own upgrade path.

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
