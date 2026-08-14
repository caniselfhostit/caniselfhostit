You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Mixpost Lite 2.6.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. It becomes `APP_URL` and the host inside every OAuth callback URL they register at X
and at Meta, so moving it later means editing each of those apps by hand. Its A record must
already point at this server.

Mixpost Lite needs 2048 MB of RAM available and 10 GB free on /srv. Upstream's
troubleshooting page asks for 4 GB, aimed mostly at its Enterprise edition; three containers
clear 2 GB, and video is the spike, because the image bundles ffmpeg. All three images are
amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop.
If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mixpost /srv/mixpost/backups
sudo install -d -m 750 /srv/mixpost/storage /srv/mixpost/logs
sudo install -d -m 700 /srv/mixpost/mysql /srv/mixpost/redis
ls -la /srv/mixpost
```

Assert: five directories. `backups` owned by the login user; `mysql` and `redis` at mode
`700` owned by root, because both images chown their own data directory on first start and
one already chowned elsewhere makes MySQL refuse to initialise. `storage` and `logs` stay
root-owned too: the Mixpost container chowns its application directory to www-data at every
start, and these two sit inside it once mounted.

## 3. Secrets

Four, all generated here. Print none of them, and keep them out of your summary and every
log line.

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

Assert: mode `-rw-------`. `APP_KEY` is a Laravel key for AES-256-CBC, 32 random bytes in
base64, and it encrypts every stored provider secret and social token. Upstream offers a web
page that generates one; this makes its own, because a key from somebody else's website is a
key somebody else saw. `ADMIN_PASSWORD` reaches no container: step 7 sets it on the account
the image creates. Compose reads this file from the working directory, so run everything
from /srv/mixpost.

## 4. compose.yml and the trusted-proxy file

Two files. The config file first: a bind mount whose host path is missing makes Docker
create a directory instead.

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

Then the three services:

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

Assert: `compose OK` and nothing else. An unset-variable warning means step 3 did not write
.env into /srv/mixpost.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-mixpost, reload, and report what it objected to.

## 6. Firewall

Two ports open, both Caddy's, idempotent:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the way in, 443/udp is
HTTP/3. 8197 is on 127.0.0.1 and compose publishes no host port for MySQL or Redis. Assert:
`ufw status verbose` prints `Status: active`, those three rules, and nothing for 8197, 3306
or 6379.

## 7. Start and verify

MySQL initialises its data directory, then the Mixpost container waits for it and runs every
Laravel migration, so the first start is the slow one.

```bash
cd /srv/mixpost
docker compose pull
docker compose up -d
for i in $(seq 1 42); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8197/mixpost/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/mixpost/login | grep -c 'Log in'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/horizon
curl -sS -o /dev/null -w '%{redirect_url}\n' https://<DOMAIN>/mixpost
```

Assert all four, printing what you received. The loop ends on `200`. The grep prints `1`,
the sign-in button. `/horizon` prints `403`: the Laravel queue dashboard this image mounts
refuses anyone not signed in. The last prints `https://<DOMAIN>/mixpost/login`, and the
`https` is the point: an `http://` target means trustedproxy.php did not load, and the
dashboard will break in a browser though curl is content. On any miss, stop, run
`docker compose logs --tail 40 mixpost` and `docker compose logs --tail 20 mysql`, and name
the cause: a MySQL container stuck below healthy points at step 3, and a curl error instead
of a number on the two https lines is a certificate Caddy has not finished issuing for a
minutes-old A record.

Now close the door the image leaves open. `start.sh` in the container runs
`mixpost-auth:create --admin` on every start where no `admin@example.com` row exists, with
the password upstream prints in its install guide. Sign in with it once over loopback,
replace it, and prove the published one is dead:

```bash
cd /srv/mixpost
umask 077
B=http://127.0.0.1:8197
J=/srv/mixpost/.jar
N=/srv/mixpost/.newpw
tok() { sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p'; }
printf '%s' "$(grep '^ADMIN_PASSWORD' /srv/mixpost/.env | cut -d= -f2-)" > $N
rm -f $J
T=$(curl -sS -c $J $B/mixpost/login | tok)
curl -sS -b $J -c $J -o /dev/null -w 'seeded %{redirect_url}\n' -X POST $B/mixpost/login --data-urlencode "_token=$T" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme'
T=$(curl -sS -b $J -c $J $B/mixpost/profile | tok)
curl -sS -b $J -c $J -o /dev/null -w 'rotate %{http_code}\n' -X PUT $B/mixpost/profile/password --data-urlencode "_token=$T" --data-urlencode 'current_password=changeme' --data-urlencode "password@$N" --data-urlencode "password_confirmation@$N"
rm -f $J
T=$(curl -sS -c $J $B/mixpost/login | tok)
curl -sS -b $J -c $J -o /dev/null -w 'published %{redirect_url}\n' -X POST $B/mixpost/login --data-urlencode "_token=$T" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme'
rm -f $J $N
umask 022
```

Assert three printed lines. `seeded http://127.0.0.1:8197/mixpost` is the published password
working, the door being closed. `rotate 302`. `published
http://127.0.0.1:8197/mixpost/login` is that credential bounced back, which is the closure.
If the third still ends in `/mixpost`, stop and have the user change the password in the
browser at once. A running container is not success.

STOP: tell the user their sign-in is `admin@example.com` at https://<DOMAIN>/mixpost/login,
that the password is in /srv/mixpost/.env, read with
`sudo grep ADMIN_PASSWORD /srv/mixpost/.env`, and that it belongs in their password manager
now, because nothing here sends mail and there is no reset.
Do not continue until they confirm. Tell them not to change the email address on that
profile page: the container recreates `admin@example.com` with the published password
whenever it is missing.

## 8. First backup and restore

Two artifacts. The dump holds the accounts, posts, calendar and encrypted provider
credentials. The archive holds what rebuilds the service around it, and `.env` is its
load-bearing half: `APP_KEY` decrypts those credentials, so a dump restored without it is a
table of unreadable tokens.

```bash
cd /srv/mixpost
docker compose exec -T mysql sh -c 'exec mysqldump -u mixpost -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces mixpost' | gzip > /srv/mixpost/backups/mixpost-db-$(date +%F).sql.gz
sudo tar -czf /srv/mixpost/backups/mixpost-files-$(date +%F).tar.gz -C /srv/mixpost compose.yml .env trustedproxy.php storage logs -C /etc/caddy Caddyfile
ls -lh /srv/mixpost/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops, because
`--single-transaction` snapshots InnoDB consistently; `--no-tablespaces` is there because
the app user has no PROCESS privilege and MySQL 8 refuses the dump without it. A backup on
the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/mixpost
scp vps:/srv/mixpost/backups/* ~/backups/mixpost/
```

To restore: `docker compose down`, `sudo rm -rf /srv/mixpost/mysql`, recreate it as in step
2, untar the archive into /srv/mixpost so `.env` is back before anything starts,
`docker compose up -d mysql`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u mixpost -p"$MYSQL_PASSWORD" mixpost'`,
then `docker compose up -d`. A MySQL volume keeps the password it was created with, so
restore that `.env`.

## 9. Updating later

Releases are listed at https://github.com/inovector/mixpost/releases and the image tags at
https://hub.docker.com/r/inovector/mixpost/tags. Read both: the repository is the Laravel
package, the image is that package inside an application skeleton, so a version lands there
only once upstream builds it. 2.6.0 of 2026-03-16 is the newest of either as of 2026-08-14,
and the date of the last commit on main. Back up both artifacts, then edit the image line in
/srv/mixpost/compose.yml to the new tag and digest:

```bash
cd /srv/mixpost
docker compose pull
docker compose up -d
docker compose logs --tail 30 mixpost
```

The container runs `php artisan migrate --force` on the way up, so watch that log until it
settles, then re-run step 7's four checks. Sessions live inside the container, so an update
signs everyone out. MySQL stays on 8.4 LTS on purpose: the innovation releases change
behaviour quarterly, the wrong thing under a scheduler.

## 10. What will probably go wrong

The minutes between `docker compose up -d` and the rotation later in step 7 are the
dangerous part of this install, and they are easy to walk past. For that window the box
answers on a public hostname with a username and password printed in upstream's install
guide, and a hostname minutes old is not private: it enters a certificate transparency log
the moment Caddy asks for it, and people read those logs for a living. Run step 7 straight
through. Then leave the account's email address alone: I read `start.sh` in the image, and
it recreates `admin@example.com` with that password on any start where the row is gone.

## 11. Out of scope

- Do not connect a social account, and do not create developer apps for the user. Mixpost
  Lite publishes to Facebook Pages, X and Mastodon; the first two need an app registered in
  that company's own developer portal, with a callback under
  `https://<DOMAIN>/mixpost/callback/`, and its id and secret entered under Settings,
  Services. Some of those registrations are reviewed by a person and take days.
- Do not change the account's email address, and do not add a second user. There is one
  account, `admin@example.com`; step 10 says why.
- Do not configure SMTP or set any `MAIL_` variable. Nothing here sends mail.
- Do not set `MIXPOST_DISK` to s3 or add any `AWS_` variable. The media library is a
  directory on this box and step 8 backs it up.
