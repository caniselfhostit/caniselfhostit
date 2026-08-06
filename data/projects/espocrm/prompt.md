You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install EspoCRM 10.0.3 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
EspoCRM writes it into its own config on first start and builds every link it mails out of it,
so it is settled now. Its A record must point at this server already.

EspoCRM and MariaDB need 2048 MB of RAM available and 10 GB free on /srv. Both images publish
amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop.

## 2. Layout

Root owns most of this on purpose: the EspoCRM containers chown their three directories to
www-data on the way up, MariaDB chowns its own to the uid it runs as, and a directory pre-owned
by the login user is how each of them fails a first boot.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/espocrm /srv/espocrm/backups
sudo install -d -m 700 /srv/espocrm/db
sudo install -d -m 755 /srv/espocrm/data /srv/espocrm/custom /srv/espocrm/client-custom
ls -la /srv/espocrm
```

Assert: `backups` is owned by the login user, `db` is `drwx------` owned by root, the other three
are `drwxr-xr-x` owned by root. `data` is the one that matters after today: the config file, the
logs and every attachment anybody uploads live in it.

## 3. Secrets

Three: the password EspoCRM connects to its database with, MariaDB's root password, and the
administrator password EspoCRM sets on first start. Generate all three on the server. Do not
print them, do not repeat them in your summary, do not put them in a log line. Hex for the two
inside a connection string, base64 for the one a human types.

```bash
umask 077
cat > /srv/espocrm/.env <<EOF
ESPOCRM_SITE_URL=https://<DOMAIN>
ESPOCRM_WEB_SOCKET_URL=wss://<DOMAIN>/ws
ESPOCRM_DATABASE_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ESPOCRM_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/espocrm/.env
umask 022
ls -l /srv/espocrm/.env
```

Assert: mode `-rw-------`. Left unset, upstream's entrypoint falls back to a built-in default for
the admin and the database account, warns in the log, and starts anyway, so this block closes
that door before the first request arrives and step 7 proves it closed. Tell the user the
administrator password is applied once, on first start: editing this file later changes nothing,
and the change has to be made inside the CRM.

## 4. compose.yml

```bash
cat > /srv/espocrm/compose.yml <<'EOF'
# EspoCRM · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.espocrm.com/administration/docker/installation/
#   caddy topology ..... https://docs.espocrm.com/administration/docker/caddy/
#   entrypoint script .. https://github.com/espocrm/espocrm-docker/blob/master/docker-entrypoint.sh
#   jobs and the daemon  https://docs.espocrm.com/administration/jobs/
#
# Four services. Only espocrm answers a browser: it is Apache plus PHP. The
# daemon runs the job queue, where notification email, mass mailing, inbound
# mail checking and cleanup happen, so a CRM without it looks healthy and does
# nothing on schedule. The websocket carries live updates, MariaDB the rows.
# Digests read from Docker Hub on 2026-08-06; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: espocrm

# The three EspoCRM services run one image over one set of directories, which
# upstream does with volumes_from. Compose ignores x- keys, so the pin below
# covers all three.
x-espocrm: &espocrm
  image: espocrm/espocrm:10.0.3@sha256:a2664ea087c2cbe2dc4bf3306c56b985402c19c2e758b39463742fae14dca513
  restart: unless-stopped
  volumes:
    - /srv/espocrm/data:/var/www/html/data
    - /srv/espocrm/custom:/var/www/html/custom
    - /srv/espocrm/client-custom:/var/www/html/client/custom

services:
  espocrm-db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: espocrm
      MARIADB_USER: espocrm
      MARIADB_PASSWORD: ${ESPOCRM_DATABASE_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    volumes:
      - /srv/espocrm/db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      start_period: 30s
      timeout: 10s
      retries: 6
    # No `ports:`: 3306 is reachable only from the other containers.

  espocrm:
    <<: *espocrm
    environment:
      ESPOCRM_DATABASE_HOST: espocrm-db
      ESPOCRM_DATABASE_USER: espocrm
      ESPOCRM_DATABASE_PASSWORD: ${ESPOCRM_DATABASE_PASSWORD}
      ESPOCRM_ADMIN_USERNAME: admin
      ESPOCRM_ADMIN_PASSWORD: ${ESPOCRM_ADMIN_PASSWORD}
      ESPOCRM_SITE_URL: ${ESPOCRM_SITE_URL}
    healthcheck:
      # First start installs and builds the schema: minutes, not seconds.
      test: ["CMD", "bin/command", "app-check"]
      interval: 30s
      start_period: 180s
      timeout: 20s
      retries: 5
    ports:
      # Loopback only: the host's Caddy is the only thing reaching 8128.
      - "127.0.0.1:8128:80"
    depends_on:
      espocrm-db:
        condition: service_healthy

  espocrm-daemon:
    <<: *espocrm
    entrypoint: docker-daemon.sh
    depends_on:
      espocrm:
        condition: service_healthy
    # No healthcheck, no `ports:`: app-check reads the shared config, not the
    # job loop, so container state is the honest signal here.

  espocrm-websocket:
    <<: *espocrm
    entrypoint: docker-websocket.sh
    environment:
      # Written into the config all three share, which is how the app container
      # learns where to publish notifications.
      ESPOCRM_CONFIG_USE_WEB_SOCKET: "true"
      ESPOCRM_CONFIG_WEB_SOCKET_URL: ${ESPOCRM_WEB_SOCKET_URL}
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBSCRIBER_DSN: "tcp://*:7777"
      ESPOCRM_CONFIG_WEB_SOCKET_ZERO_M_Q_SUBMISSION_DSN: "tcp://espocrm-websocket:7777"
    ports:
      # Loopback only: Caddy sends the /ws route here and nothing else can.
      - "127.0.0.1:8228:8080"
    depends_on:
      espocrm:
        condition: service_healthy
EOF
cd /srv/espocrm && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Every `${...}` comes from step 3's `.env`, which
`docker compose` reads from this directory on its own, so no secret is in this file. Two
published ports, both loopback, and a database publishing nothing.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first, since
a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-espocrm
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# EspoCRM · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.espocrm.com/administration/docker/caddy/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also ESPOCRM_SITE_URL in .env, which EspoCRM writes into its own config on
# first start and builds every link it mails out of.

<DOMAIN> {
	# A JavaScript bundle and a JSON API, both worth compressing.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# Live notifications ride a WebSocket on a container of its own, at the
	# exact path EspoCRM is told to dial. reverse_proxy upgrades the connection
	# and forwards Host, X-Forwarded-For and X-Forwarded-Proto already.
	reverse_proxy /ws 127.0.0.1:8228

	# 8128 is the loopback port compose publishes for Apache. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8128
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-espocrm, reload, and report what it objected to. Caddy takes the
certificate on the first request and renews it alone. One site, two routes: `/ws` reaches the
websocket container, everything else Apache.

## 6. Firewall

Three ports open, all Caddy's, and idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8128 and 8228 stay closed because compose binds both to 127.0.0.1 and only Caddy needs
them, and 3306 stays closed because the database publishes no host port at all. Assert:
`Status: active`, rules for 80, 443/tcp and 443/udp, nothing for 8128, 8228 or 3306.

## 7. Start and verify

The first start is slow and that is correct: the app container runs the installer and builds the
schema while the other two wait on its health check.

```bash
cd /srv/espocrm
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/ | grep -o '<title>EspoCRM</title>'
curl -sS -o /dev/null -w '%{http_code}\n' -u admin:password https://<DOMAIN>/api/v1/App/user
docker compose exec -T espocrm bin/command config:get useWebSocket
docker compose ps
```

Assert all five and print what you received for each. The loop ends on `200`. The second prints
`<title>EspoCRM</title>`. The third prints `401`, the security assert here: `admin` with
upstream's built-in default is the first login a scanner tries, and `401` proves step 3 replaced
it. The fourth prints `true`, which happens only once the websocket container has written to the
config all three share. The fifth lists four services, `espocrm-db` and `espocrm` healthy. If any
miss, stop, run `docker compose logs --tail 40 espocrm` and
`docker compose logs --tail 20 espocrm-db`, and name the likely step: `502` means nothing is
listening on 8128 yet, a database connection error points at step 3, a daemon restarting in a
loop means the app never reported healthy. A running container is not success.

The first screen at https://<DOMAIN> is a login panel with a `Username` field, a `Password` field
and a `Log in` button.

STOP: tell the user to read their password with
`sudo grep ESPOCRM_ADMIN_PASSWORD /srv/espocrm/.env`, put it in their password manager, sign in
at https://<DOMAIN> as `admin`, and confirm the CRM loads. Wait. Do not continue until they
confirm. It is the only account here.

## 8. First backup and restore

Two artifacts. Every contact, deal and note is a row in MariaDB; the archive holds what rebuilds
the service around those rows, attachments and config file included.

```bash
cd /srv/espocrm
docker compose exec -T espocrm-db sh -c 'exec mariadb-dump -u espocrm -p"$MARIADB_PASSWORD" --single-transaction espocrm' | gzip > /srv/espocrm/backups/espocrm-db-$(date +%F).sql.gz
sudo tar -czf /srv/espocrm/backups/espocrm-files-$(date +%F).tar.gz -C /srv/espocrm compose.yml .env data custom client-custom -C /etc/caddy Caddyfile
ls -lh /srv/espocrm/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing goes offline, because
`--single-transaction` snapshots a running InnoDB database consistently, and the password reaches
`mariadb-dump` from the container's own environment, so it is in neither the host process list
nor the shell history.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/espocrm
scp vps:/srv/espocrm/backups/* ~/backups/espocrm/
```

To restore: `docker compose down`, `sudo rm -rf /srv/espocrm/db`, recreate it as in step 2,
`sudo tar -xzf <archive> -C /srv/espocrm compose.yml .env data custom client-custom`,
`docker compose up -d espocrm-db`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T espocrm-db sh -c 'exec mariadb -u espocrm -p"$MARIADB_PASSWORD" espocrm'`,
then `docker compose up -d`. Order matters: the archive carries `data/config-internal.php`, and
rows restored without it are rows nothing knows how to open.

## 9. Updating later

New versions are listed at https://github.com/espocrm/espocrm/releases. Take both backups first,
then edit the `espocrm/espocrm` image line in /srv/espocrm/compose.yml to the new tag and digest.
It is one line for three services, which is the point of the `x-espocrm` block.

```bash
cd /srv/espocrm
docker compose pull
docker compose up -d
docker compose logs --tail 30 espocrm
```

EspoCRM migrates its own database on the way up and refuses to start if a customization is
incompatible with the new release, naming the version to go back to. Watch that log settle, then
re-run step 7's five checks.

## 10. What will probably go wrong

You will think it failed while it was still working. `docker compose up -d` returns in seconds,
https://<DOMAIN> answers `502` for two or three minutes while the app container installs itself
and builds the schema, and `docker compose ps` shows the daemon and websocket created rather than
running, because both wait on a health check that has not passed. I read that as a broken install
and had my hand on `docker compose down` before the login page appeared. Give step 7's loop its
full ten minutes, watching `docker compose logs -f espocrm` and not the browser.

## 11. Out of scope

- Do not configure SMTP, an outbound email account or an IMAP mailbox. Each needs credentials
  from a mail provider the user has not been asked for, and the CRM runs without them.
- Do not install Advanced Pack, Sales Pack or any other extension. Those are paid products from
  EspoCRM's vendor, installed through the admin panel, not here.
- Do not set `ESPOCRM_DATABASE_PLATFORM` to `Postgresql`. It is fixed at install time.
- Do not enable LDAP, OIDC or two-factor authentication. Each changes how the only account here
  signs in, which is not a thing to do before a backup has been proven.
