This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Rallly 4.12.1 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Two things to settle before step 1. `<DOMAIN>` becomes `NEXT_PUBLIC_BASE_URL`, the address printed
inside every invitation this instance mails, so changing it later breaks links other people are
holding. And Rallly signs people in by mailing a six-digit code, with no other way in, so step 3
will ask you for the host, port, username and password of an SMTP relay. Upstream names Resend,
Postmark, Mailgun and Brevo, and says not to run your own mail server and not to use a Gmail or
Proton mailbox, because consumer inboxes rate-limit automated senders and eventually block the
sign-in mail. Sign up for one now if you have not.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of RAM is
the other common stop: Rallly is a Next.js server beside a PostgreSQL, and 2 GB is upstream's own
floor rather than a number we picked. Add swap or resize the box; do not install and hope.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/rallly /srv/rallly/backups
sudo install -d -m 700 /srv/rallly/postgres
ls -la /srv/rallly
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise.

## 3. Secrets

Two secrets, the PostgreSQL password and the session key, both generated here on the server and
both written straight into a file only you can read. Upstream documents `openssl rand -hex 32` for
`SECRET_PASSWORD` and rejects anything shorter than 32 characters.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on the
first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/rallly/.env` and carry on. If
the file already existed from an earlier attempt, this block has now overwritten both secrets,
which is fine before the database exists and a problem afterwards: PostgreSQL keeps the password
it was created with, so a changed one on an existing volume produces an authentication failure in
the Rallly log rather than anything that mentions passwords.

Do not paste that file, either secret, or any output containing them into this chat window. The
agent path never sees those values, and this one hands them to a third party unless you decline.

Now edit the file: `nano /srv/rallly/.env`, and replace every `CHANGE_ME`. `SUPPORT_EMAIL` is the
address shown to people as your contact, and it is validated as an email at start-up, so the
container refuses to boot while it still reads `CHANGE_ME`. `INITIAL_ADMIN_EMAIL` is the one
address allowed to claim the admin role in step 7; make it your own. The four `SMTP_` lines are
your relay. Correct `SMTP_PORT` if it is not 587, and set `SMTP_SECURE=true` if your relay uses
465. Save, then:

```bash
grep -c CHANGE_ME /srv/rallly/.env
```

You should see: `0`.

If you do not: the number printed is how many lines still hold a placeholder, and every one of
them stops step 7. It counts lines, never values, so it is safe to paste back here.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/rallly/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/rallly/compose.yml` and paste again in one go. Upstream's own stack runs two more
containers, a Traefik and a Garage object store, and this file runs neither. Caddy is already on
the box, and the S3 variables are optional in the app's environment schema, so the whole cost of
dropping Garage is that avatar and logo uploads are unavailable.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-rallly /etc/caddy/Caddyfile`, reload, and
paste again. The usual cause is a `<DOMAIN>` you forgot to replace, which Caddy reads as a
hostname made of angle brackets. Caddy asks for the certificate on the first request and renews it
itself, so there is nothing for you to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8153` or `5432`.

If you do not: delete anything for `8153` or `5432` with `sudo ufw delete allow 8153`. 8153 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has no
host port a firewall rule could apply to. 80/tcp answers the ACME challenge and redirects to
HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The container applies its own Prisma migrations before the server listens, so the first boot takes
a few minutes. The loop below waits it out.

```bash
cd /srv/rallly
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/status
curl -sS https://<DOMAIN>/login | grep -c '>Log in to your account or create a new one</p>'
```

You should see, in order: the loop reaching `200`, a small JSON object containing `"status":"ok"`
and `"database":"connected"`, then `1`.

If you do not: read `docker compose logs --tail 60 rallly` first. An
`Invalid environment variables` line means step 3 is incomplete, and the two candidates are a
`CHANGE_ME` still sitting in `SUPPORT_EMAIL` and a `SECRET_PASSWORD` shorter than 32 characters.
If the loop never leaves `502`, the container is still migrating, so give it another few minutes
before touching anything. If `docker compose logs --tail 20 postgres` shows a database that never
reports healthy, step 2 is the place to look. A container that is running is not the same thing as
an install that works.

The first screen at https://<DOMAIN>/login is headed `Welcome`, with
`Log in to your account or create a new one` under it and one box asking for an email address.

Open it now, type in the address you put in `INITIAL_ADMIN_EMAIL`, and wait for the six-digit code
Rallly mails to you. Enter the code, then open https://<DOMAIN>/control-panel and press the button
that makes you an admin. That code landing in your inbox is the only proof your relay works; if
nothing arrives within two minutes, read step 10 before you change anything.

Now close registration, because it is open by default and a public Rallly with registration open
is an account for anyone who can receive mail. Voting on a poll never needed an account.

```bash
sed -i 's/^REGISTRATION_ENABLED=true$/REGISTRATION_ENABLED=false/' /srv/rallly/.env
cd /srv/rallly
docker compose up -d --force-recreate rallly
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/login | grep -c '>Login to your account to continue</p>'
curl -sS https://<DOMAIN>/login | grep -c '>Log in to your account or create a new one</p>'
```

You should see: the loop reach `200` again, then `1`, then `0`.

If you do not: a second `1` where you expected `0` means the container came back with the old
value, so check that the `sed` line actually changed the file with
`grep REGISTRATION_ENABLED /srv/rallly/.env` and recreate again. That is a line you can paste back
here safely; the two lines above it are not.

## 8. First backup and restore

Two artifacts. The database holds every poll, vote, comment and account. The config archive holds
what rebuilds the service around it.

```bash
cd /srv/rallly
docker compose exec -T postgres pg_dump -U rallly -d rallly | gzip > /srv/rallly/backups/rallly-db-$(date +%F).sql.gz
sudo tar -czf /srv/rallly/backups/rallly-config-$(date +%F).tar.gz -C /srv/rallly compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/rallly/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline, because
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and the
shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/rallly
scp vps:/srv/rallly/backups/* ~/backups/rallly/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/rallly/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one account:

```bash
cd /srv/rallly
docker compose down
sudo rm -rf /srv/rallly/postgres
sudo install -d -m 700 /srv/rallly/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/rallly/backups/rallly-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U rallly -d rallly
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/api/status
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then a status object whose `database`
field reads `connected`. Sign in again with the same address to confirm your account survived.

If you do not: `role "rallly" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the archive is for
as well: `SECRET_PASSWORD` lives in .env, every signed-in session is sealed with it, and a
database restored beside a freshly generated key logs everybody out at once.

## 9. Updating later

New versions are listed at https://github.com/lukevella/rallly/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/rallly/compose.yml to the new tag and its
digest.

```bash
cd /srv/rallly
docker compose pull
docker compose up -d
docker compose logs --tail 40 rallly
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/api/status` check from step 7 before you call the update done. Stay inside the 4.x line: the
licence upstream sells is perpetual for 4.x, and a major bump is a separate decision.

## 10. What will probably go wrong

The sign-in code will not arrive, and nothing will look broken. I sat on the `Verify your email`
screen for ten minutes with a healthy container, a `200` from `/api/status` and an empty inbox,
and the Rallly log said nothing, because the app had handed the message to the relay and the relay
had refused it out of sight. Make that conversation visible: add `SMTP_DEBUG=true` to
/srv/rallly/.env, run `docker compose up -d --force-recreate rallly`, try the sign-in again, and
read `docker compose logs --tail 60 rallly`. Mine was rejecting the from-address because the
domain was not verified with the relay yet. Take `SMTP_DEBUG` out once mail lands: it prints the
whole SMTP exchange into the log.

## 11. Out of scope

- Do not configure single sign-on. OIDC, Google and Microsoft each need a client registered in
  somebody else's console, and this install signs people in by email.
- Do not add upstream's bundled Traefik or Garage containers. Caddy already terminates TLS here,
  and the object store buys avatar and logo uploads at the price of a third service to operate.
- Do not set `APP_NAME`, `LOGO_URL` or `HIDE_ATTRIBUTION`. Those need a purchased licence key, and
  this install runs the free one.
- Do not install a mail server on this box. Upstream tells you to use a transactional provider,
  and port 25 on a fresh VPS is a fight with no prize.
