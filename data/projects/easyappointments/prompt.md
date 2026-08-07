You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Easy!Appointments 1.6.0 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: `<DOMAIN>` becomes
`BASE_URL`, every booking and reschedule link is built from it, and changing it later breaks
links already in customers' inboxes.

Easy!Appointments needs 1536 MB of RAM available and 5 GB free on /srv, most of it for MySQL
8.4. Both images publish amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1536 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/easyappointments /srv/easyappointments/backups
sudo install -d -m 700 /srv/easyappointments/mysql
ls -la /srv/easyappointments
```

Assert: `ls -la` shows `backups` owned by the login user and `mysql` at mode `700` owned by
root. Leave that second one alone: the MySQL image chowns its data directory to its own uid on
first start. The application container gets no volume: it writes nothing that has to
survive it. Appointments, customers, services, providers, working plans and every setting, the
company logo included, are rows in MySQL.

## 3. Secrets

Two secrets, both database passwords: the MySQL root account and the account the application
connects with. Generate both on the server. Do not print either, do not repeat them
in your summary, and do not put them in any log line. Hex rather than base64, because both
travel inside a connection string.

```bash
umask 077
cat > /srv/easyappointments/.env <<EOF
BASE_URL=https://<DOMAIN>
DB_PASSWORD=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/easyappointments/.env
umask 022
ls -l /srv/easyappointments/.env
```

Substitute the real hostname for `<DOMAIN>` before you write the file. Assert: the file exists
with mode `-rw-------`. No administrator password is generated here. That account is created in
a browser in step 7, by the user, with a password they choose that this prompt never sees.

## 4. compose.yml

```bash
cat > /srv/easyappointments/compose.yml <<'EOF'
# Easy!Appointments · the deterministic fallback. Authored by caniselfhostit
# from the upstream documentation, not copied from a repository:
#   server image ... https://github.com/alextselegidis/easyappointments-docker/blob/master/README.md
#   entrypoint ..... https://github.com/alextselegidis/easyappointments-docker/blob/master/assets/docker-entrypoint.sh
#   install guide .. https://github.com/alextselegidis/easyappointments/blob/1.6.0/docs/installation-guide.md
#
# Two services: the PHP application and the MySQL holding every appointment,
# customer, service and setting. Upstream's own docker-compose.yml adds
# phpMyAdmin, Mailpit, Baikal and OpenLDAP, and their docs call that stack
# development only, so this file runs the image the same author publishes for
# servers. The app container gets no volume: its entrypoint rewrites config.php
# from these variables at every start. Digests read from Docker Hub on
# 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  easyappointments-db:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: easyappointments
      MYSQL_USER: easyappointments
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - /srv/easyappointments/mysql:/var/lib/mysql
    healthcheck:
      # -h 127.0.0.1 forces TCP: the first start runs a socket-only server.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 --silent"]
      interval: 10s
      start_period: 60s
      timeout: 5s
      retries: 18
    # No `ports:` at all: 3306 is reachable only from the other container.

  easyappointments:
    image: alextselegidis/easyappointments:1.6.0@sha256:ab35b8872d5d3328fa3afb641a89a75f3c6f96f3fb98d6d6d3447fff9d357fa1
    restart: unless-stopped
    environment:
      # BASE_URL is the address printed inside every booking, reschedule and
      # cancel link, so it carries the https Caddy terminates out front.
      BASE_URL: ${BASE_URL}
      DEBUG_MODE: "FALSE"
      DB_HOST: easyappointments-db
      DB_NAME: easyappointments
      DB_USERNAME: easyappointments
      DB_PASSWORD: ${DB_PASSWORD}
      # Off: turning it on means an OAuth client in your own Google project.
      GOOGLE_SYNC_FEATURE: "FALSE"
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8160.
      - "127.0.0.1:8160:80"
    depends_on:
      easyappointments-db:
        condition: service_healthy
EOF
cd /srv/easyappointments && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The image rewrites config.php from those environment variables
at every start, so the credentials and the base URL live in one file and nothing is edited
inside the container.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-easyappointments
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Easy!Appointments · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/alextselegidis/easyappointments-docker/blob/master/README.md
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also BASE_URL in .env, so the two have to agree.

<DOMAIN> {
	# The booking page is HTML, CSS and JavaScript, so compression pays here.
	encode zstd gzip

	header {
		# Booking page and backend share one hostname, so a downgrade on
		# either is a downgrade on both. The application sends its own
		# X-Frame-Options: SAMEORIGIN, not repeated here.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8160 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Caddy terminates TLS
	# and speaks plain http here, which is why BASE_URL carries the https:
	# PHP reads it to mark the session cookie secure.
	reverse_proxy 127.0.0.1:8160
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-easyappointments, reload, and report what it objected to. Caddy
requests the certificate on the first request and renews it on its own, so there is nothing to
schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8160 stays closed because compose binds it to 127.0.0.1, and 3306 because
compose never publishes it: the database has no host port a rule could apply to.
Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
for 8160 or 3306.

## 7. Start and verify

The first start initialises MySQL, a minute or two, and the application container waits on
it.

```bash
cd /srv/easyappointments
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/index.php/installation); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/index.php/installation | grep -qF 'Easy!Appointments Installation' && echo "installer OK" || echo "installer MISSING"
```

Assert both and print what you received. The loop ends printing `200`, and the second command
prints `installer OK`: that page carries the heading `Easy!Appointments Installation` over the
line `Welcome to the Easy!Appointments installation page.` If either misses, stop, run
`docker compose logs --tail 40 easyappointments` and
`docker compose logs --tail 20 easyappointments-db`, and name the likely cause: a database that
never reports healthy points at step 3, where an empty `DB_PASSWORD` leaves MySQL refusing to
initialise; a `404` instead means Caddy is not reaching the container.

That page is an open form on a public hostname: it hands the administrator account to whoever
loads it first, and it closes by being used.

STOP: tell the user to open https://<DOMAIN>/index.php/installation, enter their first name,
last name, email, a username and a password of at least 8 characters, add their company name and
company email, and press Install. Wait. Do not continue until they confirm.

Once they confirm:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/index.php/installation
curl -sS https://<DOMAIN>/ | grep -qF 'Book Appointment With' && echo "booking page OK" || echo "booking page MISSING"
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/index.php/api/v1/appointments
```

Assert all three. The first prints `307`, or any other 3xx: the installer redirects away now
that the `users` table exists, so the form is gone. A `200` there
means the account was never created and the form is still open to the internet, so stop and send
the user back. The second prints `booking page OK`, the booking page carrying the title
`Book Appointment With`. The third prints `401`, the REST API refusing a caller with no
credentials, and that is the security assert here. A running container is not success.

## 8. First backup and restore

Two artifacts. The database holds every appointment, customer and setting; the config archive
holds the files that rebuild the service around it.

```bash
cd /srv/easyappointments
docker compose exec -T easyappointments-db sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction easyappointments' | gzip > /srv/easyappointments/backups/easyappointments-db-$(date +%F).sql.gz
sudo tar -czf /srv/easyappointments/backups/easyappointments-config-$(date +%F).tar.gz -C /srv/easyappointments compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/easyappointments/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. The password is read inside
the container from its own environment, so it never reaches the host's process list; mysqldump
still warns about command-line passwords on stderr, and that line is expected. Nothing is
stopped: `--single-transaction` snapshots a running InnoDB database consistently. A backup on
the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/easyappointments
scp vps:/srv/easyappointments/backups/* ~/backups/easyappointments/
```

To restore: `docker compose down`, `sudo rm -rf /srv/easyappointments/mysql`, recreate that
directory as in step 2, untar the config archive back into /srv/easyappointments so .env is in
place before anything starts, `docker compose up -d easyappointments-db`, wait a minute for it
to report healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T easyappointments-db sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" easyappointments'`,
then `docker compose up -d`. Tell the user what is at stake: the diary, the customer list and
every future appointment are in that one dump, and a business whose bookings vanish hears about
it from the customers at the door.

## 9. Updating later

New versions are listed at https://github.com/alextselegidis/easyappointments/releases, and the
image tag matching each one is published on Docker Hub. Take both backup artifacts first, then
edit the image line in /srv/easyappointments/compose.yml to the new tag and its digest:

```bash
cd /srv/easyappointments
docker compose pull
docker compose up -d
docker compose logs --tail 30 easyappointments
```

The application migrates its own database on the way up, so watch that log until it settles,
then re-run the three asserts from step 7. An update logs everyone out, because sessions are
files inside the container.

## 10. What will probably go wrong

The first thing I did after the installer finished was book myself an appointment on the public
page, and the confirmation screen said `An email with the appointment details has been sent to
you.` Nothing had been sent and nothing would be: this install configures no SMTP, and the
failure is caught and written to a log inside the container rather than shown. The appointment
was in the calendar the whole time, which is what matters. Do not read that screen as
proof mail works. Tell the user that if they are not adding a relay today they should turn
`Customer Notifications` off under Settings, so the confirmation stops promising customers
something this server cannot do.

## 11. Out of scope

- Do not configure SMTP. The image takes `MAIL_SMTP_HOST` and its siblings as environment
  variables, and choosing a relay, writing SPF and DKIM records and owning deliverability is a
  separate evening.
- Do not enable Google Calendar sync. It needs an OAuth client registered in the user's own
  Google Cloud project, and `GOOGLE_SYNC_FEATURE` stays `FALSE` here.
- Do not set up LDAP or CalDAV sync. Upstream's development stack ships OpenLDAP and Baikal for
  testing those, and neither belongs here.
- Do not install phpMyAdmin. If the database needs a query, run the client inside the container
  that already has one.
