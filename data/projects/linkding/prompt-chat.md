This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing linkding 1.45.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. That hostname is written into two places, the Caddy site block in
step 5 and a line called `LD_CSRF_TRUSTED_ORIGINS` in step 3, and the second one is why the
login form will work. If you move this install to a different hostname later, both have to
move with it.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line. The image also publishes armv7, so an old Raspberry Pi is fine.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. That 512 MB floor is
for the plain image these steps install. The `-plus` image, the one that saves a copy of every
page you bookmark, ships a Chromium and upstream asks for at least 1 GB of RAM on top.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/linkding /srv/linkding/backups
sudo install -d -m 750 -o 33 -g 33 /srv/linkding/data
ls -la /srv/linkding
```

You should see: `backups` owned by you, and `data` at mode `drwxr-x---` owned by uid `33`,
which `ls` may print as `www-data`.

If you do not: leave `data` owned by 33 on purpose. The container starts as root, runs its
database migrations, then hands the web server to `www-data`, which is uid 33 in the image's
Debian base, and it chowns that folder to uid 33 on every start. Creating it that way now means
the first start has nothing to change, and it is also why reading files in there later needs
`sudo`.

## 3. Secrets

One secret: the password for the only account this install will have. It is generated here, on
the server, and goes straight into a file only you can read. Replace `<DOMAIN>` on the last
line with your real hostname before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path. Read the password
once with `sudo grep LD_SUPERUSER_PASSWORD /srv/linkding/.env` and put it in your password
manager now. linkding publishes no sign-up page and sends no password-reset mail, so that file
and your password manager are the only two places it exists, and the way back from losing both
is a command on the server.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/linkding/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
the password, which is fine before the container has ever started and useless afterwards: the
account keeps the password it was created with, and `LD_SUPERUSER_NAME` does nothing once the
user exists.

Do not paste that file, the password, or any command output containing it into this chat
window. The value is hex rather than base64 for two reasons: Docker Compose reads this same
file for variable interpolation, so a `$` inside a value would be expanded, and you have to
type or paste this one into a login form.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/linkding/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/linkding/compose.yml` and paste again in one go. The image's own health check runs
`curl` against `/health` inside the container every 30 seconds, which is why nothing here
declares one.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-linkding /etc/caddy/Caddyfile`, reload,
and paste again. Caddy requests the certificate on the first request to the hostname and renews
it on its own, so there is nothing to schedule and no certificate path anywhere in that block.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8118` or `9090`.

If you do not: delete anything for `8118` with `sudo ufw delete allow 8118`. 8118 is bound to
127.0.0.1 by the compose file, so no machine other than this one can open it and a firewall
rule would be theatre. 80/tcp is there to redirect to HTTPS and to answer the ACME challenge,
443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default. `Status:
inactive` is a different problem: Prompt Zero left this firewall enabled, so something has
turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The container generates its secret key, runs the migrations, turns on SQLite WAL mode and
creates the account named in `LD_SUPERUSER_NAME`, all on the way up.

```bash
cd /srv/linkding
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/health; echo
curl -sS https://<DOMAIN>/login/ | grep -o 'id="main-heading">Login'
docker compose exec -T linkding python manage.py shell -c "from django.contrib.auth import get_user_model; print(get_user_model().objects.count())"
```

You should see, in order: the loop reaching `200`, then
`{"version": "1.45.0", "status": "healthy"}`, then `id="main-heading">Login`, then `1`.

If you do not: a loop that never reaches `200` is usually the certificate, so run `sudo
journalctl -u caddy --no-pager -n 30` and look for an ACME failure before you touch the
container. A container that exits immediately is step 2 done differently: run `docker compose
logs --tail 40 linkding`. A `0` from the last command means the `.env` was written after the
container had already started once, so run `docker compose down`, then `docker compose up -d`,
then that command again. That `1` is the whole account list on this server: there is no
sign-up page in linkding and no route behind one, so nobody else can make an account without
your password.

Now open https://<DOMAIN> in a browser. It redirects to https://<DOMAIN>/login/ and shows the
heading `Login` over `Username` and `Password` boxes and a `Login` button, with the browser tab
reading `Login - Linkding`. Log in as `admin` with the password from step 3, and save one
bookmark. Then, back on the server:

```bash
docker compose exec -T linkding python manage.py shell -c "from bookmarks.models import Bookmark; print(Bookmark.objects.count())"
```

You should see: a number greater than `0`. That is a link that went through the browser,
through Caddy, through the login form and into the database, which is the whole product
working end to end. A running container was not proof of that; this is.

If you do not: a `403` page saying `CSRF verification failed` at the moment you pressed Login
is step 3, not your password. See step 10.

## 8. First backup and restore

Two artifacts. The zip holds the bookmarks: `db.sqlite3` plus the `assets`, `favicons` and
`previews` folders. The config archive holds the files that rebuild the service around it.

```bash
cd /srv/linkding
docker compose exec -T linkding python manage.py full_backup /backups/linkding-$(date +%F).zip
sudo tar -czf /srv/linkding/backups/linkding-config-$(date +%F).tar.gz -C /srv/linkding compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/linkding/backups/
```

You should see: `Backup created at /backups/linkding-...zip`, then two files listed, both a few
kilobytes on a fresh install. Nothing goes offline: `full_backup` is upstream's own command and
it copies the database through SQLite's own backup API rather than reading the file, which is
what makes it safe on a running server.

If you do not: `no such option: full_backup` means an older image than 1.45.0 is running, so
check the version in the health output from step 7. Do not work around this by copying
`db.sqlite3` with `cp`: upstream warns plainly that copying that file is not transaction safe
and can leave you with a corrupted database that still opens.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/linkding
scp vps:/srv/linkding/backups/* ~/backups/linkding/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/linkding/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is one test bookmark:

```bash
cd /srv/linkding
docker compose down
sudo rm -rf /srv/linkding/data
sudo install -d -m 750 -o 33 -g 33 /srv/linkding/data
docker compose run --rm linkding python -m zipfile -e /backups/linkding-$(date +%F).zip /etc/linkding/data
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/health; echo
docker compose exec -T linkding python manage.py shell -c "from bookmarks.models import Bookmark; print(Bookmark.objects.count())"
```

You should see: `{"version": "1.45.0", "status": "healthy"}`, then the same bookmark count as
before, from a data folder that was deleted and rebuilt out of the zip.

If you do not: a count of `0` means the unzip landed somewhere else, so run `docker compose
exec -T linkding ls -la /etc/linkding/data` and check that `db.sqlite3` is there. One thing
the zip does not contain is `secretkey.txt`, which the container writes again on start, so
every browser session is signed out after a restore and the same password signs you back in.
Those five commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/sissbruecker/linkding/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/linkding/compose.yml to the new tag and
its digest.

```bash
cd /srv/linkding
docker compose pull
docker compose up -d
docker compose logs --tail 30 linkding
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/health` check from step 7 before you call the update done, and check that the `version` field
in the response is the one you meant to install, because a `docker compose pull` that quietly
failed leaves the old image running and a healthy answer coming from it.

## 10. What will probably go wrong

The login form will look broken before anything else does. linkding speaks plain http to
Caddy, so the framework behind it believes the request arrived over http, while your browser
sends an `Origin` header that says https, and a mismatch there answers the login POST with a
bare `403 CSRF verification failed` page and no other explanation. I lost ten minutes to that
screen convinced the password was wrong. The `LD_CSRF_TRUSTED_ORIGINS` line in step 3 is what
stops it, which means it has to carry the exact scheme and hostname you type, with no trailing
path and no port. If you ever move this install to a different hostname, that line moves with
it or the login stops working again.

## 11. Out of scope

- Do not switch to the `-plus` image. It bundles a Chromium to snapshot pages as HTML, upstream
  asks for at least 1 GB of RAM before it will behave, and step 1 sized the box for the plain
  one.
- Do not set `LD_DB_ENGINE` to `postgres`. SQLite is the choice here, and it is what the backup
  command in step 8 knows how to snapshot.
- Do not enable `LD_ENABLE_AUTH_PROXY` or `LD_ENABLE_OIDC`. Both hand authentication to an
  identity provider that is a separate install on a separate hostname.
- Do not configure SMTP. linkding sends no mail, so there is nothing for it to do.
