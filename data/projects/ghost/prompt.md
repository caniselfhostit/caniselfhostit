You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Ghost 6.56.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname becomes
Ghost's `url`, and every canonical link, RSS item and newsletter footer is built from it, so
moving the publication later means editing two files and reissuing a certificate.

Ghost plus MySQL 8 needs 2048 MB of RAM available and 10 GB free on /srv. Upstream's own
prerequisites ask for at least 1 GB, their floor for one machine running everything; two
containers, one of them MySQL 8, is where the OOM killer starts arriving mid-upload, so this
prompt asks for double. Both images publish amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ghost /srv/ghost/backups
sudo install -d -m 750 /srv/ghost/content
sudo install -d -m 700 /srv/ghost/mysql
ls -la /srv/ghost
```

Assert: `ls -la` shows `backups` owned by the login user, and `content` and `mysql` owned by
root. Leave both alone. The Ghost image's entrypoint starts as root, chowns its content
directory to the `node` user it runs as, then drops privileges; the MySQL image does the same
for its data directory. One you have already chowned to yourself makes MySQL refuse to
initialise.

## 3. Secrets

Two secrets: the MySQL root password and the password for the `ghost` database user. Generate
both on the server. Do not print either, do not repeat them in your summary, and do not put them
in any log line. Hex rather than base64, because both travel inside connection strings and one
is read back by a shell in the backup step.

```bash
umask 077
cat > /srv/ghost/.env <<EOF
GHOST_URL=https://<DOMAIN>
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
GHOST_DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/ghost/.env
umask 022
ls -l /srv/ghost/.env
```

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the
real hostname before writing it. Compose reads this file on its own for both services, but only
when it is run from /srv/ghost, so every docker command below is preceded by a `cd`. Tell the
user they can read either value with `sudo grep MYSQL_ROOT_PASSWORD /srv/ghost/.env`, and that
neither is a login they will type into a browser: the account they write with comes in step 7.

## 4. compose.yml

```bash
cat > /srv/ghost/compose.yml <<'EOF'
# Ghost · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.ghost.org/install/docker/
#   image reference .... https://hub.docker.com/_/ghost
#   config reference ... https://docs.ghost.org/config/
#   supported databases  https://docs.ghost.org/faq/supported-databases/
#   mysql image ........ https://hub.docker.com/_/mysql
#
# Two services: Ghost and the MySQL 8 it keeps posts, members and settings in.
# Upstream states MySQL 8 is the only database it supports in production, so the
# SQLite the image can run under NODE_ENV=development is not an option. Ghost
# speaks plain http on 2368 and the host's Caddy terminates TLS in front of it,
# which is why `url` carries the https address: every canonical link, RSS item
# and email footer is built from that one value. Both services read secrets from
# /srv/ghost/.env, which Compose picks up when run from /srv/ghost and nowhere
# else. MySQL 8.4 is the current long-term release and the line Ghost's own
# development compose file runs against. Tags and digests read from the
# registries on 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mysql:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: ghost-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ${GHOST_DB_PASSWORD}
    volumes:
      - /srv/ghost/mysql:/var/lib/mysql
    healthcheck:
      # `$$` sends a literal dollar to the container instead of interpolating.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u root -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      retries: 30
      start_period: 60s
    # No `ports:`: 3306 is reachable only from the other container.

  ghost:
    image: ghost:6.56.0-alpine@sha256:57cd95050d3ca05a098c9ae1275c8d62ace1c844aa653494204d1c0e77c0900a
    container_name: ghost
    restart: unless-stopped
    environment:
      NODE_ENV: production
      url: ${GHOST_URL}
      # Two underscores separate nested config levels. Documented mapping.
      database__client: mysql
      database__connection__host: mysql
      database__connection__user: ghost
      database__connection__password: ${GHOST_DB_PASSWORD}
      database__connection__database: ghost
    volumes:
      # Posts live in MySQL. Images, themes and uploads live here.
      - /srv/ghost/content:/var/lib/ghost/content
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8100.
      - "127.0.0.1:8100:2368"
    depends_on:
      mysql:
        condition: service_healthy
EOF
cd /srv/ghost && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. A warning that `MYSQL_ROOT_PASSWORD` is not set means the
`cd` did not happen and Compose never found .env; run it again from /srv/ghost.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-ghost
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Ghost · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.ghost.org/config/,
# https://hub.docker.com/_/ghost,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also the `url` value in .env, and Ghost builds every canonical link, RSS item
# and newsletter footer from it, so the two must always say the same thing.

<DOMAIN> {
	# Ghost serves HTML, JSON feeds and theme assets, all of which compress well.
	encode zstd gzip

	# Upstream asks the proxy in front of Ghost for X-Forwarded-For,
	# X-Forwarded-Host and X-Forwarded-Proto. Caddy's reverse_proxy sets all
	# three itself and ignores whatever the client sent, so there is nothing to
	# add here and nothing a visitor can spoof.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# No frame-blocking header: the Ghost editor previews posts and the members
	# portal renders its signup form in same-origin iframes, and a blanket DENY
	# breaks both.

	# 8100 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8100
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-ghost, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it on its own, so there is nothing
to schedule, and it puts no ceiling on request body size, so theme and image uploads need no
setting here.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3. 8100 stays closed because it is bound to 127.0.0.1, and 3306 stays closed because
compose never publishes it: the database has no host port to firewall. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for
8100 or 3306.

## 7. Start and verify

Ghost runs its own migrations on first boot against an empty MySQL, and that takes longer than
the container takes to appear in `docker ps`.

```bash
cd /srv/ghost
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/ghost/api/admin/authentication/setup); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/ghost/api/admin/authentication/setup
```

Assert both, and print what you received. The loop ends printing `200`. The second command
prints exactly `{"setup":[{"status":false}]}`, upstream's way of saying the site exists and has
no owner yet. If either misses, stop, run `docker compose logs --tail 40 ghost` and
`docker compose logs --tail 20 mysql`, and name the likely cause: a MySQL container that never
reports healthy points at step 2, a `502` that never clears points at step 4, a certificate
error points at the A record from step 1. A running container is not success.

That `status` of `false` is a standing open door: until the first account exists, whoever loads
the setup page owns the publication. Do this now, not tomorrow.

STOP: tell the user to open https://<DOMAIN>/ghost/ and create their account, and wait. Do not
continue until they confirm. The first screen carries the heading `Welcome to Ghost.` above a
form asking for a site title, full name, email address and a password of at least 10 characters.
Tell them the email address is only a login here, because no mail is configured, and the
password goes in their password manager before they submit.

Once they confirm, prove the door is shut:

```bash
curl -sS https://<DOMAIN>/ghost/api/admin/authentication/setup
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert: the first prints exactly `{"setup":[{"status":true}]}` and the second prints `200`. Both
must pass before you report success.

## 8. First backup and restore

Two artifacts. MySQL holds the posts, pages, tags, members and settings. The content archive
holds the images, the themes and the files that rebuild the service around them.

```bash
cd /srv/ghost
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers ghost' | gzip > /srv/ghost/backups/ghost-db-$(date +%F).sql.gz
sudo tar -C /srv/ghost -czf /srv/ghost/backups/ghost-content-$(date +%F).tar.gz content compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/ghost/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. The password expands in a
shell inside the container, so it never reaches this machine's history; mysqldump still prints
one warning line about passwords on the command line, and that line is expected. Nothing goes
offline: `--single-transaction` snapshots a running InnoDB database consistently.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/ghost
scp vps:/srv/ghost/backups/* ~/backups/ghost/
```

To restore: `cd /srv/ghost`, `docker compose down`, `sudo rm -rf /srv/ghost/mysql`, recreate it
as in step 2, untar the content archive back into /srv/ghost, `docker compose up -d mysql`, wait
for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" ghost'`, then
`docker compose up -d`. The order matters: the archive carries .env, and MySQL takes its
passwords from that file the moment it initialises an empty data directory.

## 9. Updating later

New versions are listed at https://github.com/TryGhost/Ghost/releases and the matching digest
is on https://hub.docker.com/_/ghost. Take both backups first, then edit the image line in
/srv/ghost/compose.yml to the new tag and its digest:

```bash
cd /srv/ghost
docker compose pull
docker compose up -d
docker compose logs --tail 30 ghost
```

Ghost migrates its own database on the way up, so watch that log until it settles, then re-run
the setup check from step 7 before calling the update done. Reach the last release of a major
version before crossing to the next: upstream states that skipping ahead is where database
errors come from.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a failed install for about a minute. I watched
`docker ps` show both containers up while https://<DOMAIN> returned `502 Bad Gateway`, and had
the Caddy config open hunting for a typo before it cleared on its own. Nothing was wrong: MySQL
spends its first 30 to 60 seconds initialising an empty data directory and refuses connections
until it has finished, and Ghost then runs its whole migration set before it binds 2368. That is
what the 40-iteration loop in step 7 is for. Do not restart anything, do not edit the Caddyfile,
and do not conclude the digest is wrong. Watch `docker compose logs -f ghost` and let it finish.

## 11. Out of scope

- Do not configure SMTP. Ghost publishes and serves the site without it, and mail is a provider
  choice with its own DNS records, made after the user has written something.
- Do not enable the analytics or ActivityPub profiles from Ghost's own compose repository. Each
  adds containers and an outside account, and this prompt installs the publication.
- Do not switch the database to SQLite. Upstream supports it in development mode only, and the
  image rejects it under NODE_ENV=production.
- Do not run Ghost-CLI commands inside the container. The official image documents that most of
  them are not designed to work there, and `ghost update` fights the digest pin.
