This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Easy!Appointments 1.6.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `BASE_URL`, the address printed inside every
booking, reschedule and cancellation link this software sends out. Change it later and the links
your customers are holding stop working. Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1536` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that
does not resolve and failed attempts count against a rate limit you cannot see. Under 1536 MB
available is the one to take seriously here: MySQL 8.4 plus PHP on a 1 GB box will install fine
and then get killed by the kernel during the first busy morning.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/easyappointments /srv/easyappointments/backups
sudo install -d -m 700 /srv/easyappointments/mysql
ls -la /srv/easyappointments
```

You should see: `backups` owned by you, and `mysql` at mode `drwx------` owned by root.

If you do not: leave `mysql` owned by root on purpose. The MySQL image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it
refuse. There is no `data` directory for the application itself, and that is not an omission:
every appointment, customer, service, provider and working plan, and the company logo too, is a
row in MySQL. The container's own storage folder holds sessions, cache and logs, and losing it
logs everyone out and costs nothing else.

## 3. Secrets

Two secrets, both database passwords: one for the MySQL root account, one for the account the
application connects with. Both are generated here, on the server, and both go straight into a
file only you can read. Replace `<DOMAIN>` on the first line before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/easyappointments/.env`
and carry on. If the file already existed from an earlier attempt, this block has now
overwritten both passwords, which is harmless before the database exists and a problem
afterwards: MySQL keeps the password it was created with, so a changed `DB_PASSWORD` on an
existing data directory shows up as an access-denied error in the application log rather than as
anything about passwords.

Do not paste that file, either password, or any command output containing them into this chat
window. Nothing in this install ever needs you to.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/easyappointments/compose.yml` and paste again in one go. A warning
about the `DB_PASSWORD` variable not being set means step 3 did not write the file, or you are
running the command from a different directory: compose reads `.env` from the folder the file
sits in.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-easyappointments /etc/caddy/Caddyfile`,
reload, and paste again. Caddy terminates TLS and speaks plain http to the container, which is
why `BASE_URL` in your .env carries the https. PHP reads that value to decide the session cookie
is a secure one, so an http `BASE_URL` behind an https site is a real weakness rather than a
cosmetic mismatch.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8160` or `3306`.

If you do not: delete anything for `8160` or `3306` with `sudo ufw delete allow 8160`. 8160 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp redirects to HTTPS and answers the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The first start initialises MySQL from nothing, which takes a minute or two, and the application
container is held back until the database reports healthy. The loop below is that wait.

```bash
cd /srv/easyappointments
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/index.php/installation); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/index.php/installation | grep -qF 'Easy!Appointments Installation' && echo "installer OK" || echo "installer MISSING"
```

You should see: the loop counting up and reaching `200`, then `installer OK`.

If you do not: run `docker compose logs --tail 20 easyappointments-db` first, because a database
that never reports healthy holds everything else back, then
`docker compose logs --tail 40 easyappointments`. A `404` where a `200` was expected means Caddy
is not reaching the container: check `docker compose ps`. A `502` usually means the loop ran out
before MySQL finished; give it another two minutes and run the loop again.

Now open https://<DOMAIN>/index.php/installation in a browser. The page shows the heading
`Easy!Appointments Installation` over the line
`Welcome to the Easy!Appointments installation page.` It is an open form on a public hostname
and it hands the administrator account to whoever loads it first, so do this now rather than
tomorrow: enter your first name, last name, email, a username and a password of at least 8
characters, add your company name and company email, and press Install.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/index.php/installation
curl -sS https://<DOMAIN>/ | grep -qF 'Book Appointment With' && echo "booking page OK" || echo "booking page MISSING"
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/index.php/api/v1/appointments
```

You should see: `307` (any other 3xx means the same thing), then `booking page OK`, then `401`.

If you do not: a `200` from the first line means the installer form is still there and your
account was never created, so go back to the browser and finish it before anything else. The
`307` is this framework's answer to a redirected GET, and here it means the installer is
redirecting away because the `users` table now exists; a `302` from a different proxy setup
means exactly the same. The `401` on the last line is the API
refusing a caller with no credentials, and it is the security check in this step: anything else
there, especially a `200`, means stop and investigate. A running container is not success.

The backend where you set your working hours, services and providers is
https://<DOMAIN>/index.php/calendar, and it asks for the username and password you entered in
the installer.

## 8. First backup and restore

Two artifacts. The database holds every appointment, customer and setting. The config archive
holds the files that rebuild the service around it.

```bash
cd /srv/easyappointments
docker compose exec -T easyappointments-db sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction easyappointments' | gzip > /srv/easyappointments/backups/easyappointments-db-$(date +%F).sql.gz
sudo tar -czf /srv/easyappointments/backups/easyappointments-config-$(date +%F).tar.gz -C /srv/easyappointments compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/easyappointments/backups/
```

You should see: two files, the dump a few dozen kilobytes on a fresh install and the config
archive a couple of kilobytes. One warning from mysqldump about using a password on the command
line goes to stderr and is expected. Nothing goes offline: `--single-transaction` snapshots a
running InnoDB database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means mysqldump failed and
the shell created the file anyway. Run the same line without `| gzip` to read the error. The
password is read from inside the container, which is why it does not appear in your shell
history or in `ps`.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/easyappointments
scp vps:/srv/easyappointments/backups/* ~/backups/easyappointments/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/easyappointments/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty diary:

```bash
cd /srv/easyappointments
docker compose down
sudo rm -rf /srv/easyappointments/mysql
sudo install -d -m 700 /srv/easyappointments/mysql
docker compose up -d easyappointments-db
sleep 90
gunzip -c /srv/easyappointments/backups/easyappointments-db-$(date +%F).sql.gz | docker compose exec -T easyappointments-db sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" easyappointments'
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/ | grep -qF 'Book Appointment With' && echo "restore OK" || echo "restore MISSING"
```

You should see: `restore OK`, which means the booking page came back from a database that was
deleted and rebuilt from the dump.

If you do not: `ERROR 1045 (28000): Access denied` means the new data directory was initialised
with a different password, so check that .env is the same file it was when you took the dump.
`Unknown database` means the container had not finished initialising when the pipe ran, so wait
another minute and run the `gunzip` line again. Understand the stakes before you skip this step:
your diary, your customer list and every appointment anyone has booked are in that one file.

## 9. Updating later

New versions are listed at https://github.com/alextselegidis/easyappointments/releases, and the
matching image tag is published on Docker Hub. Take both backup artifacts first, then edit the
`image:` line in /srv/easyappointments/compose.yml to the new tag and its digest.

```bash
cd /srv/easyappointments
docker compose pull
docker compose up -d
docker compose logs --tail 30 easyappointments
```

You should see: the application starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. The application
migrates its own database on the way up, so re-run the three checks from step 7 before you call
the update done. Everyone is logged out by an update, because sessions are files inside the
container, and that is expected rather than a sign the upgrade broke your accounts.

## 10. What will probably go wrong

The first thing I did after the installer finished was book myself an appointment on the public
page, and the confirmation screen said `An email with the appointment details has been sent to
you.` Nothing had been sent and nothing would be: this install configures no SMTP, and the
failure is caught and written to a log inside the container rather than shown. The appointment
was in the calendar the whole time, which is what matters. Do not read that screen as proof mail
works. If you are not adding a mail relay today, turn `Customer Notifications` off under
Settings, so the confirmation stops promising your customers something your server cannot do.

## 11. Out of scope

- Do not configure SMTP. The image takes `MAIL_SMTP_HOST` and its siblings as environment
  variables, and choosing a relay, writing SPF and DKIM records and owning deliverability is a
  separate evening.
- Do not enable Google Calendar sync. It needs an OAuth client registered in your own Google
  Cloud project, and `GOOGLE_SYNC_FEATURE` stays `FALSE` here.
- Do not set up LDAP or CalDAV sync. Upstream's development stack ships OpenLDAP and Baikal for
  testing those, and neither belongs here.
- Do not install phpMyAdmin. If the database needs a query, run the client inside the container
  that already has one.
