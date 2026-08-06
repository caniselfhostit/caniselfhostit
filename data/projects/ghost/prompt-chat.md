This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Ghost 6.56.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` becomes Ghost's `url`, and Ghost builds every canonical
link, RSS item and newsletter footer from that one value. Moving the publication later means
editing two files and reissuing a certificate, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that
does not resolve, and failed attempts count against a rate limit you cannot see. On memory,
Ghost's own prerequisites ask for 1 GB, which is their figure for one machine running
everything; two containers with MySQL 8 among them is where the OOM killer arrives during an
upload, so 2 GB is the floor here. A 1 GB box will appear to work and then fail on the day you
upload a batch of images or install a theme.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ghost /srv/ghost/backups
sudo install -d -m 750 /srv/ghost/content
sudo install -d -m 700 /srv/ghost/mysql
ls -la /srv/ghost
```

You should see: `backups` owned by you, `content` at mode `drwxr-x---` owned by root, and
`mysql` at mode `drwx------` owned by root.

If you do not: leave `content` and `mysql` owned by root on purpose. The Ghost image's
entrypoint starts as root, chowns its content directory to the `node` user it runs as, and
then drops privileges; the MySQL image does the same for its data directory. One you have
already chowned to yourself makes MySQL refuse to initialise.

## 3. Secrets

Two secrets: the MySQL root password and the password for the `ghost` database user. Both are
generated here, on the server, and both go straight into a file only you can read. Hex rather
than base64, because both travel inside connection strings.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste. Neither value is a login you will ever
type into a browser: the account you write with is created in step 7.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/ghost/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten both
passwords, which is fine before the database exists and a problem afterwards: MySQL keeps the
passwords it was created with, so a changed value on an existing data directory shows up as an
access-denied line in the Ghost log rather than anything about passwords.

Do not paste that file, either password, or any output containing them into this chat window.
Read a value with `sudo grep MYSQL_ROOT_PASSWORD /srv/ghost/.env` only when the chat window is
closed, and keep it in your password manager.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: a warning that `MYSQL_ROOT_PASSWORD` is not set means you ran the last line from
somewhere other than /srv/ghost, because that is the only directory where Compose finds the
.env file. `services must be a mapping` means the indentation was lost between the page and
your terminal: run `rm /srv/ghost/compose.yml` and paste again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-ghost /etc/caddy/Caddyfile`, reload,
and paste again. Caddy requests the certificate on the first request to the hostname and
renews it on its own, and it puts no ceiling on request body size, so theme and image uploads
need no setting here.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8100` or `3306`.

If you do not: delete anything for `8100` or `3306` with `sudo ufw delete allow 8100`. 8100 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp redirects to HTTPS and answers the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

Ghost runs its own migrations on first boot against an empty MySQL, and that takes longer than
the containers take to appear in `docker ps`.

```bash
cd /srv/ghost
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/ghost/api/admin/authentication/setup); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/ghost/api/admin/authentication/setup
```

You should see, in order: the loop climbing through `502` and reaching `200`, then exactly
`{"setup":[{"status":false}]}`.

If you do not: a `502` that never clears means Ghost has not bound its port yet, so run
`docker compose logs --tail 20 mysql` first, because a database that never reports healthy is
step 2 done wrong, and `docker compose logs --tail 40 ghost` second. A certificate error points
back at the A record in step 1. A `404` where the JSON should be means Caddy is reaching
something other than Ghost: check `docker compose ps`.

That `status` of `false` is a standing open door: until the first account exists, whoever loads
the setup page owns the publication. Do this now, not tomorrow.

Open https://<DOMAIN>/ghost/ in a browser. The first screen carries the heading
`Welcome to Ghost.` above a form asking for a site title, your full name, an email address and
a password of at least 10 characters. The email address is only a login here, because no mail
is configured. Put the password in your password manager before you submit.

Then prove the door is shut:

```bash
curl -sS https://<DOMAIN>/ghost/api/admin/authentication/setup
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: exactly `{"setup":[{"status":true}]}`, then `200`.

If you do not: a `status` still reading `false` means the form did not submit, and the browser
tab will be showing why. A `502` on the second command means Ghost restarted while you were
typing; wait 30 seconds and run it again.

## 8. First backup and restore

Two artifacts. MySQL holds the posts, pages, tags, members and settings. The content archive
holds the images, the themes and the files that rebuild the service around them.

```bash
cd /srv/ghost
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers ghost' | gzip > /srv/ghost/backups/ghost-db-$(date +%F).sql.gz
sudo tar -C /srv/ghost -czf /srv/ghost/backups/ghost-content-$(date +%F).tar.gz content compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/ghost/backups/
```

You should see: two files, both non-empty, the content archive the larger of the two because
it carries the default theme, and one warning line from mysqldump about passwords on the
command line. That warning is expected: the password is expanded by a shell inside the
container, so it never lands in your own shell history. Nothing goes offline, because
`--single-transaction` snapshots a running InnoDB database.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means mysqldump failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/ghost
scp vps:/srv/ghost/backups/* ~/backups/ghost/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/ghost/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty site:

```bash
cd /srv/ghost
docker compose down
sudo rm -rf /srv/ghost/mysql
sudo install -d -m 700 /srv/ghost/mysql
docker compose up -d mysql
sleep 60
gunzip -c /srv/ghost/backups/ghost-db-$(date +%F).sql.gz | docker compose exec -T mysql sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" ghost'
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/ghost/api/admin/authentication/setup
```

You should see: the same warning line about passwords, then `{"setup":[{"status":true}]}`,
which means your account survived a database that was deleted and rebuilt from the archive.

If you do not: `Access denied for user 'root'` means MySQL had not finished initialising, so
wait longer and run the `gunzip` line again. `Unknown database 'ghost'` means the same thing.
The order matters on a real restore: untar the content archive before any container starts,
because MySQL reads its passwords from .env the moment it initialises an empty data directory.

## 9. Updating later

New versions are listed at https://github.com/TryGhost/Ghost/releases and the matching digest
is on https://hub.docker.com/_/ghost. Take both backups first, then edit the `image:` line in
/srv/ghost/compose.yml to the new tag and its digest.

```bash
cd /srv/ghost
docker compose pull
docker compose up -d
docker compose logs --tail 30 ghost
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
setup check from step 7 before you call the update done. Reach the last release of a major
version before crossing to the next: upstream states that skipping ahead is where database
errors come from.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a failed install for about a minute. I watched
`docker ps` show both containers up while https://<DOMAIN> returned `502 Bad Gateway`, and had
the Caddy config open hunting for a typo before it cleared on its own. Nothing was wrong: MySQL
spends its first 30 to 60 seconds initialising an empty data directory and refuses connections
until it has finished, and Ghost then runs its whole migration set before it binds 2368. That
is what the 40-iteration loop in step 7 is for. Do not restart anything, do not edit the
Caddyfile, and do not conclude the digest is wrong. Watch `docker compose logs -f ghost` and
let it finish.

## 11. Out of scope

- Do not configure SMTP. Ghost publishes and serves the site without it, and mail is a provider
  choice with its own DNS records, made after you have written something.
- Do not enable the analytics or ActivityPub profiles from Ghost's own compose repository. Each
  adds containers and an outside account, and this install gives you the publication.
- Do not switch the database to SQLite. Upstream supports it in development mode only, and the
  image rejects it under NODE_ENV=production.
- Do not run Ghost-CLI commands inside the container. The official image documents that most of
  them are not designed to work there, and `ghost update` fights the digest pin.
