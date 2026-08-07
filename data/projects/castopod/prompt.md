You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Castopod 1.15.5 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say this when you ask, because it is the one decision here that cannot be undone: `<DOMAIN>`
becomes `CP_BASEURL`, the address inside their feed and inside every audio URL that feed hands
to Apple Podcasts, Spotify and every app between. Moving hostname later means keeping the old
one alive as a redirect for as long as anyone still has the show subscribed. Its A record must
already point at this server.

Castopod, MariaDB and Redis need 2048 MB of RAM available and 10 GB free on /srv, and audio is
what eats the disk. All three images publish amd64 and arm64. Measure all five:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
timedatectl show -p NTPSynchronized --value
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name nobody resolves. If `timedatectl` prints `no`, stop: upstream requires an
NTP-synced clock, because fediverse servers reject signed requests that have drifted.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/castopod /srv/castopod/backups
sudo install -d -m 700 /srv/castopod/mariadb
ls -la /srv/castopod
```

Assert: `backups` owned by the login user, `mariadb` at mode `700` owned by root. Leave that one
alone; the MariaDB image chowns its own data directory and refuses one somebody claimed first.
Audio gets no directory here: step 4 keeps it in a named volume the image can own.

## 3. Secrets

Four secrets, all generated here: the database password, the MariaDB root password, the Redis
password and the analytics salt. Print none, keep them out of your summary and out of every log
line you quote back.

```bash
umask 077
cat > /srv/castopod/.env <<EOF
CP_BASEURL=https://<DOMAIN>/
DB_PASSWORD=$(openssl rand -hex 32)
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
CP_ANALYTICS_SALT=$(openssl rand -hex 32)
EOF
chmod 600 /srv/castopod/.env
umask 022
ls -l /srv/castopod/.env
```

Assert: mode `-rw-------` and the login user's name twice. The salt is 64 characters, the length
upstream's generator produces, and it is not an encryption key: Castopod hashes it with the
date, the listener's IP and their user agent so one person downloading twice counts once, and
that hash expires at midnight. Changing it costs a day of accuracy, not history.

## 4. compose.yml

```bash
cat > /srv/castopod/compose.yml <<'EOF'
# Castopod · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   official image ... https://docs.castopod.org/getting-started/docker.html
#   env bootstrap .... https://github.com/ad-aures/castopod/blob/v1.15.5/docker/production/s6-rc.d/bootstrap/prepare-environment.sh
#   mariadb support .. https://mariadb.org/about/maintenance-policy/
#
# Castopod is one image carrying FrankenPHP, Caddy and its own per-minute cron.
# MariaDB holds the shows, episodes and download counts; Redis holds the daily
# hashes that stop one listener being counted twice.
#
# Upstream's example names mariadb:12.1, a rolling release whose image has not
# been rebuilt since February 2026; this uses the 11.8 LTS line, supported to
# June 2028. Media is a named volume: the image ships /app/public/media owned
# by its www-data user at mode 770, which a host directory cannot reproduce.
# Only 8080 is published, the host's Caddy terminates TLS. Digests read
# 2026-08-06; all three do arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: castopod-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: castopod
      MARIADB_USER: castopod
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - /srv/castopod/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 stays inside the compose network.

  cache:
    image: redis:8.4.5-alpine@sha256:bd4a0d37e7cd830117ffec9329052b4a1887afa060c265e1768f82b177ff6f43
    container_name: castopod-redis
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      # Snapshots land here; those hashes expire at midnight anyway.
      - castopod-cache:/data
    # No `ports:` at all: 6379 stays inside the compose network.

  castopod:
    image: castopod/castopod:1.15.5@sha256:4e4f0440520f45257bfeac7be4347defd20048b4efef8f53d73ec9ed3a4f7966
    container_name: castopod
    restart: unless-stopped
    environment:
      # The bootstrap inside the image refuses to start without these two.
      CP_BASEURL: ${CP_BASEURL}
      CP_ANALYTICS_SALT: ${CP_ANALYTICS_SALT}
      CP_DATABASE_HOSTNAME: db
      CP_DATABASE_NAME: castopod
      CP_DATABASE_USERNAME: castopod
      CP_DATABASE_PASSWORD: ${DB_PASSWORD}
      # A Redis host switches the cache handler and forces a password.
      CP_REDIS_HOST: cache
      CP_REDIS_PASSWORD: ${REDIS_PASSWORD}
    volumes:
      - castopod-media:/app/public/media
    healthcheck:
      # Without the header this is answered by a redirect rather than the
      # check itself, and a dead database still reports healthy.
      test: ["CMD", "curl", "-fsS", "-H", "X-Forwarded-Proto: https", "-o", "/dev/null", "http://127.0.0.1:8080/health"]
      start_period: 60s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8135.
      - "127.0.0.1:8135:8080"
    depends_on:
      db:
        condition: service_healthy
      cache:
        condition: service_started

volumes:
  castopod-media:
  castopod-cache:
EOF
cd /srv/castopod && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No default credential appears in this file, and the bootstrap
exits with an error rather than starting without `CP_BASEURL` or `CP_ANALYTICS_SALT`.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-castopod
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Castopod · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.castopod.org/getting-started/docker.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also CP_BASEURL in .env: the address
# inside your feed and inside every audio URL it hands a podcast app.

<DOMAIN> {
	# No `encode`: the bulk of this site is compressed audio. There is
	# deliberately no X-Frame-Options either, because Castopod ships an
	# embeddable player and framing it elsewhere is the point of it.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8135 is the loopback port compose publishes here, not a container port
	# and not open in the firewall. Caddy sets X-Forwarded-Proto itself, the
	# only thing telling Castopod this arrived over TLS.
	reverse_proxy 127.0.0.1:8135
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-castopod, reload,
and report what it objected to. Caddy requests the certificate on the first request and renews
it on its own; nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3, which matters here because listeners pull large files. 8135 is bound to 127.0.0.1, and
compose publishes no host port for 3306 or 6379. Assert: `Status: active`, rules for 80, 443/tcp
and 443/udp, nothing for 8135, 3306 or 6379.

## 7. Start and verify

On first start the container writes its config, runs every migration, then starts the web server
and its cron. Read step 10 before you read that log: never quote it back unfiltered.

```bash
cd /srv/castopod
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/cp-install
curl -sS https://<DOMAIN>/cp-install | grep -c 'Create your Super Admin account'
```

Assert all four, printing what you received. The loop ends on `200`. The health body contains
`"code":200`, which upstream returns only when the database, the cache and the media directory
all answered. The third prints `200`, the fourth `1`. If any miss, stop, run the filtered log
command from step 10 and `docker compose logs --tail 20 db`, and name the likely step: a
database never reporting healthy is step 2, a lasting `502` is step 5, `CP_ANALYTICS_SALT is
empty` is step 3. A running container is not success.

The first screen at https://<DOMAIN>/cp-install shows `4/4` beside the heading
`Create your Super Admin account`, with Username, Email and Password fields.

STOP: tell the user to open https://<DOMAIN>/cp-install, create their account with a password of
at least 8 characters that is not a dictionary word, put it in their password manager, and wait.
Do not continue until they confirm they are signed in. Self-registration is off in this release,
so that account is the only way in, and there is no reset path until mail is configured.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/cp-install
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from cp_users where is_owner = 1" "$MARIADB_DATABASE"'
```

Assert both. The first prints `404`: once an owner exists the installer refuses everyone else
who finds that URL, and that is the security assert here. The second prints `1`, one owner, made
in a browser rather than seeded from a file.

## 8. First backup and restore

Three artifacts: a dump with the shows, episodes and download history, the audio itself, and
the config archive that rebuilds the service around them.

```bash
cd /srv/castopod
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/castopod/backups/castopod-db-$(date +%F).sql.gz
docker compose exec -T castopod tar -C /app/public/media -czf - . > /srv/castopod/backups/castopod-media-$(date +%F).tar.gz
sudo tar -czf /srv/castopod/backups/castopod-config-$(date +%F).tar.gz -C /srv/castopod compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/castopod/backups/
```

Assert: all three exist, all three non-empty, all three sizes printed. Nothing is stopped;
`mariadb-dump` snapshots a running database consistently. Tell the user the media archive is the
one that grows: kilobytes today, their largest file after a year of episodes.

A backup on the same disk is not a backup. Run this from the user's machine, not the server:

```bash
mkdir -p ~/backups/castopod
scp vps:/srv/castopod/backups/* ~/backups/castopod/
```

To restore: `docker compose down`, `sudo rm -rf /srv/castopod/mariadb`, recreate it as in step 2,
untar the config archive into /srv/castopod so `.env` is back first, `docker compose up -d db`,
wait about 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
`docker compose up -d`, then the audio with
`docker compose exec -T castopod tar -C /app/public/media -xzf - < backups/castopod-media-<date>.tar.gz`.
`.env` comes back first because MariaDB reads its password from it the moment it initialises an
empty directory. The stakes: feed URLs in other people's apps outlive this server, and a restore
without the audio leaves those apps pointing at nothing.

## 9. Updating later

New versions are at https://code.castopod.org/adaures/castopod/-/releases, mirrored at
https://github.com/ad-aures/castopod/tags. Take all three backups first, then edit the castopod
image line in /srv/castopod/compose.yml to the new tag and digest:

```bash
cd /srv/castopod
docker compose pull
docker compose up -d
docker compose logs --tail 40 castopod | grep -viE 'password|salt'
```

The container migrates on every start, so a version bump needs no separate command. Watch that
log until it settles, then re-run step 7's health check and confirm /cp-install still gives
`404`.

## 10. What will probably go wrong

The first thing `docker compose logs castopod` prints is your entire configuration in plain text,
including the database password, the Redis password and the analytics salt. I pasted that log
into a chat window before I noticed and had to regenerate all three. The container rewrites its
config on every start and prints it under `INFO: Using config:`; no setting turns that off. Pipe
it through the filter every time:
`docker compose logs --tail 40 castopod | grep -viE 'password|salt'`.

## 11. Out of scope

- Do not configure SMTP. Publishing works with no mail; mail buys password reset and inviting a
  second contributor, and both are worth a separate evening.
- Do not change `CP_ADMIN_GATEWAY` or `CP_AUTH_GATEWAY`. Upstream suggests renaming those routes,
  and doing it here would make every admin URL in this prompt wrong.
- Do not set `CP_MEDIA_FILE_MANAGER` or any `CP_MEDIA_S3_` variable. Object storage for audio is
  a real option and a different install with a different bill.
- Do not add a cron job on the host. The image runs `spark tasks:run` itself every minute, which
  imports feeds and pushes episodes to the fediverse.
