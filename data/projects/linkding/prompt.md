You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install linkding 1.45.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. The same hostname is written into the config in
step 3, as the one origin the login form accepts a POST from, so changing the hostname later
means editing that file as well as the Caddy block.

linkding needs 512 MB of RAM available and 5 GB free on /srv. The image publishes amd64, arm64
and armv7. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve. That 512 MB is for the plain image this prompt
installs. The `-plus` image snapshots pages as HTML with a bundled Chromium, and upstream asks
for at least 1 GB of RAM to run it; step 11 says to leave it alone.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/linkding /srv/linkding/backups
sudo install -d -m 750 -o 33 -g 33 /srv/linkding/data
ls -la /srv/linkding
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by uid `33` at mode
`750`. The container starts as root, runs its migrations, then hands the web server to
`www-data`, uid 33 in the image's Debian base, and chowns the data folder to that uid on every
start. Creating it as 33 now means the first start has nothing to change. Everything for this
service lives under /srv/linkding.

## 3. Secrets

One secret: the password for the only account this install will have. Generate it on the
server. Do not print it, do not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/linkding/.env <<EOF
LD_SUPERUSER_NAME=admin
LD_SUPERUSER_PASSWORD=$(openssl rand -hex 24)
LD_CSRF_TRUSTED_ORIGINS=https://<DOMAIN>
EOF
chmod 600 /srv/linkding/.env
umask 022
ls -l /srv/linkding/.env
```

Replace `<DOMAIN>` on the last line with the real hostname before you write the file. Assert:
the file exists with mode `-rw-------`. Hex rather than base64 for two reasons. Docker Compose
reads this same file for variable interpolation, so a `$` inside a value would be expanded,
and the user has to read this password once and paste it into a login form.

Upstream documents `LD_SUPERUSER_NAME` and `LD_SUPERUSER_PASSWORD` as an initial superuser
created once during container start-up, and states that one created with no password cannot
use the login form at all. Tell the user their password is in /srv/linkding/.env, that they
read it with `sudo grep LD_SUPERUSER_PASSWORD /srv/linkding/.env`, and that it belongs in
their password manager before step 7. linkding publishes no sign-up page and sends no
password-reset mail, so that file and their password manager are the only two places it
exists.

## 4. compose.yml

```bash
cat > /srv/linkding/compose.yml <<'EOF'
# linkding · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ....... https://linkding.link/installation/
#   options reference .... https://linkding.link/options/
#   backups .............. https://linkding.link/backups/
#   archiving ............ https://linkding.link/archiving/
#   proxy and CSRF ....... https://linkding.link/troubleshooting/
#
# One service. Bookmarks, tags and notes are rows in a SQLite database under
# /etc/linkding/data, so there is no second container and no database password
# anywhere. This is the plain image, not the -plus variant, which adds Chromium
# to snapshot pages as HTML and wants at least 1 GB of RAM. The container starts
# as root, migrates the database, then hands the web server to www-data and
# chowns /etc/linkding/data to that uid (33) on every start, which is why the
# install creates the host folder owned by 33. The image carries its own
# HEALTHCHECK against /health, so `docker compose ps` reports health with
# nothing declared here. Tag and digest read from Docker Hub on 2026-08-06; the
# image publishes amd64, arm64 and armv7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  linkding:
    image: sissbruecker/linkding:1.45.0@sha256:61b2eb9eed8e5772a473fb7f1f8923e046cb8cbbeb50e88150afd5ff287d4060
    container_name: linkding
    restart: unless-stopped
    # LD_SUPERUSER_NAME, LD_SUPERUSER_PASSWORD and LD_CSRF_TRUSTED_ORIGINS,
    # mode 600, never printed.
    env_file: /srv/linkding/.env
    environment:
      # SQLite is upstream's default and the choice here. Nothing to operate.
      LD_DB_ENGINE: sqlite
      # Left on (the default). The worker files Wayback Machine snapshots
      # only for an account whose owner turned that on.
      LD_DISABLE_BACKGROUND_TASKS: "False"
      # Every request arrives from Caddy on 127.0.0.1, so without this the
      # access log records the proxy rather than the browser.
      LD_LOG_X_FORWARDED_FOR: "true"
    volumes:
      # db.sqlite3, plus the assets, favicons and previews folders.
      - /srv/linkding/data:/etc/linkding/data
      # Where the backup step writes its zip.
      - /srv/linkding/backups:/backups
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8118.
      - "127.0.0.1:8118:9090"
EOF
cd /srv/linkding && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one database file, and no
connection string to get wrong.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-linkding
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# linkding · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://linkding.link/installation/,
# https://linkding.link/troubleshooting/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream states
# that Caddy passes the Host header through unchanged and needs no extra
# directive for it. The same hostname is also LD_CSRF_TRUSTED_ORIGINS in .env,
# because linkding speaks plain http behind this proxy while the browser sends
# an https Origin, and Django compares the two.

<DOMAIN> {
	# The bookmark list and the JSON API compress well.
	encode zstd gzip

	# linkding sets its own X-Frame-Options: DENY, so this block does not
	# repeat it and must not weaken it. HSTS is here because every request to
	# this host carries a session cookie.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8118 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8118
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-linkding, reload, and report what it objected to. Caddy requests
the certificate on the first request to the hostname and renews it on its own, so there is
nothing to schedule.

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
443/udp is HTTP/3. 8118 stays closed because compose binds it to 127.0.0.1 and Caddy is the
only thing that speaks to it. Assert: `ufw status verbose` prints `Status: active`, shows 80,
443/tcp and 443/udp, and no rule mentioning 8118 or 9090.

## 7. Start and verify

The container generates its Django secret key, runs the migrations, turns on SQLite WAL mode
and creates the account named in `LD_SUPERUSER_NAME`, all on the way up.

```bash
cd /srv/linkding
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/health; echo
curl -sS https://<DOMAIN>/login/ | grep -o 'id="main-heading">Login'
docker compose exec -T linkding python manage.py shell -c "from django.contrib.auth import get_user_model; print(get_user_model().objects.count())"
```

Assert all four, and print what you received for each. The loop ends printing `200`. The
health response reads `{"version": "1.45.0", "status": "healthy"}`, where `status` is the
assert and the version confirms which image is running. The grep prints
`id="main-heading">Login`, the heading on the first screen. The last command prints `1`, which
is the account step 3 created and the whole account list. If any of the four misses, stop, run
`docker compose logs --tail 40 linkding`, and say which earlier step is the likely cause: a
container that exits immediately usually means step 2 left `data` owned by somebody other than
uid 33, a `502` from Caddy against a healthy container means step 5, and a user count of `0`
means the `.env` in step 3 was written after the container first started. A running container
is not success.

The first screen at https://<DOMAIN> redirects to https://<DOMAIN>/login/ and shows the
heading `Login` over `Username` and `Password` boxes and a `Login` button, with the browser
tab reading `Login - Linkding`. There is no register link and no route behind one: upstream
ships no sign-up page, so that count of `1` is the entire access-control surface here.

STOP: tell the user to read their password with `sudo grep LD_SUPERUSER_PASSWORD
/srv/linkding/.env`, put it in their password manager, log in at https://<DOMAIN> as `admin`,
save one bookmark, and wait. Do not continue until they confirm.

```bash
docker compose exec -T linkding python manage.py shell -c "from bookmarks.models import Bookmark; print(Bookmark.objects.count())"
```

Assert: a number greater than 0. Print it. That is a link that went through the browser,
through Caddy, through the login form and into the database, which is the whole product
working end to end. A `403` in the browser at the moment they pressed Login is step 3: see
step 10.

## 8. First backup and restore

Two artifacts. The zip holds the bookmarks. The config archive holds the files that rebuild the
service around them.

```bash
cd /srv/linkding
docker compose exec -T linkding python manage.py full_backup /backups/linkding-$(date +%F).zip
sudo tar -czf /srv/linkding/backups/linkding-config-$(date +%F).tar.gz -C /srv/linkding compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/linkding/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`full_backup` is upstream's own command and it copies the database through SQLite's backup API
rather than reading the file. Upstream warns plainly against copying `db.sqlite3` with `cp`:
that is not transaction safe and can produce a corrupted database.

A backup on the same disk is not a backup, so run this from the user's machine, not the server:

```bash
mkdir -p ~/backups/linkding
scp vps:/srv/linkding/backups/* ~/backups/linkding/
```

To restore: `docker compose down`, `sudo rm -rf /srv/linkding/data`, recreate it exactly as in
step 2, then unpack the zip into it with a one-off container that has the same volumes and no
published port, `docker compose run --rm linkding python -m zipfile -e
/backups/linkding-$(date +%F).zip /etc/linkding/data` with the date of the archive being
restored, then `docker compose up -d`. The zip holds `db.sqlite3` and the `assets`,
`favicons` and `previews` folders at its top level. It does not hold `secretkey.txt`, which the
container writes again on start, so every session is signed out after a restore and the same
password signs back in. Tell the user those five commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/sissbruecker/linkding/releases. Take both backup
artifacts first, then edit the image line in /srv/linkding/compose.yml to the new tag and its
digest:

```bash
cd /srv/linkding
docker compose pull
docker compose up -d
docker compose logs --tail 30 linkding
```

linkding migrates its own database on the way up. Watch that log until it settles, then re-run
the `/health` check from step 7 before calling the update done.

## 10. What will probably go wrong

The login form will look broken before anything else does. linkding speaks plain http to
Caddy, so the framework behind it believes the request arrived over http, while the browser
sends an `Origin` header that says https, and a mismatch there answers the login POST with a
bare `403 CSRF verification failed` page and no other explanation. I lost ten minutes to that
screen convinced the password was wrong. The `LD_CSRF_TRUSTED_ORIGINS` line step 3 writes is
what stops it, which means it has to carry the exact scheme and hostname the user types, with
no trailing path and no port. If the user ever moves this install to a different hostname,
that line moves with it or the login stops working again.

## 11. Out of scope

- Do not switch to the `-plus` image. It bundles a Chromium to snapshot pages as HTML, upstream
  asks for at least 1 GB of RAM before it will behave, and this prompt sized the box for the
  plain one.
- Do not set `LD_DB_ENGINE` to `postgres`. SQLite is the choice here, and it is what the backup
  command in step 8 knows how to snapshot.
- Do not enable `LD_ENABLE_AUTH_PROXY` or `LD_ENABLE_OIDC`. Both hand authentication to an
  identity provider that is a separate install on a separate hostname.
- Do not configure SMTP. linkding sends no mail, so there is nothing for it to do.
