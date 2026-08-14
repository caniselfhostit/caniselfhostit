You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install OTOBO 11.0.17 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here. Upstream publishes `rotheross/otobo` for linux/amd64
only, and wants 4096 MB of RAM with 20 GB on /srv.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If the architecture is anything but `amd64`, print it and stop. If RAM is under 4096 MB or free
disk under 20 GB, print both and stop. Upstream's own figures are 4 GB with 10 GB of storage to
test on, and 8 GB with 40 GB for real use. If `dig +short` prints nothing, stop.

## 2. Layout

Three directories, three owners. The OTOBO image runs as uid 1000 and copies its application
tree into the mounted directory on first start, so it owns that. MariaDB takes its own data
directory then, so that one stays root's.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/otobo /srv/otobo/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/otobo/otobo
sudo install -d -m 700 /srv/otobo/mariadb
ls -la /srv/otobo
```

Assert: `backups` owned by the login user, `otobo` by `1000`, `mariadb` at mode `700` owned by
root. Keep `mariadb` local: a network mount under InnoDB corrupts it quietly.

## 3. Secrets

One secret, the MariaDB root password. Generate it on the server, do not print it, do not repeat
it in your summary, do not put it in a log line. Hex rather than base64: the user retypes it
into a browser form in step 7, and OTOBO puts it inside a `CREATE USER` statement where a quote
character becomes an error about SQL syntax.

```bash
umask 077
cat > /srv/otobo/.env <<EOF
OTOBO_DB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/otobo/.env
umask 022
ls -l /srv/otobo/.env
```

Assert: mode `-rw-------`. Compose reads it from the compose file's own directory, which is why
every `docker compose` command runs after `cd /srv/otobo`. Tell the user to read it with
`sudo grep OTOBO_DB_ROOT_PASSWORD /srv/otobo/.env` and keep it: step 7 needs it.

## 4. compose.yml

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

Assert: `compose OK`. Four services, one port.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy it first: a syntax error takes every site down.

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

Assert: `caddy validate` and the reload both exit 0. On failure restore the copy, reload, and
report it.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the way in, 443/udp is HTTP/3. 8202
is on 127.0.0.1; 3306 and 6379 have no host port. Assert: `Status: active`, 80, 443/tcp and
443/udp present, none for 8202, 3306, 6379 or 5000.

## 7. Start and verify

The first start looks broken and is not: the web container copies roughly a gigabyte out of the
image into /srv/otobo/otobo before it listens.

```bash
cd /srv/otobo
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose ps --format '{{.Service}} {{.State}} {{.Health}}'
curl -sSL https://<DOMAIN>/otobo/installer.pl | grep -c 'Welcome to OTOBO'
```

Assert all three. The loop ends on `200`, and `/health` is a static file, so it proves Perl is
listening and nothing about the database. `ps` shows `db`, `redis` and `web` running, the first
two healthy, `daemon` unhealthy until the installer is done. The grep prints above `0`,
`Welcome to OTOBO` being its first heading. On a miss read
`docker compose logs --tail 40 web` then `db`: a database never healthy is step 2's ownership,
`502` with `web` up is step 5.

STOP: that installer is not a signup form, it is the whole system, and it answers whoever loads
the hostname first. Tell the user to open https://<DOMAIN>/otobo/installer.pl and work its four
steps, then wait. Do not continue until they confirm. The values not obvious on screen: choose
`MySQL` and `Create a new database for OTOBO`; User `root`, Host `db`, Database `otobo`, and in
the one blank field the password from `sudo grep OTOBO_DB_ROOT_PASSWORD /srv/otobo/.env`; keep
the generated database password; HTTP Type `https`, System FQDN the real hostname; `Skip this
step` on the mail screen. The last page prints `root@localhost` and a sixteen character
password, shown once, for their password manager before that tab closes.

Once they confirm, shut the last door and prove all of it. Upstream ships
`CustomerPanelCreateAccount` on, so the customer portal offers a `Request Account` form to
anyone, and with no mail here that account could never learn its password.

```bash
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

Assert, in order: `403`, `403`, a count above `0`, `Done`, then `0`, a count above `0`, and
`healthy` within two minutes. The installer set SecureMode, so the middleware now refuses
installer.pl and migration.pl: the setup door and the OTRS migration door, shut with printed
evidence. The console command shuts the third and the `0` proves it; agents have no self-service
door at all. The daemon exits while SecureMode is off and is retried every two minutes, hence
that delay. All of these pass before success is reported.

STOP: tell the user to sign in at https://<DOMAIN>/otobo/index.pl as `root@localhost` with that
password, and wait. Do not continue until they confirm they see the agent dashboard. If it is
gone: `docker compose exec -T web bin/otobo.Console.pl Admin::User::SetPassword root@localhost`.

## 8. First backup and restore

Two artifacts. The database is every ticket, article and attachment, because upstream keeps
attachments in it rather than on disk. The archive beside it rebuilds the service and carries
OTOBO's own database password.

```bash
cd /srv/otobo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --max-allowed-packet=136314880 -u root -p"$MARIADB_ROOT_PASSWORD" otobo' | gzip > /srv/otobo/backups/otobo-db-$(date +%F).sql.gz
sudo tar -czf /srv/otobo/backups/otobo-config-$(date +%F).tar.gz --exclude=var/tmp -C /srv/otobo compose.yml .env -C /srv/otobo/otobo Kernel/Config.pm var -C /etc/caddy Caddyfile
ls -lh /srv/otobo/backups/
```

Assert: both files exist and are non-empty. Print both sizes. Nothing stops, because
`--single-transaction` snapshots InnoDB consistently, and the root password is read from the
database container's environment, never typed on a command line. A backup on the same disk is
not a backup, so run this on the user's machine:

```bash
mkdir -p ~/backups/otobo
scp vps:/srv/otobo/backups/* ~/backups/otobo/
```

To restore onto a bare box: recreate step 2's layout, untar the config archive into /srv/otobo,
put the Caddy block back, `docker compose up -d db`, wait for healthy. Read the pair the
installer generated with `grep -E "Database(User|Pw)" /srv/otobo/otobo/Kernel/Config.pm`, and in
`docker compose exec db mariadb -u root -p` recreate database `otobo` `CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci` plus that user with `ALL ON otobo.*`. Pipe `gunzip -c` on the dump
into `docker compose exec -T db mariadb -u root -p otobo`, then `docker compose up -d` and
`docker compose exec -T web bin/otobo.Console.pl Maint::Config::Rebuild`.

## 9. Updating later

Releases are git tags rather than GitHub releases, at https://github.com/RotherOSS/otobo/tags.
OTOBO writes version identity with underscores, so 11.0.17 is the tag `rel-11_0_17` and the
Docker Hub tag is that string. Upstream's compose follows a rolling tag for the 11.0 line, which
moves under you; this pins the tag and its digest. Do not move to `11_1` yet: it is
`rel-11_1_0-beta1` and `-beta2`. Back up, then edit both OTOBO image lines:

```bash
cd /srv/otobo
docker compose pull
docker compose up -d
docker compose logs --tail 40 web
```

The container copies the new tree over /srv/otobo/otobo and OTOBO migrates its schema, so watch
that log until it settles, then re-run step 7's asserts.

## 10. What will probably go wrong

The daemon. I had a working desk in twenty minutes, tickets moving, everything green in the
browser, and `docker compose ps` reading `unhealthy` beside `otobo-daemon` for an hour.
Nothing visible breaks: pages render, tickets save, agents work. What stops is
every clock in the product, which here is most of the reason to run it. Escalations do not
escalate, generic agent jobs do not run, reminders never arrive, and no error shows anywhere a
person would look. Unhealthy is correct only between first start and two minutes after the
installer. Put `docker compose ps` into your Monday morning.

## 11. Out of scope

- Do not configure SMTP or IMAP, in the installer or after. Turning a support address into
  tickets is a separate day with a provider whose deliverability the user owns.
- Do not add an `elastic` service. Upstream lists Elasticsearch as optional and the setting
  ships off; switching it on costs a JVM heap and a reindex of every ticket.
- Do not install the ITSM packages or the CMDB on day one. Each migrates the database and is
  reinstalled after every image update.
- Do not publish 3306, 6379 or 5000, or open them in the firewall.
