This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Mixpost Lite 2.6.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record
already points at the box.

Read this before step 1. Two facts shape the whole install. `<DOMAIN>` becomes `APP_URL` and
the host inside every OAuth callback URL you register at X and at Meta, so changing it later
means editing each of those developer apps by hand. And the container ships a standing
default account, `admin@example.com` with a password printed in upstream's own install
guide, recreated on any start where that row is missing. Step 7 replaces the password and
proves the published one no longer works; do not stop before it.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a
hostname that does not resolve. On memory, 2048 MB is the floor for three containers with
MySQL among them; upstream's troubleshooting page asks for 4 GB, aimed mostly at its
Enterprise edition, and video is the spike, because the image bundles ffmpeg and converts
uploads itself. All three images publish amd64 and arm64.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mixpost /srv/mixpost/backups
sudo install -d -m 750 /srv/mixpost/storage /srv/mixpost/logs
sudo install -d -m 700 /srv/mixpost/mysql /srv/mixpost/redis
ls -la /srv/mixpost
```

You should see: five directories. `backups` owned by you, `storage` and `logs` owned by
root at `drwxr-x---`, and `mysql` and `redis` at `drwx------` owned by root.

If you do not: leave the last four owned by root on purpose. MySQL and Redis chown their own
data directory the first time they start, and one you have already chowned to yourself makes
MySQL refuse to initialise. `storage` and `logs` are chowned to www-data by the Mixpost
container itself at every start, because that container runs a `chown -R` over its whole
application directory before anything else.

## 3. Secrets

Four secrets, all generated here on the server, straight into a file only you can read: the
Laravel application key, the database password, the MySQL root password, and the password
step 7 will put on the account the container creates.

```bash
umask 077
cat > /srv/mixpost/.env <<EOF
MIXPOST_DOMAIN=<DOMAIN>
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/mixpost/.env
umask 022
ls -l /srv/mixpost/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>`
on the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens
if you pasted the lines separately in different shells. Run `chmod 600 /srv/mixpost/.env`
and carry on. If the file already existed from an earlier attempt, this block has now
overwritten all four values, which is fine before MySQL exists and a problem afterwards: a
MySQL volume keeps the password it was created with, so a changed password against an
existing volume shows up as an authentication failure in the Mixpost log rather than as
anything about passwords.

Do not paste that file, any of those four values, or any command output containing them into
this chat window. This is the one rule the agent path never has to think about and this path
does: the values are on your server, and a chat window is somebody else's computer.

`APP_KEY` is the one to understand. It is a Laravel key for AES-256-CBC, 32 random bytes in
base64, and every provider secret and social token Mixpost stores is encrypted with it.
Upstream offers a web page that generates one; this generates its own, because a key fetched
from somebody else's website is a key somebody else saw. Compose reads this file from the
working directory, so run every command from here on with /srv/mixpost as your working
directory.

## 4. compose.yml and the trusted-proxy file

Two files. Paste the config file first, whole, including the last two lines. It has to exist
before the first `docker compose up`, because a bind mount whose host path is missing makes
Docker create a directory at that path instead.

```bash
cat > /srv/mixpost/trustedproxy.php <<'EOF'
<?php
// Mixpost Lite · trusted proxies. Authored by caniselfhostit from the image's
// vendor/laravel/framework/src/Illuminate/Http/Middleware/TrustProxies.php,
// which trusts nothing unless the application sets a proxy list, which this
// image does not, or config('trustedproxy.proxies') exists, which is this
// file. Without it Laravel reads Caddy's plain http connection and hands the
// browser http:// URLs on an https page, the Ziggy route table the dashboard
// drives itself from included, and browsers block those.
//
// '*' trusts the address that connected, which behind a loopback-only
// published port is only ever the Caddy on this host.

return [
    'proxies' => '*',
];
EOF
chmod 644 /srv/mixpost/trustedproxy.php
```

You should see: no output at all, and `ls -l /srv/mixpost/trustedproxy.php` showing a file
of a few hundred bytes.

If you do not: `bash: !: event not found` means your shell tried to expand something inside
the heredoc. Paste the block again in one go; the `<<'EOF'` quoting is what stops that, and
it only works when the whole block arrives together.

Now the three services. Paste the whole block at once, including the last two lines.

```bash
cat > /srv/mixpost/compose.yml <<'EOF'
# Mixpost Lite · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   docker install ...... https://docs.mixpost.app/lite/installation/docker
#   variable reference .. https://docs.mixpost.app/lite/configuration/environment-variables
#   troubleshooting ..... https://docs.mixpost.app/troubleshooting
#
# Three services. The Mixpost image is one Ubuntu container running nginx,
# PHP-FPM, the Horizon queue worker and cron under supervisord; MySQL holds the
# posts, accounts and encrypted provider credentials; Redis is what Horizon
# queues on. Upstream's compose file names mysql/mysql-server, a Docker Hub
# repository whose newest tag is 8.0.32 from January 2023, so this pins the
# official mysql image on the 8.4 LTS line, and every image carries a tag and
# a digest. Digests read 2026-08-14, all amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: mixpost

services:
  mysql:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    restart: unless-stopped
    environment:
      # The image will not initialise without a root variable; nothing here
      # connects as root.
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: mixpost
      MYSQL_USER: mixpost
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/mixpost/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", 'mysqladmin ping -h 127.0.0.1 -u "$$MYSQL_USER" -p"$$MYSQL_PASSWORD" --silent']
      interval: 10s
      retries: 18
    # No `ports:` at all: 3306 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /srv/mixpost/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  mixpost:
    image: inovector/mixpost:v2.6.0@sha256:90cf94cec73dcaf87989d30b0de7a84b0625ff06797ba61c8ecb54e8fe1e10c4
    restart: unless-stopped
    environment:
      APP_NAME: Mixpost
      # Every stored provider secret and social token is encrypted with this.
      APP_KEY: ${APP_KEY}
      APP_DEBUG: "false"
      APP_URL: "https://${MIXPOST_DOMAIN}"
      DB_HOST: mysql
      DB_PORT: "3306"
      DB_DATABASE: mixpost
      DB_USERNAME: mixpost
      DB_PASSWORD: ${DB_PASSWORD}
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      MIXPOST_DISK: public
    volumes:
      # The media library, on the "public" disk, then the application log.
      - /srv/mixpost/storage:/var/www/html/storage/app
      - /srv/mixpost/logs:/var/www/html/storage/logs
      # Why this third file exists is written inside it. It has to exist on the
      # host first, or Docker creates a directory at that path.
      - /srv/mixpost/trustedproxy.php:/var/www/html/config/trustedproxy.php
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8197.
      - "127.0.0.1:8197:80"
    # If Facebook connections later time out, upstream's troubleshooting page
    # says Meta refuses the container over IPv6: add a `sysctls:` entry here,
    # net.ipv6.conf.all.disable_ipv6=1.
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/mixpost && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `variable is not set` means step 3 did not write .env into /srv/mixpost, or
you are in a different directory. `services must be a mapping` means the indentation was
lost between the page and your terminal: run `rm /srv/mixpost/compose.yml` and paste again
in one go. Upstream's own compose file names `mysql/mysql-server`, a Docker Hub repository
whose newest tag is 8.0.32 from January 2023, and a floating tag for every image. This one
pins the official mysql image on the 8.4 LTS line and gives every image a digest.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-mixpost
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Mixpost Lite · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.mixpost.app/lite/installation/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. It is also
# MIXPOST_DOMAIN in .env and the host inside every OAuth callback URL you
# register at X and at Meta.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting an account bounces out to a provider.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8197 is the loopback port compose publishes here, not a container port,
	# and not open in the firewall. Caddy sets X-Forwarded-Proto on the way
	# through, and trustedproxy.php is what tells the app to believe it.
	reverse_proxy 127.0.0.1:8197
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-mixpost /etc/caddy/Caddyfile`,
reload, and paste again. Caddy issues the certificate on the first request and renews it on
its own. It also terminates TLS and speaks plain http to the container, which is the whole
reason step 4 wrote trustedproxy.php: without that file the application believes the request
arrived over http and hands your browser http:// links on an https page.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8197`, `3306` or `6379`.

If you do not: delete anything for those three with, for example,
`sudo ufw delete allow 8197`. 8197 is bound to 127.0.0.1 by the compose file, and MySQL and
Redis publish no host port at all, so there is nothing for a firewall rule to apply to.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first start is the slow one. MySQL initialises its data directory, then the Mixpost
container waits for it and runs every Laravel migration, so the loop below is allowed seven
minutes.

```bash
cd /srv/mixpost
docker compose pull
docker compose up -d
for i in $(seq 1 42); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8197/mixpost/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/mixpost/login | grep -c 'Log in'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/horizon
curl -sS -o /dev/null -w '%{redirect_url}\n' https://<DOMAIN>/mixpost
```

You should see, in order: the loop climbing through `502` and ending on `200`, then `1`,
then `403`, then `https://<DOMAIN>/mixpost/login`.

If you do not: a loop that never leaves `502` after seven minutes is usually MySQL. Run
`docker compose logs --tail 20 mysql` first, then `docker compose logs --tail 40 mixpost`.
A curl error rather than a number on the three https lines is a different problem: that is
Caddy still issuing a certificate for an A record you created minutes ago, and it clears on
its own within a minute or two.
The `403` is Laravel Horizon, the queue dashboard this image mounts at /horizon: it refuses
anyone who is not signed in, and a `200` there would mean your queue dashboard is public.
The last line is the one worth reading twice. It must start `https`. An `http://` target
means trustedproxy.php did not load, and the dashboard will break in a browser even though
curl looks content, because the page will try to call itself over http from an https origin
and the browser will block it.

Now close the door the image leaves open. `start.sh` inside the container runs
`mixpost-auth:create --admin` on every start where no row with the address
`admin@example.com` exists, and that command sets the password upstream prints in its own
install guide. The next block signs in with it once over loopback, replaces it with the one
step 3 generated, and then proves the published one is dead.

```bash
cd /srv/mixpost
umask 077
B=http://127.0.0.1:8197
tok() { sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p'; }
printf '%s' "$(grep '^ADMIN_PASSWORD' .env | cut -d= -f2-)" > .newpw
rm -f .jar
T=$(curl -sS -c .jar $B/mixpost/login | tok)
curl -sS -b .jar -c .jar -o /dev/null -w 'seeded %{redirect_url}\n' -X POST $B/mixpost/login --data-urlencode "_token=$T" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme'
T=$(curl -sS -b .jar -c .jar $B/mixpost/profile | tok)
curl -sS -b .jar -c .jar -o /dev/null -w 'rotate %{http_code}\n' -X PUT $B/mixpost/profile/password --data-urlencode "_token=$T" --data-urlencode 'current_password=changeme' --data-urlencode 'password@.newpw' --data-urlencode 'password_confirmation@.newpw'
rm -f .jar
T=$(curl -sS -c .jar $B/mixpost/login | tok)
curl -sS -b .jar -c .jar -o /dev/null -w 'published %{redirect_url}\n' -X POST $B/mixpost/login --data-urlencode "_token=$T" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme'
rm -f .jar .newpw
umask 022
```

You should see three lines: `seeded http://127.0.0.1:8197/mixpost`, then `rotate 302`, then
`published http://127.0.0.1:8197/mixpost/login`.

If you do not: the first line is the control. It says the published password worked, which
is the door you are closing; if it already ends in `/mixpost/login`, either the container
has not finished starting or somebody has been here before you, and you should stop and read
`docker compose logs --tail 40 mixpost`. The third line is the closure: the same credential
now bounces back to the sign-in page. If the third still ends in `/mixpost`, the rotation
did not take. Do not carry on. Open https://<DOMAIN>/mixpost/login in a browser, sign in as
`admin@example.com` with the published password, and change it under Profile before you do
anything else with this box.

Now sign in yourself. Read your password with `sudo grep ADMIN_PASSWORD /srv/mixpost/.env`,
put it in your password manager, and open https://<DOMAIN>/mixpost/login. The first screen
shows `Email` and `Password` fields under the Mixpost logo, with a `Log in` button. There is
no reset link and no mail configured, so that password manager entry is the only copy you
have.

One thing not to change: the account's email address. The container recreates
`admin@example.com` with upstream's published password on any start where that address is
missing from the users table, so renaming the account quietly reopens the door at the next
restart. Change the display name and the password as often as you like; leave the address
alone.

## 8. First backup and restore

Two artifacts. The dump holds the accounts, the posts, the calendar and the encrypted
provider credentials. The archive holds the files that rebuild the service around it, media
library and `.env` included. `.env` is the load-bearing half: `APP_KEY` is what those
credentials are encrypted with, so a dump restored without it is a table of unreadable
tokens.

```bash
cd /srv/mixpost
docker compose exec -T mysql sh -c 'exec mysqldump -u mixpost -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces mixpost' | gzip > /srv/mixpost/backups/mixpost-db-$(date +%F).sql.gz
sudo tar -czf /srv/mixpost/backups/mixpost-files-$(date +%F).tar.gz -C /srv/mixpost compose.yml .env trustedproxy.php storage logs -C /etc/caddy Caddyfile
ls -lh /srv/mixpost/backups/
```

You should see: two files, both non-empty. Nothing goes offline, because
`--single-transaction` snapshots InnoDB consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mysqldump`
failed and the shell created the file anyway. Run the dump line without `| gzip` to read the
error. `Access denied; you need the PROCESS privilege` means `--no-tablespaces` was dropped:
the application user does not have that privilege and MySQL 8 refuses the dump without the
flag.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/mixpost
scp vps:/srv/mixpost/backups/* ~/backups/mixpost/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/mixpost/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is one empty account:

```bash
cd /srv/mixpost
docker compose down
sudo rm -rf /srv/mixpost/mysql
sudo install -d -m 700 /srv/mixpost/mysql
docker compose up -d mysql
sleep 60
gunzip -c /srv/mixpost/backups/mixpost-db-$(date +%F).sql.gz | docker compose exec -T mysql sh -c 'exec mysql -u mixpost -p"$MYSQL_PASSWORD" mixpost'
docker compose up -d
sleep 90
curl -sS -o /dev/null -w '%{redirect_url}\n' https://<DOMAIN>/mixpost
```

You should see: no output from the `gunzip` pipe, then `https://<DOMAIN>/mixpost/login` from
the last command, and your rotated password still works in the browser.

If you do not: `Access denied for user 'mixpost'` means the container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what this protects:
the posts, the calendar and the connected accounts come back from that dump, and a connected
account comes back working only if the network's token has not expired meanwhile.

## 9. Updating later

Releases are listed at https://github.com/inovector/mixpost/releases and the matching image
tags at https://hub.docker.com/r/inovector/mixpost/tags. Read both: that repository is the
Laravel package, and the image is that package installed into an application skeleton, so a
version exists on Docker Hub only once upstream has built it. 2.6.0, published 2026-03-16,
is the newest of either as of 2026-08-14, and that is also the date of the last commit on
the repository's main branch. Take both backup artifacts first, then edit the `image:` line
in /srv/mixpost/compose.yml to the new tag and its digest.

```bash
cd /srv/mixpost
docker compose pull
docker compose up -d
docker compose logs --tail 30 mixpost
```

You should see: migration output, then the Mixpost banner, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
the four checks from step 7 before you call the update done. Two things to expect on any
update: sessions live inside the container and are not mounted, so everyone signed in gets
signed out, and MySQL stays on the 8.4 LTS line on purpose, because the innovation releases
change behaviour every quarter and a database under a scheduler is the wrong place for that.

## 10. What will probably go wrong

The minutes between `docker compose up -d` and the rotation later in step 7 are the
dangerous part of this install, and they are easy to walk past. For that window your box is
answering on a public hostname with a username and password printed in upstream's install
guide, and a hostname minutes old is not private: it enters a certificate transparency log
the moment Caddy asks for the certificate, and people read those logs for a living. Run step
7 straight through, in one sitting, before you go and make coffee. Then leave the account's
email address alone, however tempting a rename is: I read `start.sh` inside the image, and
it recreates `admin@example.com` with that same published password on any start where the
row is gone.

## 11. Out of scope

- Do not connect a social account yet. Mixpost Lite publishes to Facebook Pages, X and
  Mastodon. The first two need an app registered in that company's own developer portal,
  with a callback under `https://<DOMAIN>/mixpost/callback/`, and its id and secret entered
  under Settings, Services inside Mixpost. Some of those registrations are reviewed by a
  person at the other company and take days. Mastodon is the exception: Mixpost registers
  that application itself against the instance you name.
- Do not change the account's email address, and do not add a second user. There is one
  account, `admin@example.com`, and step 10 says why that matters.
- Do not configure SMTP or set any `MAIL_` variable. Nothing in this install sends mail, and
  the account password lives in .env instead of behind a reset link.
- Do not set `MIXPOST_DISK` to s3 or add any `AWS_` variable. The media library is a
  directory on this box and step 8 backs it up.
