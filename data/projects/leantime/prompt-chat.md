This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Leantime 3.9.8 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Read this before step 1. `<DOMAIN>` becomes `LEAN_APP_URL`, the base Leantime builds every
redirect against. It is not a label you can swap later without editing .env and restarting, and a
mismatch between it and the name you type in a browser is the single most common way this install
appears broken while running perfectly.

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
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. If the RAM figure is
short, this is PHP-FPM, nginx and MySQL on one box; 1 GB will start and then be killed by the
kernel partway through your first project import.

## 2. Layout

The application image runs as `www-data`, uid 1000, so the two directories it writes to are
created owned by 1000 rather than by you.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/leantime /srv/leantime/backups
sudo install -d -m 700 /srv/leantime/mysql
sudo install -d -m 750 -o 1000 -g 1000 /srv/leantime/userfiles /srv/leantime/public-userfiles
ls -la /srv/leantime
```

You should see: `backups` owned by you, `mysql` at mode `drwx------` owned by root, and both
`userfiles` directories at `drwxr-x---` owned by uid 1000, which `ls` may print as a username if
your own account happens to be 1000.

If you do not: leave `mysql` owned by root on purpose. The MySQL image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. Do not chown the two `userfiles` directories to yourself either: the container
cannot write to them if you do, and uploads then fail with a permission error that names a path
inside the container rather than on the host.

## 3. Secrets

Three secrets: the MySQL root password, the MySQL password for the `leantime` database user, and
`LEAN_SESSION_PASSWORD`, which salts every session cookie. All three are generated here, on the
server, and all three go into a file only you can read.

Hex rather than base64 for all three. Docker Compose reads this file to expand the `${...}`
references in compose.yml, and its parser treats an unquoted `#` as the start of a comment, so a
base64 secret can silently lose its tail and leave you with a database password that is wrong in
a way nothing reports.

```bash
umask 077
cat > /srv/leantime/.env <<EOF
DOMAIN_NAME=<DOMAIN>
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
LEAN_SESSION_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/leantime/.env
umask 022
ls -l /srv/leantime/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/leantime/.env` and carry on.
If the file already existed from an earlier attempt, this block has now overwritten all three
secrets, which is fine before the database exists and a problem afterwards: MySQL keeps the
password it was created with, so a changed `DB_PASSWORD` against an existing data directory
produces a connection error in the Leantime log rather than anything mentioning passwords.

Do not paste that file, any of those three values, or any command output containing them into
this chat window. Nothing in this install needs you to read a secret aloud to anybody, and the
chat path is the only one of the three where a secret can leave your machine by accident.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/leantime/compose.yml <<'EOF'
# Leantime · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install .... https://docs.leantime.io/installation/docker
#   variable reference  https://github.com/Leantime/docker-leantime/blob/master/sample.env
#   backup & restore .. https://docs.leantime.io/installation/backup-restore
#
# Two services: Leantime's nginx-and-PHP-FPM image and the MySQL holding every
# project, task, goal and comment. Upstream keeps its data in named volumes;
# this file binds the two userfiles directories the backup page asks you to
# keep under /srv/leantime, and leaves MySQL on a directory the image chowns
# for itself. No plugin mount: upstream asks for one only if you install
# marketplace plugins, and this install does not. The app image runs as
# www-data, uid 1000, so those two are created owned by 1000. Digests read
# 2026-08-07; both images have arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  leantime_db:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: leantime-db
    restart: unless-stopped
    command: --character-set-server=UTF8MB4 --collation-server=UTF8MB4_unicode_ci
    environment:
      MYSQL_DATABASE: leantime
      MYSQL_USER: leantime
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - /srv/leantime/mysql:/var/lib/mysql
    healthcheck:
      # Runs inside the container, where that value already is an env var.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u leantime -p$$MYSQL_PASSWORD --silent"]
      start_period: 30s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  leantime:
    image: leantime/leantime:3.9.8@sha256:6150dd3e8a1e17f1ead8d462d31e26177fe906ce3602dbbbf6af5417ef809de3
    container_name: leantime
    restart: unless-stopped
    # Both of these come from upstream's compose file for this service.
    security_opt:
      - no-new-privileges:true
    cap_add:
      - CAP_CHOWN
      - CAP_SETGID
      - CAP_SETUID
    environment:
      LEAN_DB_HOST: leantime_db
      LEAN_DB_PORT: "3306"
      LEAN_DB_DATABASE: leantime
      LEAN_DB_USER: leantime
      LEAN_DB_PASSWORD: ${DB_PASSWORD}
      # Salts every session. Change it later and everyone is signed out.
      LEAN_SESSION_PASSWORD: ${LEAN_SESSION_PASSWORD}
      # Caddy terminates TLS in front, so the base URL carries its scheme.
      # Upstream needs this set for proxy installs; without it /install loops.
      LEAN_APP_URL: https://${DOMAIN_NAME}
      # true because Caddy serves this over https.
      LEAN_SESSION_SECURE: "true"
      LEAN_DEFAULT_TIMEZONE: UTC
    volumes:
      - /srv/leantime/userfiles:/var/www/html/userfiles
      - /srv/leantime/public-userfiles:/var/www/html/public/userfiles
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8163.
      - "127.0.0.1:8163:8080"
    depends_on:
      leantime_db:
        condition: service_healthy
EOF
cd /srv/leantime && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/leantime/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/leantime/compose.yml` and paste again in one go. A warning about `DOMAIN_NAME` being
unset means the first line of your .env still says `<DOMAIN>`.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-leantime
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Leantime · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.leantime.io/installation/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also DOMAIN_NAME in .env, where it becomes LEAN_APP_URL: keep them identical.

<DOMAIN> {
	# The interface is HTML, JavaScript and JSON, and compresses well.
	encode zstd gzip

	# The image's own nginx already sends X-Frame-Options, a CSP and versions of
	# the three below. Caddy's header directive replaces rather than appends, so
	# a browser sees one of each and the two not named here pass through.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8163 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8163
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-leantime /etc/caddy/Caddyfile`, reload,
and paste again. The usual cause is a `<DOMAIN>` you replaced in one place and not the other, so
the file now has a site block with an angle bracket in its name. Caddy requests the certificate
on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8163` or `3306`.

If you do not: delete anything for `8163` or `3306` with `sudo ufw delete allow 8163`. 8163 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has no
host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer the
ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

MySQL initialises its data directory first, and the application container does not start until
that database reports healthy, so the first minute or so answers `502` through Caddy. That is
expected, not a fault.

```bash
cd /srv/leantime
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthCheck.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthCheck.php
curl -sS https://<DOMAIN>/install | grep -c 'This script will set up your database' || true
```

You should see, in order: the loop climbing through `502` and reaching `200`, then the word `Ok`
on its own line, then `1`.

If you do not: a `502` that never clears means the database never reported healthy, so run
`docker compose logs --tail 20 leantime_db` first and `docker compose logs --tail 40 leantime`
second. A `0` where you wanted `1`, alongside a `200`, means Leantime answered and redirected you
somewhere else, which is `LEAN_APP_URL` in step 3 disagreeing with the hostname in step 5. Check
both with `grep DOMAIN_NAME /srv/leantime/.env` and `grep -n 'reverse_proxy' /etc/caddy/Caddyfile`.
A running container is not success; that `1` is.

Now open https://<DOMAIN> in a browser. It redirects to https://<DOMAIN>/install, which shows the
heading `Installation` over the line
`This script will set up your database and create an administrator account`, then boxes for
`Email`, `First name`, `Last name` and `Company Name`, and an `Install` button. Fill it in and
press `Install`. Leantime hands you a `Setting Account Details` screen next, where you choose the
password for that account: upstream wants at least 8 characters with an uppercase, a lowercase, a
number and a symbol. Put it in your password manager before you go on, because nothing on this
server can mail it back to you.

There is no default account and no default password anywhere in this install. The account you
created is the only one that exists.

Once you are signed in, prove the installer closed behind you:

```bash
curl -sS https://<DOMAIN>/install | grep -c 'This script will set up your database' || true
curl -sSL https://<DOMAIN>/ | grep -c '<label for="password">Password</label>' || true
```

You should see: `0`, then `1`.

If you do not: that `0` is the security check in this step. Leantime stops serving the installer
once the user table exists, so a `1` means no account was created and the install form is still
open on a public hostname. Go back to https://<DOMAIN>/install and finish it before you do
anything else. The `1` from the second command is the login form now answering at the root.

## 8. First backup and restore

Two artifacts. The database holds every project, task, goal, wiki page and comment. The file
archive holds the uploads and the three files that rebuild the service around them.

```bash
cd /srv/leantime
docker compose exec -T leantime_db sh -c 'mysqldump --single-transaction --no-tablespaces -u leantime -p"$MYSQL_PASSWORD" leantime' | gzip > /srv/leantime/backups/leantime-db-$(date +%F).sql.gz
sudo tar -czf /srv/leantime/backups/leantime-files-$(date +%F).tar.gz -C /srv/leantime compose.yml .env userfiles public-userfiles -C /etc/caddy Caddyfile
ls -lh /srv/leantime/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mysqldump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.
`Access denied; you need the PROCESS privilege` means `--no-tablespaces` went missing: the
`leantime` user is not a superuser and the dump needs that flag.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/leantime
scp vps:/srv/leantime/backups/* ~/backups/leantime/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/leantime/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty project list:

```bash
cd /srv/leantime
docker compose down
sudo rm -rf /srv/leantime/mysql
sudo install -d -m 700 /srv/leantime/mysql
docker compose up -d leantime_db
sleep 60
gunzip -c /srv/leantime/backups/leantime-db-$(date +%F).sql.gz | docker compose exec -T leantime_db sh -c 'mysql -u leantime -p"$MYSQL_PASSWORD" leantime'
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/healthCheck.php
```

You should see: no output from the `gunzip` line, then `Ok` from the last command, then your own
account still signing in at https://<DOMAIN>.

If you do not: `ERROR 1045 (28000): Access denied` means the database container had not finished
initialising, so wait another minute and run the `gunzip` line again. Understand the order before
you ever do this for real: .env has to be back on disk before MySQL starts, because MySQL takes
its passwords from that file the moment it initialises an empty data directory. The full restore
from a bare server is untar the file archive into /srv/leantime, then the five commands above.
`LEAN_SESSION_PASSWORD` lives in .env and nowhere else, so a dump restored without that file
signs everybody out.

## 9. Updating later

New versions are listed at https://github.com/Leantime/leantime/releases. Leantime ships several
in a busy month and each migrates its own schema on the way up, so take both backup artifacts
first, then edit the `image:` line in /srv/leantime/compose.yml to the new tag and its digest.

```bash
cd /srv/leantime
docker compose pull
docker compose up -d
docker compose logs --tail 30 leantime
```

You should see: the container starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. If a version
wants a schema change it serves `/install/update` instead of the application, and you press that
page's button once; that is normal on a minor bump and it is why the backup comes first. Re-run
the health check from step 7 before you call the update done.

## 10. What will probably go wrong

The first two minutes look like a broken reverse proxy. Compose holds the app container back
until MySQL reports healthy, MySQL is building its data directory from scratch, and until both
finish Caddy has nothing on 8163 to talk to, so every request returns `502 Bad Gateway`. I read
that as a Caddyfile mistake and restored /etc/caddy/Caddyfile from my own copy twice before the
health loop caught up on round nine. Let step 7's loop run all forty rounds; while
`docker compose ps` still shows `leantime-db` as `starting`, that `502` is the design working.

## 11. Out of scope

- Do not configure SMTP or set any `LEAN_EMAIL_` variable. Leantime runs with mail off, and the
  cost is real: invitations and notifications go nowhere, so you hand new people their
  credentials yourself.
- Do not enable LDAP or OIDC. Both need an identity provider this install does not have, and both
  change how the account from step 7 signs in.
- Do not install plugins from the Leantime marketplace. Some are paid extensions of this same
  install, a broken one takes the app down, and no volume is mounted to keep them.
- Do not set `LEAN_USE_S3`. Uploads belong on the two mounted directories step 8 backs up.
