This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing EspoCRM 10.0.3 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. EspoCRM writes `<DOMAIN>` into its own configuration during its first
start and builds every link it puts in an email out of it, so pick the hostname you intend to
keep. Set aside an unhurried afternoon: this is four containers, a database and a first backup,
and the single most common way it goes wrong is deciding it has failed while it is still
starting.

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
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of RAM is
the other stopper: PHP, a job daemon, a websocket process and MariaDB share this box, and the
one that gets killed under memory pressure is usually the database, which looks like data loss
rather than like a small server.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/espocrm /srv/espocrm/backups
sudo install -d -m 700 /srv/espocrm/db
sudo install -d -m 755 /srv/espocrm/data /srv/espocrm/custom /srv/espocrm/client-custom
ls -la /srv/espocrm
```

You should see: `backups` owned by you, `db` at `drwx------` owned by root, and `data`, `custom`
and `client-custom` at `drwxr-xr-x` owned by root.

If you do not: leave all four owned by root on purpose. The EspoCRM container chowns its three
directories to its web-server user during the first start, and MariaDB chowns its own to the uid
it runs as. A directory you have already chowned to yourself is how each of them fails to
initialise. `data` is the one that matters after today: the configuration file, the logs and
every attachment anybody uploads live in it.

## 3. Secrets

Three secrets, all generated here on the server: the password EspoCRM connects to its database
with, MariaDB's own root password, and the administrator password EspoCRM sets during its first
start. Hex for the two that travel inside a connection string, base64 for the one you will type.
Replace `<DOMAIN>` on the first two lines with your real hostname before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path. Read the administrator
password once with `sudo grep ESPOCRM_ADMIN_PASSWORD /srv/espocrm/.env` and put it in your
password manager: it is the only account this install has.

Do not paste that file, any of those three secrets, or any command output containing them into
this chat window. The other tab never sees these values; this one will hand them to a third
party unless you keep them out.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when
the lines are pasted separately into different shells. Run `chmod 600 /srv/espocrm/.env` and
carry on. If the file already existed from an earlier attempt, this block has now replaced all
three secrets, which is harmless before the database exists and a problem afterwards: MariaDB
keeps the password it was created with, so a changed one on an existing volume shows up as a
connection failure in the EspoCRM log rather than as anything about passwords. One more thing to
know now: the administrator password is applied once, during the first start. Editing this file
later changes nothing, and the change is made inside the CRM instead.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/espocrm/compose.yml` and paste again in one go. A complaint about an
undefined variable means step 3 did not write `.env`, or you are not in `/srv/espocrm`, which is
the directory `docker compose` reads it from. Nothing in this file is a secret: every `${...}` is
looked up in `.env` at start time.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-espocrm /etc/caddy/Caddyfile`, reload,
and paste again. The two `reverse_proxy` lines are both needed and their order matters: the one
with `/ws` in front of it is a path matcher, so it takes only that one request, the WebSocket
that carries live notifications, and everything else falls through to Apache on 8128. Caddy
requests the certificate on the first real request to the hostname and renews it on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8128`, `8228` or `3306`.

If you do not: delete anything for the application ports with `sudo ufw delete allow 8128`. Both
8128 and 8228 are bound to 127.0.0.1 by the compose file, so Caddy reaches them and nothing else
can, and MariaDB publishes no host port at all, which is why 3306 never appears. 80/tcp answers
the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3,
which Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back before
you go any further.

## 7. Start and verify

The first start is slow, and that is correct rather than broken. The app container runs the
installer and builds the schema, which takes minutes on a small box, and the daemon and the
websocket wait on its health check before they start at all.

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

You should see, in order: the loop counting `502` for a while and then reaching `200`,
`<title>EspoCRM</title>`, then `401`, then `true`, then four services listed with `espocrm-db`
and `espocrm` marked healthy.

If you do not: the `401` is the one worth understanding. Upstream's image falls back to a
built-in default administrator password when the environment does not set one, and that pair is
the first login anybody scanning the internet will try. `401` means the password step 3 generated
replaced it. Anything other than `401` there, stop and do not go further. If the loop never
reaches `200`, give it the full ten minutes first, then run
`docker compose logs --tail 20 espocrm-db`, because a database that never reports healthy holds
everything else back, and `docker compose logs --tail 40 espocrm` second. A `true` that comes
back as `false` means the websocket container has not started yet, which is usually the same
waiting problem.

The first screen at https://<DOMAIN> is a login panel with a `Username` field, a `Password` field
and a `Log in` button. Sign in as `admin` with the password from
`sudo grep ESPOCRM_ADMIN_PASSWORD /srv/espocrm/.env`, and confirm the CRM loads before you go on.
Four running containers are not success; a CRM you can sign into is.

## 8. First backup and restore

Two artifacts. Every contact, deal and note is a row in MariaDB. The archive holds what rebuilds
the service around those rows: the attachments, the Caddy site block, and the configuration file
that carries the database password.

```bash
cd /srv/espocrm
docker compose exec -T espocrm-db sh -c 'exec mariadb-dump -u espocrm -p"$MARIADB_PASSWORD" --single-transaction espocrm' | gzip > /srv/espocrm/backups/espocrm-db-$(date +%F).sql.gz
sudo tar -czf /srv/espocrm/backups/espocrm-files-$(date +%F).tar.gz -C /srv/espocrm compose.yml .env data custom client-custom -C /etc/caddy Caddyfile
ls -lh /srv/espocrm/backups/
```

You should see: two files, the dump a few dozen kilobytes on a fresh install and the archive a
little larger. Nothing goes offline: `--single-transaction` snapshots a running InnoDB database
consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump` failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error. Note
what that command does not do: the password is read from inside the database container's own
environment, so it never appears in your shell history or in the host process list, and you
should keep it that way rather than typing it on the command line.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/espocrm
scp vps:/srv/espocrm/backups/* ~/backups/espocrm/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/espocrm/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty CRM:

```bash
cd /srv/espocrm
docker compose down
sudo rm -rf /srv/espocrm/db
sudo install -d -m 700 /srv/espocrm/db
docker compose up -d espocrm-db
sleep 45
gunzip -c /srv/espocrm/backups/espocrm-db-$(date +%F).sql.gz | docker compose exec -T espocrm-db sh -c 'exec mariadb -u espocrm -p"$MARIADB_PASSWORD" espocrm'
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: no output from the import, then `200` from the last command, and your login still
works.

If you do not: `Access denied for user 'espocrm'` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Keep both files together forever:
the archive carries `data/config-internal.php`, and a database restored without it comes back as
rows nothing knows how to open.

## 9. Updating later

New versions are listed at https://github.com/espocrm/espocrm/releases. Take both backup
artifacts first, then edit the `espocrm/espocrm` image line in /srv/espocrm/compose.yml to the new
tag and its digest. It is one line for three services, which is what the `x-espocrm` block at the
top of the file is for.

```bash
cd /srv/espocrm
docker compose pull
docker compose up -d
docker compose logs --tail 30 espocrm
```

You should see: migration output, then the server starting, and no container restarting in a
loop.

If you do not: EspoCRM refuses to start when a customization or an extension is incompatible with
the new release, and it names the version to go back to in that log. Put the old tag and digest
back, run the same three commands, and deal with the customization before trying again. Either
way, re-run the five checks from step 7 before you call the update done.

## 10. What will probably go wrong

You will think it failed while it was still working. `docker compose up -d` returns in seconds,
https://<DOMAIN> answers `502` for the next two or three minutes while the app container installs
itself and builds the schema, and `docker compose ps` shows the daemon and the websocket as
created rather than running, because both wait on a health check that has not passed yet. I read
that as a broken install and had my hand on `docker compose down` before the login page appeared.
Give step 7's loop its full ten minutes, and watch `docker compose logs -f espocrm` rather than
the browser.

## 11. Out of scope

- Do not configure SMTP, an outbound email account or an IMAP mailbox. Each needs credentials
  from a mail provider you have not been asked for, and the CRM runs without them.
- Do not install Advanced Pack, Sales Pack or any other extension. Those are paid products from
  EspoCRM's vendor, installed through the admin panel, not here.
- Do not set `ESPOCRM_DATABASE_PLATFORM` to `Postgresql`. It is fixed at install time.
- Do not enable LDAP, OIDC or two-factor authentication. Each changes how the only account here
  signs in, which is not a thing to do before a backup has been proven.
