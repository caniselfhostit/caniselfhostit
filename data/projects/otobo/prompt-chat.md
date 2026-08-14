This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing OTOBO 11.0.17 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read this before step 1. OTOBO is the free fork of the OTRS Community Edition, maintained by
Rother OSS, and it is a classic ITSM-shaped ticket system: queues, states, SLAs, escalation
clocks and a customer portal. Two consequences for this install. The web installer you will run
in step 7 is not a signup form, it is the whole system, and until you finish it anyone who loads
your hostname can claim the box. And one of the four containers, the daemon, is the only thing
that makes a clock tick; it will look wrong until the installer is done and it has to look right
afterwards.

## 1. Preflight

Upstream publishes `rotheross/otobo` for linux/amd64 only, so an arm server cannot run this at
all.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64`, and your server's
IP on the last line.

If you do not: `arm64` on the third line ends this here, because there is no image to pull and
emulating four containers of Perl is not a desk anyone can work at. Under 4096 MB or 20 GB, stop
and resize; 4096 MB is upstream's own figure for a machine to test on and theirs for real use is
8 GB with 40 GB of disk, so a busy queue with a year of attachments wants the larger box. An
empty last line means the A record does not exist yet: add it, wait a minute, run
`dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/otobo /srv/otobo/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/otobo/otobo
sudo install -d -m 700 /srv/otobo/mariadb
ls -la /srv/otobo
```

You should see: `backups` owned by you, `otobo` owned by `1000`, and `mariadb` at mode
`drwx------` owned by root.

If you do not: the ownership is the part that goes wrong. The OTOBO image runs as uid 1000 and
copies its whole application tree into `/srv/otobo/otobo` the first time it starts, so it has to
own that directory outright; a directory owned by you gives a permission error in the web
container's log and nothing else. MariaDB takes its own data directory on first start, so leave
that one to root. Keep `mariadb` on local disk: a network mount under an InnoDB data directory
corrupts it quietly, weeks later.

## 3. Secrets

One secret, the MariaDB root password. It is generated here, on the server, into a file only you
can read. Hex rather than base64 because you retype this value into a browser form in step 7 and
OTOBO carries it into a `CREATE USER` statement, where a quote character becomes an error about
SQL syntax rather than anything about passwords.

```bash
umask 077
cat > /srv/otobo/.env <<EOF
OTOBO_DB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/otobo/.env
umask 022
ls -l /srv/otobo/.env
```

You should see: mode `-rw-------` and your own username twice.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines into different shells. Run `chmod 600 /srv/otobo/.env` and carry on. If the
file already existed from an earlier attempt this block has overwritten the password, which is
fine before the database exists and a problem afterwards, because MariaDB keeps the password it
was initialised with.

Do not paste that file, the password, or any command output containing it into this chat window.
The agent path never sees the value; this window hands it to a third party unless you keep it
out. Read it yourself, once, when step 7 asks:
`sudo grep OTOBO_DB_ROOT_PASSWORD /srv/otobo/.env`.

The two other credentials this install ends up with are made by OTOBO during step 7, not here:
one for the limited `otobo` database user, one for the `root@localhost` administrator account.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/otobo/compose.yml <<'EOF'
# OTOBO · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://doc.otobo.org/manual/installation/11.0/en/content/installation/installation-docker.html
#   requirements ....... https://doc.otobo.org/manual/installation/11.0/en/content/requirements.html
#   upstream compose ... https://github.com/RotherOSS/otobo-docker/blob/rel-11_0_17/docker-compose/otobo-base.yml
#
# Four services; `web` and `daemon` are one image dispatched on the command
# word, and no daemon means no SLA fires. Attachments live in the database.
# Redis is required under Docker: the image's Kernel/Config.pm points the
# cache at redis:6379. Elasticsearch is optional upstream, and left out.
# Digests read 2026-08-14; OTOBO is amd64 only.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:12.3.2-noble@sha256:759869cb6f003234a95c6384cdee245b4bce7de26913fe607a8110362c0c007d
    container_name: otobo-db
    restart: unless-stopped
    command: --max-allowed-packet=136314880 --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --innodb-log-file-size=268435456
    environment:
      MARIADB_ROOT_PASSWORD: ${OTOBO_DB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/otobo/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      interval: 10s
      retries: 30

  redis:
    image: redis:8.4.0-bookworm@sha256:c22af04bb576503bf16b3e34a1fd2fd82de0f765afd866d2e380145e0af30d78
    container_name: otobo-redis
    restart: unless-stopped
    user: redis:redis
    cap_drop:
      - ALL
    command: ["redis-server", "--save", ""]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 10

  web:
    image: rotheross/otobo:rel-11_0_17@sha256:381ec32cc5c53bd468af917a888b295497336a73cbd3e1657ce02e474eba383d
    container_name: otobo-web
    restart: unless-stopped
    cap_drop:
      - ALL
    command: web
    volumes:
      # The image copies its application tree here on first start, roughly a
      # gigabyte, and the installer writes Kernel/Config.pm here after that.
      - /srv/otobo/otobo:/opt/otobo
    healthcheck:
      test: ["CMD-SHELL", "curl -sS -f http://localhost:5000/robots.txt >/dev/null"]
      start_period: 300s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: the host's Caddy alone reaches 8202.
      - "127.0.0.1:8202:5000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  daemon:
    image: rotheross/otobo:rel-11_0_17@sha256:381ec32cc5c53bd468af917a888b295497336a73cbd3e1657ce02e474eba383d
    container_name: otobo-daemon
    restart: unless-stopped
    cap_drop:
      - ALL
    command: daemon
    volumes:
      - /srv/otobo/otobo:/opt/otobo
    healthcheck:
      # Unhealthy until the installer finishes: it exits while SecureMode
      # is off, retried every two minutes.
      test: ["CMD-SHELL", "./bin/otobo.Daemon.pl status | grep -q 'Daemon running'"]
      start_period: 300s
      interval: 30s
      retries: 10
    depends_on:
      web:
        condition: service_started
EOF
cd /srv/otobo && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/otobo/compose.yml` and paste again in one go. Note the `cd` on the
last line and keep it on every later compose command: Compose reads /srv/otobo/.env from the
directory the compose file is in, and from anywhere else `${OTOBO_DB_ROOT_PASSWORD}` comes out
empty and MariaDB refuses to start.

Four services, and the shape is worth knowing before you run it. `web` and `daemon` are the same
image under different commands: the Perl web application, and the process that works escalation
clocks and generic agent jobs. MariaDB holds every ticket and every attachment, because
upstream's default article storage is the database rather than the disk. Redis is not optional
under Docker, since the Kernel/Config.pm baked into the image points the cache at redis:6379.
Elasticsearch is left out, which is upstream's own default and not a subtraction from it: their
requirements page lists it under Optional and the setting ships invalid. You lose the
live-preview fulltext search and save a fifth container plus a JVM heap.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-otobo
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# OTOBO · the Caddy site block for this service. Authored by caniselfhostit
# from https://github.com/RotherOSS/otobo/blob/rel-11_0_17/bin/psgi-bin/otobo.psgi
# and https://caddyserver.com/docs/automatic-https. Append it to
# /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname pointed here.
# Upstream terminates TLS in a sixth Nginx container; this uses the Caddy
# already on the box instead.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8202 is the loopback port compose publishes here, not open in the
	# firewall. OTOBO's PSGI app enables its reverse-proxy middleware only
	# when X-Forwarded-Host arrives; that middleware reads X-Forwarded-Proto
	# for the https the session cookie is built from.
	reverse_proxy 127.0.0.1:8202 {
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Proto {scheme}
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-otobo /etc/caddy/Caddyfile`, reload, and
paste again with the real hostname in place of `<DOMAIN>`. Do not delete the two `header_up`
lines to tidy the block up. OTOBO's PSGI application enables its reverse-proxy handling only
when `X-Forwarded-Host` arrives, and that handling is what turns `X-Forwarded-Proto` into the
https scheme its session cookie is built from. Upstream's own answer to TLS is a sixth container
running Nginx against a certificate you keep renewed; this uses the Caddy already on the box,
which gets the certificate on first request and renews it.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8202`, `3306`, `6379` or `5000`.

If you do not: delete anything for those with `sudo ufw delete allow 8202`. 8202 is bound to
127.0.0.1 by the compose file, and 3306 and 6379 are never published at all, so the database and
the cache have no host port a firewall rule could apply to. 80/tcp answers the ACME challenge
and redirects to HTTPS, 443/tcp is the way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall on, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first start looks broken and is not. The web container copies roughly a gigabyte of
application tree out of the image into /srv/otobo/otobo before anything listens on 5000, so use
the loop rather than one impatient curl.

```bash
cd /srv/otobo
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose ps --format '{{.Service}} {{.State}} {{.Health}}'
curl -sSL https://<DOMAIN>/otobo/installer.pl | grep -c 'Welcome to OTOBO'
```

You should see, in order: the loop reaching `200`, then four services with `db`, `redis` and
`web` running and the first two healthy, `daemon` running and unhealthy, and then a number
greater than `0`.

If you do not: the unhealthy daemon is correct at this point and this block ends by fixing it,
so do not chase it yet. Understand what `/health` is worth while you are here: it is a static
file the webserver hands back, so `200` proves Perl is listening and nothing whatever about the
database. If the loop never reaches `200`, run `docker compose logs --tail 40 web` first and
`docker compose logs --tail 20 db` second. A database that never reports healthy is step 2 done
wrong. A `502` from Caddy with `web` up is step 5, usually a hostname in the site block that is
not the one you are asking for.

Now open https://<DOMAIN>/otobo/installer.pl in a browser and work through its four steps. This
is the one part nobody can do for you, and it is urgent rather than optional: that installer is
not a signup form, it is the whole system, and it answers whoever loads your hostname first.
Until you finish it, a stranger could create the schema, choose the administrator password and
lock you out of your own desk.

The values that are not obvious on screen: press `Next`, then `Accept license and continue`. On
Database Settings choose type `MySQL` and `Create a new database for OTOBO`. The screen after
wants User `root`, Host `db`, Database name `otobo`, and only the password is blank, which is
the one you read with `sudo grep OTOBO_DB_ROOT_PASSWORD /srv/otobo/.env`. Press
`Check database settings`, then `Next`, and leave the generated OTOBO database password exactly
as it is. On General Specifications set HTTP Type to `https` and System FQDN to your real
hostname, put your own address in AdminEmail, then `Next` and `Skip this step` on the mail
screen. The last page prints `root@localhost` and a sixteen character password. It is shown once
and never again, so put it in your password manager before you close that tab.

Then shut the last door and prove all of it. Upstream ships `CustomerPanelCreateAccount` on, so
the customer portal offers a `Request Account` form to anyone who loads it, and since this
install configures no mail, an account it creates could never be told its own password.

```bash
cd /srv/otobo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/otobo/installer.pl
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/otobo/migration.pl
curl -sSL https://<DOMAIN>/otobo/customer.pl | grep -c 'oooRegister'
docker compose exec -T web bin/otobo.Console.pl Admin::Config::Update --setting-name CustomerPanelCreateAccount --value 0
docker compose restart web
sleep 45
curl -sSL https://<DOMAIN>/otobo/customer.pl | grep -c 'oooRegister'
curl -sSL https://<DOMAIN>/otobo/index.pl | grep -c 'id="LoginBox"'
docker compose ps --format '{{.Service}} {{.Health}}' | grep daemon
```

You should see, in order: `403`, `403`, a number greater than `0`, `Done` from the console
command, then `0`, a number greater than `0`, and `daemon healthy` within about two minutes.

If you do not: a `200` on either of the first two means the installer did not finish, so go back
to the browser and complete it, because those two 403s are the whole security result of this
step. Finishing it switches SecureMode on, and the middleware in front of installer.pl and
migration.pl refuses both from then on: the setup door and the OTRS migration door, shut with
printed evidence. If the second signup count is not `0`, run the console command again and check
it printed `Done`. If the daemon is still unhealthy after five minutes, run
`docker compose logs --tail 40 daemon`: it exits on its own while SecureMode is off and the
entrypoint retries it every two minutes, so it should recover shortly after the installer, and
an unhealthy daemon means no escalation clock in this product ever fires.

Last, sign in at https://<DOMAIN>/otobo/index.pl as `root@localhost` with the password from the
installer's final page, and confirm you get the agent dashboard. If that password is already
gone, reset it from the server with
`docker compose exec -T web bin/otobo.Console.pl Admin::User::SetPassword root@localhost`. A
running container is not success; this sign-in is.

## 8. First backup and restore

Two artifacts. The database is every ticket, article and attachment, because upstream keeps
attachments in the database rather than on disk. The archive beside it rebuilds the service and
holds the only copy of the password OTOBO gave its own database user.

```bash
cd /srv/otobo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --max-allowed-packet=136314880 -u root -p"$MARIADB_ROOT_PASSWORD" otobo' | gzip > /srv/otobo/backups/otobo-db-$(date +%F).sql.gz
sudo tar -czf /srv/otobo/backups/otobo-config-$(date +%F).tar.gz --exclude=var/tmp -C /srv/otobo compose.yml .env -C /srv/otobo/otobo Kernel/Config.pm var -C /etc/caddy Caddyfile
ls -lh /srv/otobo/backups/
```

You should see: two files, the dump a few hundred kilobytes on a fresh install and the archive a
few megabytes. Nothing goes offline, because `--single-transaction` snapshots InnoDB
consistently, and the root password is read out of the database container's own environment
rather than typed onto a command line where it would land in your shell history.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means mariadb-dump failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error;
`Access denied` there means the `.env` password and the running database no longer agree.

A backup on the same disk as the data is not a backup. Run this on your own machine, not the
server:

```bash
mkdir -p ~/backups/otobo
scp vps:/srv/otobo/backups/* ~/backups/otobo/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/otobo/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

To restore onto a bare box: recreate the layout from step 2, untar the config archive into
/srv/otobo, put the Caddy block back, then `docker compose up -d db` and wait for it to report
healthy. Read the two values the installer generated with
`grep -E "Database(User|Pw)" /srv/otobo/otobo/Kernel/Config.pm`, open
`docker compose exec db mariadb -u root -p`, and recreate database `otobo` with
`CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci` plus that user granted `ALL ON otobo.*`. Pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T db mariadb -u root -p otobo`, bring
the rest up with `docker compose up -d`, then run `Maint::Config::Rebuild` through
`docker compose exec -T web bin/otobo.Console.pl`. Know what is at stake before you skip this:
the dump is every ticket you will ever have, and the `Kernel/Config.pm` beside it is the key
that opens them.

## 9. Updating later

Releases are git tags rather than GitHub releases, listed at
https://github.com/RotherOSS/otobo/tags. The tag scheme is the thing to understand: OTOBO writes
version identity with underscores, so 11.0.17 is the tag `rel-11_0_17`, and the Docker Hub image
tag is that same string. Upstream's own compose file follows a rolling tag that tracks the whole
11.0 line and moves under you; this install pins the release tag plus the digest it resolved to.
Do not move to an `11_1` tag yet: at the time of writing that line exists only as
`rel-11_1_0-beta1` and `-beta2`.

Take both backup artifacts first, then edit the two OTOBO image lines in /srv/otobo/compose.yml
to the new tag and its digest.

```bash
cd /srv/otobo
docker compose pull
docker compose up -d
docker compose logs --tail 40 web
```

You should see: the container copying its new application tree over /srv/otobo/otobo, then
OTOBO migrating its own schema, then the webserver starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Re-run step 7's
checks before you call the update done, including the daemon health line, because a migration
that half ran leaves the desk answering pages with nothing on schedule.

## 10. What will probably go wrong

The daemon. I had a working desk in twenty minutes, tickets moving, everything green in the
browser, and `docker compose ps` reading `unhealthy` beside `otobo-daemon` for an hour while I
looked straight past it. Nothing visible breaks when that happens: pages render, tickets save,
agents work. What stops is every clock in the product, which on this software is most of the
reason to run it. Escalations do not escalate, generic agent jobs do not run, pending reminders
never arrive, and no error appears anywhere a person would look. Unhealthy is only correct
between the first start and about two minutes after you finish the installer. Put
`docker compose ps` in your Monday morning and treat an unhealthy daemon as an outage nobody has
reported yet.

## 11. Out of scope

- Do not configure SMTP or IMAP, in the installer or afterwards. A support address that turns
  mail into tickets is a separate day with a provider whose deliverability you now own.
- Do not add an `elastic` service. Upstream lists Elasticsearch as optional and the setting
  ships off; switching it on costs a JVM heap and a reindex of every ticket.
- Do not install the ITSM packages or the CMDB on day one. Each migrates the database and is
  reinstalled after every image update.
- Do not publish 3306, 6379 or 5000, and do not open any of them in the firewall.
