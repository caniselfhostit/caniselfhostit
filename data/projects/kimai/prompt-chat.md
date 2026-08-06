This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Kimai 2.63.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, replace `<DOMAIN>` with the hostname whose A record already points at the
box, and replace `<ADMIN_EMAIL>` with the address you want on the first account.

Two things to decide before you start. `<DOMAIN>` becomes the `TRUSTED_HOSTS` pattern Symfony
checks every request against, so it has to be the name you will actually use. `<ADMIN_EMAIL>`
is an identifier on an account that signs in as `admin`; this install sends no mail, so it does
not have to be a mailbox that works.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of RAM is
the one to take seriously here: this is PHP under Apache plus a MySQL, and the OOM killer
arrives during the first schema build rather than at a moment that tells you why.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kimai /srv/kimai/backups
sudo install -d -m 700 /srv/kimai/mysql
sudo install -d -m 750 /srv/kimai/var
ls -la /srv/kimai
```

You should see: `backups` owned by you, `mysql` at mode `drwx------` owned by root, and `var`
alongside them.

If you do not: leave `mysql` and `var` owned by root on purpose. MySQL chowns its data
directory the first time it starts, and Kimai chowns /opt/kimai/var to its own web user on
every start, so both end up owned by uids the images picked. After step 7 you read either of
them with `sudo`, and that is the images working as designed rather than a permissions bug.

## 3. Secrets

Four secrets: the MySQL root password, the MySQL password for the `kimai` database user,
`APP_SECRET`, and the password the container puts on the first admin account. All four are
generated here, on the server, into a file only you can read. Hex rather than base64, because
the container's start-up script parses `DATABASE_URL` by splitting it on `/`, `:` and `@` and
then url-decoding the pieces: a password holding any of those characters, or a `%`, breaks the
wait-for-database loop before Kimai ever runs.

```bash
umask 077
cat > /srv/kimai/.env <<EOF
DOMAIN_NAME=<DOMAIN>
ADMIN_EMAIL=<ADMIN_EMAIL>
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
APP_SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/kimai/.env
umask 022
ls -l /srv/kimai/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>`
and `<ADMIN_EMAIL>` on the first two lines with your real values before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/kimai/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all
four values, which is fine before the database exists and a problem afterwards: MySQL keeps the
passwords it was created with, so a changed `DB_PASSWORD` against an existing data directory
shows up as an access-denied loop in the Kimai log rather than as anything about passwords.

Do not paste that file, any of those four values, or any command output containing them into
this chat window. The agent path never shows them to anybody; this path will hand them to a
third party unless you keep them out of the box you are typing in.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/kimai/compose.yml <<'EOF'
# Kimai · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose ... https://www.kimai.org/documentation/docker-compose.html
#   docker image ..... https://www.kimai.org/documentation/docker.html
#   backups .......... https://www.kimai.org/documentation/backups.html
#
# Two services: Kimai's Apache image and the MySQL holding every timesheet.
# Upstream supports MariaDB and MySQL only, so there is no SQLite path. Their
# example pins mysql:8.3, an innovation release out of support; 8.4 is the
# long-term line and DATABASE_URL says so. It also splits var/data from
# var/plugins, leaving invoices in an anonymous volume; this file mounts all of
# /opt/kimai/var, the path the image declares as a volume and the one the backup
# page asks you to keep. Digests read 2026-08-06; both images have arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  sqldb:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: kimai-db
    restart: unless-stopped
    command: --default-storage-engine innodb
    environment:
      MYSQL_DATABASE: kimai
      MYSQL_USER: kimai
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - /srv/kimai/mysql:/var/lib/mysql
    healthcheck:
      # Runs inside the container, where that value already is an env var.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u kimai -p$$MYSQL_PASSWORD --silent"]
      start_period: 30s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  kimai:
    image: kimai/kimai2:2.63.0@sha256:c0d55027c384b5f4e612dfeb326fdcff1d700dc469f85961b365eeb1c353119b
    container_name: kimai
    restart: unless-stopped
    environment:
      DATABASE_URL: "mysql://kimai:${DB_PASSWORD}@sqldb/kimai?charset=utf8mb4&serverVersion=8.4.0"
      APP_SECRET: ${APP_SECRET}
      # A regex Symfony matches the Host header against. 127.0.0.1 is in it
      # because the image's own HEALTHCHECK asks for that name.
      TRUSTED_HOSTS: localhost|127.0.0.1|${DOMAIN_NAME}
      # Caddy is on the host, so requests arrive from the docker bridge gateway.
      # Without these ranges Symfony ignores X-Forwarded-Proto and writes
      # http:// links on an https site.
      TRUSTED_PROXIES: 172.16.0.0/12,192.168.0.0/16,10.0.0.0/8
      # The start-up script creates the admin account while ADMINPASS is set.
      # Step 7 drops it from .env; `:-` keeps compose quiet once it is gone.
      ADMINMAIL: ${ADMIN_EMAIL}
      ADMINPASS: ${ADMIN_PASSWORD:-}
      memory_limit: 512M
    volumes:
      - /srv/kimai/var:/opt/kimai/var
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8126.
      - "127.0.0.1:8126:8001"
    depends_on:
      sqldb:
        condition: service_healthy
EOF
cd /srv/kimai && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal, so run `rm /srv/kimai/compose.yml` and paste again in one go. A warning that a
variable is not set means step 3 wrote the .env somewhere other than /srv/kimai, or you are not
in /srv/kimai: compose reads that file from the directory you run it in. Note what is not here:
no SQLite option, because Kimai supports MariaDB and MySQL only, and no host port on the
database at all.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-kimai
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Kimai · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.kimai.org/documentation/docker-compose.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also DOMAIN_NAME in .env, where it becomes the TRUSTED_HOSTS pattern, so the
# two stay the same string.

<DOMAIN> {
	# The interface is HTML, JavaScript and JSON; exports arrive compressed.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy: invoice templates are editable here, and one
	# written without testing them breaks an invoice.

	# 8126 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8126
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-kimai /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the container, which is why the
compose file lists three private network ranges in `TRUSTED_PROXIES`: requests reach the
container from the Docker bridge gateway, and without those ranges Symfony ignores
`X-Forwarded-Proto` and writes `http://` links into an https site.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8126` or `3306`.

If you do not: delete anything for those two with `sudo ufw delete allow 8126`. 8126 is bound
to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has no host
port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and answer the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

MySQL initialises its data directory, then Kimai's start-up script waits for it, builds the
schema and creates one account named `admin` with the password from step 3. First boot takes
two to three minutes, and the log looks alarming the whole time. Read step 10 now if you have
not.

```bash
cd /srv/kimai
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/en/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/en/login | grep -o '<title>[^<]*</title>'
docker compose exec -T kimai /opt/kimai/bin/console kimai:user:list
```

You should see, in order: the loop reaching `200`, then `<title>Kimai</title>`, then a one-row
table whose `Username` is `admin`, whose `Roles` include `ROLE_SUPER_ADMIN` and whose `Active`
column reads `Yes`.

If you do not: a `502` from the loop means Caddy is reaching nothing on 8126, so check
`docker compose ps` and then `docker compose logs --tail 40 kimai`. An empty user table means
the container never saw `ADMIN_PASSWORD`, which is step 3 written to the wrong place. A log
still printing `Wait for database connection` after five minutes means MySQL never came up, so
read `docker compose logs --tail 20 sqldb`. A running container is not success; all three of
these have to pass.

In a browser, https://<DOMAIN> redirects to https://<DOMAIN>/en/login, which shows the wordmark
`Kimai` over the line `Sign in to start your session`, a `Username` box, a `Password` box and a
`Sign In` button.

Read your password once, sign in, and confirm the dashboard loads before you go on, because the
next block deletes the server's copy of it:

```bash
sudo grep ADMIN_PASSWORD /srv/kimai/.env
```

You should see: one line. Put that value in your password manager now, then sign in at
https://<DOMAIN> as `admin`.

If you do not: an empty result means step 3 did not run in this shell. Go back rather than
inventing a password here.

Now close the bootstrap out. The container's start-up script has `bash -x` on its first line,
so the account-creation command, password included, was traced into the container log on first
boot, and it repeats on every restart while `ADMINPASS` still has a value:

```bash
cd /srv/kimai
sed -i '/^ADMIN_PASS/d' /srv/kimai/.env
docker compose up -d --force-recreate kimai
sleep 60
docker compose logs kimai | grep -c 'kimai:user:create' || true
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/en/login
```

You should see: `0` from the count, then `200` from the status.

If you do not: a count above `0` means the .env line is still there, so run
`grep -c '^ADMIN_PASS' /srv/kimai/.env`, confirm it prints `0`, and repeat the block. That `0`
is the security check in this step: recreating the container replaced the log file that held
the traced password, and the deleted line stops the script writing it again on every start.
From here your password manager holds the only copy. If you lose it,
`docker compose exec -it kimai /opt/kimai/bin/console kimai:user:password admin` asks for a new
one on the terminal instead of taking it on a command line.

## 8. First backup and restore

Two artifacts. The database holds the customers, projects, timesheets and rates. The file
archive holds compose.yml, .env, the Caddy site block and `var`, where exports and invoices
live.

```bash
cd /srv/kimai
docker compose exec -T sqldb sh -c 'mysqldump --single-transaction --no-tablespaces -u kimai -p"$MYSQL_PASSWORD" kimai' | gzip > /srv/kimai/backups/kimai-db-$(date +%F).sql.gz
sudo tar -czf /srv/kimai/backups/kimai-files-$(date +%F).tar.gz -C /srv/kimai compose.yml .env var -C /etc/caddy Caddyfile
ls -lh /srv/kimai/backups/
```

You should see: two files, the dump a few tens of kilobytes on a fresh install and the archive
larger. Nothing goes offline: `--single-transaction` snapshots a running InnoDB database
consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mysqldump` failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error.
`Access denied; you need ... the PROCESS privilege` means `--no-tablespaces` was dropped: the
`kimai` user is not a superuser, and that flag is what keeps the dump inside its own database.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/kimai
scp vps:/srv/kimai/backups/* ~/backups/kimai/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/kimai/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty timesheet:

```bash
cd /srv/kimai
sudo tar -xzf /srv/kimai/backups/kimai-files-$(date +%F).tar.gz -C /srv/kimai compose.yml .env
docker compose down
sudo rm -rf /srv/kimai/mysql
sudo install -d -m 700 /srv/kimai/mysql
docker compose up -d sqldb
sleep 60
gunzip -c /srv/kimai/backups/kimai-db-$(date +%F).sql.gz | docker compose exec -T sqldb sh -c 'mysql -u kimai -p"$MYSQL_PASSWORD" kimai'
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/en/login
```

You should see: no output from the `gunzip` line, then `200` from the last command, then your
own account still working when you sign in.

If you do not: `Access denied for user 'kimai'` means the .env was not back before the database
container initialised the empty directory, which is why the untar is the first line rather than
the last. `ERROR 2002` means MySQL had not finished starting, so wait longer and run the
`gunzip` line again. Understand what is at stake: an hour you billed and cannot prove is an
hour you do not get paid for, so this dump is the invoice, not the app.

## 9. Updating later

New versions are listed at https://github.com/kimai/kimai/releases. Kimai ships one most months
and each migrates the database on the way up, so take both backup artifacts first, then edit
the `image:` line in /srv/kimai/compose.yml to the new tag and its digest.

```bash
cd /srv/kimai
docker compose pull
docker compose up -d
docker compose logs --tail 30 kimai
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
first two checks from step 7 before you call the update done, because a login page that answers
`200` can still sit in front of a migration that stopped halfway.

## 10. What will probably go wrong

The first `docker compose logs kimai` looks like a catastrophe and is not. The start-up script
has `bash -x` on its first line, so every command it runs is echoed with a `+` in front of it,
interleaved with `Testing DB:` from the wait loop, and `docker compose ps` says `unhealthy` for
the first minute or two because the image's health check starts polling immediately and gives
up after three tries. I read that as a crashed install and started pulling the compose file
apart before the login page came up on its own. Give step 7's loop its full 40 rounds first.

## 11. Out of scope

- Do not configure SMTP or set `MAILER_URL`. Kimai runs with mail off; the cost is
  password-reset and notification email, and the admin creates accounts by hand.
- Do not enable LDAP or SAML. Both need an identity provider this install does not have, and
  both change how the account from step 7 signs in.
- Do not install plugins from the Kimai store. They need a cache rebuild of their own, and a
  broken one takes the application down.
- Do not turn on self-registration in a `local.yaml`. It is off by default and this host is
  public.
