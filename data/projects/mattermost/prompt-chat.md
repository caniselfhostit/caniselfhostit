This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Mattermost 11.9.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `MM_SERVICESETTINGS_SITEURL`, and Mattermost builds
every invite link, permalink and websocket address from it. Changing it later means editing the
config, restarting, and reissuing invitations, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64`, and your server's
IP on the last line.

If you do not: `arm64` on the third line is the end of this install, not a hurdle. Upstream
supports 64-bit x86 processors and publishes the Mattermost image for amd64 only, so there is
nothing to pull on an ARM box. An empty last line means the A record does not exist yet: add it,
wait a minute, run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a
hostname that does not resolve and failed attempts count against a rate limit you cannot see.

## 2. Layout

The server image is distroless and runs as uid 2000, and it writes to four directories.
PostgreSQL chowns its own cluster on first start, so that one stays root-owned.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mattermost /srv/mattermost/backups
sudo install -d -m 750 -o 2000 -g 2000 /srv/mattermost/config /srv/mattermost/data /srv/mattermost/plugins /srv/mattermost/client-plugins
sudo install -d -m 700 /srv/mattermost/postgres
ls -la /srv/mattermost
```

You should see: `backups` owned by you, four directories owned by `2000`, and `postgres` at
mode `drwx------` owned by root.

If you do not: do not chown any of them to yourself to make an error go away. A `config`
directory the container cannot write is the single most common way this install fails, and it
fails with a log line about loading configuration that never mentions ownership. Leave
`postgres` owned by root: the PostgreSQL image chowns its own data directory the first time it
starts, and one you have already chowned makes it refuse to initialise.

## 3. Secrets

One secret: the PostgreSQL password. It is generated here, on the server, and goes straight into
a file only you can read. Hex rather than base64, because it is pasted into a connection string
where `+` and `/` would need escaping.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

Do not paste that file, the password, or any command output containing it into this chat window.
The other tab never sees those values; this one hands them to a third party unless you stop it.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/mattermost/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten the
password, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed `DB_PASSWORD` on an existing volume shows up as an
authentication failure in the Mattermost log rather than as anything about passwords.

Mattermost generates its own at-rest encryption key and public-link salt into
`config/config.json` the first time it starts, so this is the only secret you create by hand.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/mattermost/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/mattermost/compose.yml` and paste again in one go. A warning that the variable
`DB_PASSWORD` is not set means you are running the command from somewhere other than
/srv/mattermost, which is where compose looks for the `.env` it reads.

Every setting given as an `MM_` environment variable overrides `config.json` and shows greyed out
in the System Console. That is deliberate: the four hardening choices in this file cannot be
undone from a browser session, only by editing this file.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-mattermost /etc/caddy/Caddyfile`, reload,
and paste again. There is nothing to add for the websocket the webapp keeps open at
`/api/v4/websocket`: Caddy's `reverse_proxy` performs that upgrade on its own, which is why this
block is short where the upstream nginx example is ninety lines.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8113` or `5432`.

If you do not: delete anything for `8113` or `5432` with `sudo ufw delete allow 8113`. 8113 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has no
host port a firewall rule could apply to. 80/tcp redirects to HTTPS and answers the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

Mattermost runs its own database migrations on the way up. The first start is much slower than
the second, so the loop below is doing real work rather than being cautious.

Have your browser open before you paste this. The moment Caddy issues a certificate, that
hostname is in the public certificate transparency logs, and until you create the first account
anybody who loads the page can create it and become the system administrator.

```bash
cd /srv/mattermost
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v4/system/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v4/system/ping
curl -sS https://<DOMAIN>/api/v4/config/client | tr ',' '\n' | grep NoAccounts
```

You should see, in order: the loop climbing and ending on `200`, a JSON object containing
`"status":"OK"`, and then `"NoAccounts":"true"`.

If you do not: run `docker compose logs --tail 20 postgres` first, because a database that never
reports healthy stops everything behind it, then `docker compose logs --tail 40 mattermost`. A
Mattermost log that cannot load its configuration is step 2 done wrong, and the fix is
`sudo chown -R 2000:2000 /srv/mattermost/config` followed by `docker compose up -d`. A `502` that
never becomes `200` after five minutes is usually DNS: run `dig +short <DOMAIN>` and check the
certificate actually issued with `sudo journalctl -u caddy --since -10m`. A green
`docker compose ps` is not success on its own.

Now open https://<DOMAIN> in your browser. The first screen is the account form, headed
`Create your account`. Create your account, and put that password in your password manager: there
is no mail in this install, so a forgotten administrator password has no reset link and the only
way back in is the command line.

Then prove the window is shut:

```bash
curl -sS https://<DOMAIN>/api/v4/config/client | tr ',' '\n' | grep NoAccounts
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"email":"signup-check@example.invalid","username":"signupcheck"}' https://<DOMAIN>/api/v4/users
```

You should see: `"NoAccounts":"false"`, then `403`.

If you do not: a `201` in place of the `403` means that command created an account, which means
`MM_TEAMSETTINGS_ENABLEOPENSERVER` is not being read. Check that the line is in
/srv/mattermost/compose.yml, run `docker compose up -d --force-recreate`, delete the account it
created from the System Console, and run the check again. This is the assert with real security
meaning in the whole install; do not wave it through.

## 8. First backup and restore

Two artifacts. The database holds every message, channel and account. The file archive holds the
uploads, the config Mattermost generated, and the pieces that rebuild the service around them.

```bash
cd /srv/mattermost
docker compose exec -T postgres pg_dump -U mmuser -d mattermost | gzip > /srv/mattermost/backups/mattermost-db-$(date +%F).sql.gz
sudo tar -czf /srv/mattermost/backups/mattermost-files-$(date +%F).tar.gz -C /srv/mattermost compose.yml .env config data -C /etc/caddy Caddyfile
ls -lh /srv/mattermost/backups/
```

You should see: two files, both a few hundred kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/mattermost
scp vps:/srv/mattermost/backups/* ~/backups/mattermost/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/mattermost/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/mattermost
docker compose down
sudo rm -rf /srv/mattermost/postgres
sudo install -d -m 700 /srv/mattermost/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/mattermost/backups/mattermost-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U mmuser -d mattermost
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/api/v4/config/client | tr ',' '\n' | grep NoAccounts
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `"NoAccounts":"false"`, which
means your account survived a database that was deleted and rebuilt. Log in to confirm.

If you do not: `role "mmuser" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the two artifacts
are for before you skip this: the database without the `data` directory gives you every message
with every attachment broken, and the `config` directory carries the at-rest encryption key the
server generated on its first start.

## 9. Updating later

New versions are listed at https://github.com/mattermost/mattermost/releases. Mattermost also
publishes an extended-support line that takes patches for longer; the tag here is the current
feature release, not that one. Take both backup artifacts first, then edit the `image:` line in
/srv/mattermost/compose.yml to the new tag and its digest.

```bash
cd /srv/mattermost
docker compose pull
docker compose up -d
docker compose logs --tail 30 mattermost
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Move one major
version at a time, because upstream does not support skipping them, and re-run the ping check
from step 7 before you call the update done.

## 10. What will probably go wrong

The gap between the container starting and you creating your account is a real hole, and I walked
away during it. Caddy publishes the hostname to the certificate transparency logs the moment it
issues, those logs are scraped within seconds, and while `NoAccounts` reads `true` the first
stranger to load that page becomes the system administrator of your server. Nothing happened to
me, but nothing had to. Do not paste step 7 until you are ready to open the browser immediately
afterwards.

## 11. Out of scope

- Do not configure SMTP. Mattermost runs without it and invitations work as copyable links from
  the Invite People dialog. Password reset stays broken until mail exists, and that is the trade
  this install makes.
- Do not enable AD/LDAP, SAML or OpenID sign-on. Those are licensed features of the paid
  editions, and turning them on here produces an error rather than a login page.
- Do not install the Calls, Playbooks or any other plugin. Each is a separate decision with its
  own ports and storage; this install gives you the chat server.
- Do not switch the image to mattermost-enterprise-edition. That is a different licence and this
  install chose Team Edition on purpose.
