This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Castopod 1.15.5 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1, because it is the one decision here you cannot undo. `<DOMAIN>`
becomes `CP_BASEURL`, the address inside your RSS feed and inside every audio file URL that
feed hands to Apple Podcasts, Spotify and every app in between. Change it later and every app
that already has your show subscribed keeps asking the old name, so you are keeping that
hostname alive as a redirect for years. Pick the one you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
timedatectl show -p NTPSynchronized --value
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, `yes`,
and your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. A `no` from
`timedatectl` matters more here than on most installs: Castopod federates, and fediverse servers
reject signed requests whose clocks have drifted. Fix it with
`sudo timedatectl set-ntp true` before going on. The 10 GB floor is about audio; a weekly
hour-long show is roughly 60 MB an episode, so plan the disk for the year you intend to record,
not for today.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/castopod /srv/castopod/backups
sudo install -d -m 700 /srv/castopod/mariadb
ls -la /srv/castopod
```

You should see: `backups` owned by you, and `mariadb` at mode `drwx------` owned by root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. There is no directory here for your audio: step 4 keeps the media in a Docker
named volume, because the Castopod image ships /app/public/media owned by its own www-data user
at mode 770 and a fresh directory on the host would be root-owned and unwritable. Step 8 gets
the audio back out again.

## 3. Secrets

Four secrets: the database password, the MariaDB root password, the Redis password and the
analytics salt. All four are generated here, on the server, and all four go into a file only you
can read.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste, and keep the trailing slash.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/castopod/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
all four values, which is fine before the database exists and a problem afterwards: MariaDB
keeps the password it was created with, so a changed `DB_PASSWORD` on an existing directory
produces an authentication failure in the Castopod log rather than anything about passwords.

Do not paste that file, any of those four values, or any command output containing them into
this chat window. That matters more on this install than on most, because step 7 explains that
Castopod prints its whole configuration into its own container log on every start, so
`docker compose logs castopod` is a command whose output you must never paste here unfiltered.

The salt is 64 characters, the length upstream's own generator produces. It is not an encryption
key: Castopod hashes it together with the date, the listener's IP and their user agent so that
one person downloading an episode twice is counted once, and the hash expires at midnight.
Changing it later costs a day of counting accuracy, not your history.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/castopod/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/castopod/compose.yml` and paste again in one go. Two choices in that file are worth
knowing about. The MariaDB tag is the 11.8 long-term-support line rather than the 12.1 that
upstream's example names, because 12.1 is a rolling release whose image stopped being rebuilt in
February 2026 while 11.8 is supported until June 2028, and Castopod's own requirement is only
10.2 or newer. And the health check carries an `X-Forwarded-Proto` header, because without it
Castopod answers with a redirect to https instead of running the check, and a container with a
dead database would still report itself healthy.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-castopod /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the container, and the
`X-Forwarded-Proto` header it adds by itself is the only thing telling Castopod the request
arrived over https. That is also why there is no `X-Frame-Options` in the block: Castopod ships
an embeddable player, and blocking framing would break it on every site you embed an episode in.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8135`, `3306` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8135`. 8135 is bound
to 127.0.0.1 by the compose file, and MariaDB and Redis are never published at all, so neither
has a host port a firewall rule could apply to. 80/tcp answers the ACME challenge and redirects
to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which is worth having when the
files leaving this box are audio. `Status: inactive` is a different problem: Prompt Zero left
this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

On the first start the container writes its configuration, runs every database migration, then
starts the web server and a cron that fires every minute. Give it a minute or two.

```bash
cd /srv/castopod
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/cp-install
curl -sS https://<DOMAIN>/cp-install | grep -c 'Create your Super Admin account'
```

You should see, in order: the loop reaching `200`, a small JSON object containing `"code":200`,
then `200`, then `1`.

If you do not: that health endpoint is the useful one, because upstream returns `200` from it
only when the database answered, the Redis cache answered and the media directory was writable,
so a `503` there tells you which of the three to look at. If the loop never reaches `200`, run
`docker compose logs --tail 20 db` first, because a database that never reports healthy is step
2 done wrong. Then, and only with the filter, look at the app:
`docker compose logs --tail 40 castopod | grep -viE 'password|salt'`. Never run that command
without the filter while this chat window is open, and read step 10 before you do.

The first screen at https://<DOMAIN>/cp-install shows `4/4` beside the heading
`Create your Super Admin account`, with Username, Email and Password fields and a
`Finish install` button. Open it in a browser now and create your account. The password must be
at least 8 characters and not a dictionary word, and it is the only credential this install has:
self-registration is off in this release, and there is no reset path until you configure mail.
Put it in your password manager before you close the tab.

Once you are signed in, prove that the installer closed behind you:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/cp-install
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from cp_users where is_owner = 1" "$MARIADB_DATABASE"'
```

You should see: `404`, then `1`.

If you do not: a `200` from that first command means no owner account exists yet, so the wizard
is still open to whoever finds the URL, and you should go back and finish it now rather than
later. Castopod decides this by looking for a user row flagged as the instance owner; once one
exists the installer answers `404` for good. A count of `0` from the second command says the
same thing from the other side. Do not treat three running containers as success.

## 8. First backup and restore

Three artifacts. The dump holds the shows, the episodes and the download history. The media
archive holds the audio. The config archive rebuilds the service around them.

```bash
cd /srv/castopod
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/castopod/backups/castopod-db-$(date +%F).sql.gz
docker compose exec -T castopod tar -C /app/public/media -czf - . > /srv/castopod/backups/castopod-media-$(date +%F).tar.gz
sudo tar -czf /srv/castopod/backups/castopod-config-$(date +%F).tar.gz -C /srv/castopod compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/castopod/backups/
```

You should see: three files, all small on a fresh install. Nothing goes offline; `mariadb-dump`
snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump` failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error. The
media archive is the one that changes character over time: it is kilobytes today and the largest
file you own after a year of weekly episodes, so whatever you set up to copy these off the box
has to be sized for audio, not for a database dump.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/castopod
scp vps:/srv/castopod/backups/* ~/backups/castopod/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/castopod/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty show:

```bash
cd /srv/castopod
docker compose down
sudo rm -rf /srv/castopod/mariadb
sudo install -d -m 700 /srv/castopod/mariadb
docker compose up -d db
sleep 30
gunzip -c /srv/castopod/backups/castopod-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/health
```

You should see: no output from the `gunzip` pipe, then `200` from the last command, and your
login still working at https://<DOMAIN>/cp-auth/login.

If you do not: `Access denied for user` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what you are rehearsing:
the feed URL you hand out lives in other people's podcast apps for years, and a restore that
brings back the database but not the audio leaves every one of those apps downloading nothing.
The audio comes back with
`docker compose exec -T castopod tar -C /app/public/media -xzf - < backups/castopod-media-<date>.tar.gz`.

## 9. Updating later

New versions are at https://code.castopod.org/adaures/castopod/-/releases, mirrored at
https://github.com/ad-aures/castopod/tags. Take all three backup artifacts first, then edit the
castopod `image:` line in /srv/castopod/compose.yml to the new tag and its digest.

```bash
cd /srv/castopod
docker compose pull
docker compose up -d
docker compose logs --tail 40 castopod | grep -viE 'password|salt'
```

You should see: the bootstrap output, migrations, then the server starting, and no repeating
restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and confirm
https://<DOMAIN>/cp-install still answers `404`, because that is the check that tells you the
database came through the migration with your owner account intact.

## 10. What will probably go wrong

The first thing `docker compose logs castopod` prints is your entire configuration in plain text,
including the database password, the Redis password and the analytics salt. I pasted that log
into a chat window before I noticed and had to regenerate all three. The container rewrites its
config file on every start and prints it under `INFO: Using config:`, and no setting turns that
off. Pipe it through the filter every time:
`docker compose logs --tail 40 castopod | grep -viE 'password|salt'`.

## 11. Out of scope

- Do not configure SMTP. Publishing works with no mail; mail buys password reset and inviting a
  second contributor, and both are worth a separate evening.
- Do not change `CP_ADMIN_GATEWAY` or `CP_AUTH_GATEWAY`. Upstream suggests renaming those routes,
  and doing it here would make every admin URL in this guide wrong.
- Do not set `CP_MEDIA_FILE_MANAGER` or any `CP_MEDIA_S3_` variable. Object storage for audio is
  a real option and a different install with a different bill.
- Do not add a cron job on the host. The image runs `spark tasks:run` itself every minute, which
  imports feeds and pushes episodes to the fediverse.
