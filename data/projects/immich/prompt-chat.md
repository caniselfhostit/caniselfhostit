This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Immich 3.1.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read this before step 1. Immich cannot be served from a sub-path, which upstream states plainly,
so `<DOMAIN>` has to be a hostname of its own rather than a `/photos` prefix on a site you
already run. And this is a four-container install with a 6 GB memory floor, so it does not fit
on the cheapest VPS tier. Both facts are cheaper to learn now than in step 7.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
docker version --format '{{.Server.Version}}'
dig +short <DOMAIN>
```

You should see: at least `6144` MB available, at least `20` G free, `amd64` or `arm64`, a Docker
server version of `25` or higher, and your server's IP on the last line.

If you do not: the RAM line is the one that stops people. Upstream publishes a floor of 6 GB and
recommends 8 GB, and this install runs the machine-learning container, so a 4 GB box will build
thumbnails until the kernel kills something. Resize the server rather than pushing on. The 20 GB
of disk is before a single photo: about 5 GB of images, a model cache that grows as searches
run, and a database upstream puts at 1 to 3 GB. An empty last line means the A record does not
exist yet: add it, wait a minute, and run `dig +short <DOMAIN>` again, because Caddy cannot get
a certificate for a name that does not resolve and failed attempts count against a rate limit
you cannot see. A Docker version below 25 means the database's health check will not gate
start-up properly; upgrade Docker first.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/immich /srv/immich/data /srv/immich/backups
sudo install -d -m 700 /srv/immich/postgres
ls -la /srv/immich
```

You should see: `data` and `backups` owned by you, and `postgres` at mode `drwx------` owned by
root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `/srv/immich/data` is the photo library, and it is the directory that will
grow: originals, thumbnails, transcodes and Immich's own nightly database dumps all live under
it.

## 3. Secrets

One secret, the PostgreSQL password. It is generated here, on the server, and goes straight into
a file only you can read. Hex rather than base64 because upstream restricts this password to the
characters A-Za-z0-9.

```bash
umask 077
cat > /srv/immich/.env <<EOF
TZ=Etc/UTC
DB_USERNAME=immich
DB_DATABASE_NAME=immich
IMMICH_ALLOW_SETUP=true
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/immich/.env
umask 022
ls -l /srv/immich/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/immich/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten the
password, which is fine before the database exists and a problem afterwards: PostgreSQL keeps
the password it was created with, so a changed `DB_PASSWORD` against an existing data directory
shows up as an authentication failure in the Immich log rather than as anything about passwords.

Do not paste that file, the password, or any command output containing it into this chat window.
Nothing in this install needs you to read the value at all: Immich talks to its own database and
you never type it.

`TZ` is the zone Immich falls back to for a photo that carries none of its own, and it is also
the clock the nightly dump job runs on. Change `Etc/UTC` to your own zone later if you like.
`IMMICH_ALLOW_SETUP` stays true only until step 7 closes it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/immich/compose.yml <<'EOF'
# Immich · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose install . https://docs.immich.app/install/docker-compose
#   variable reference ..... https://docs.immich.app/install/environment-variables
#   backup and restore ..... https://docs.immich.app/administration/backup-and-restore
#
# Four services, because that is what Immich is: the server, a machine-learning
# worker doing search and faces on the CPU, a Valkey job queue, and PostgreSQL.
# The database is upstream's own build, not stock postgres, because Immich
# keeps one vector per photo in the VectorChord extension. Every tag and digest
# is upstream's pin for v3.1.0, re-read from the registries on 2026-08-05; the
# valkey `9` tag has moved since. All four images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: immich

services:
  database:
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    container_name: immich_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - /srv/immich/postgres:/var/lib/postgresql/data
    shm_size: 128mb
    # The image ships its own tuned postgresql.conf and health script, so
    # nothing here overrides either. No `ports:`: 5432 stays container-only.

  redis:
    image: docker.io/valkey/valkey:9@sha256:8e8d64b405ce18f41b8e5ee20aa4687a8ed0022d1298f2ce31cdcf3a76e09411
    container_name: immich_redis
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping || exit 1"]
      interval: 10s
      retries: 12
    # No `ports:` either. The queue is spoken between containers only.

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:v3.1.0@sha256:5a0839dc5303cd7215bcd2180a26aed3af41675aefb3e75e5157e9f10ad16e6e
    container_name: immich_machine_learning
    restart: unless-stopped
    volumes:
      - model-cache:/cache
    # No env_file: it reads no DB_ or REDIS_ variable, so the password needs no
    # third copy. The service name is load-bearing: the server looks for the
    # models at immich-machine-learning:3003.

  immich-server:
    image: ghcr.io/immich-app/immich-server:v3.1.0@sha256:b434cb9287eea1471c9974845914d4dd328c9c2d652e446ed4930f99944f0ceb
    container_name: immich_server
    restart: unless-stopped
    env_file: /srv/immich/.env
    environment:
      DB_HOSTNAME: database
      REDIS_HOSTNAME: redis
    volumes:
      # Originals, thumbnails, transcodes and the nightly dumps all land here.
      - /srv/immich/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8098.
      - "127.0.0.1:8098:2283"
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  model-cache:
EOF
cd /srv/immich && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/immich/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal;
run `rm /srv/immich/compose.yml` and paste again in one go. Do not substitute a stock `postgres`
image for the database line, however tempting the familiar name looks. Immich stores one vector
per photo in the VectorChord extension, that extension is why upstream builds and publishes its
own PostgreSQL image, and a plain postgres passes `docker compose config` and then fails on the
first migration.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-immich
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Immich · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.immich.app/administration/reverse-proxy,
# https://caddyserver.com/docs/automatic-https and
# https://caddyserver.com/docs/caddyfile/directives/encode
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. Upstream states Immich cannot be served from a sub-path.

<DOMAIN> {
	# Caddy's encode touches only the text-like content types in its default
	# matcher, so the web app is compressed and photos go through untouched.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8098 is the loopback port compose publishes here. It is not a container
	# port and it is not open in the firewall. Caddy sets three of the four
	# headers upstream asks for, so only X-Real-IP is written. It also applies no
	# request-body limit and no proxy read timeout, which is what an nginx install
	# has to fix before the first 4 GB video upload.
	reverse_proxy 127.0.0.1:8098 {
		header_up X-Real-IP {remote_host}
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-immich /etc/caddy/Caddyfile`, reload, and
paste again. The most common cause is a `<DOMAIN>` you forgot to replace, which Caddy reads as a
site named `<DOMAIN>` and refuses. Caddy issues the certificate on the first request to that
hostname and renews it on its own, so there is nothing to schedule and no path to hardcode.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8098`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8098`. 8098 is bound
to 127.0.0.1 by the compose file, and the database and the queue publish no host port at all, so
there is nothing a firewall rule could even apply to. 80/tcp is there to answer the ACME
challenge and redirect to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy
offers by default. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back before you go
any further.

## 7. Start and verify

The pull is roughly 5 GB across four images and the first database start builds its extensions,
so this is the slow step. The loop below allows twelve minutes and prints a status code every
ten seconds, so you can watch it work.

```bash
cd /srv/immich
docker compose pull
docker compose up -d
for i in $(seq 1 72); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/server/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/server/ping
curl -sS https://<DOMAIN>/api/server/version
curl -sS https://<DOMAIN>/api/server/config
```

You should see, in order: the loop climbing through `502` and reaching `200`, then exactly
`{"res":"pong"}`, then a version object containing `"major":3` and `"minor":1`, then a longer
config object containing `"isInitialized":false`.

If you do not: `{"res":"pong"}` is the same string the server container's own health script
checks for, so getting it means the whole chain is working. `"major":3` and `"minor":1` prove
the digest you pinned really is the version this page claims. `"isInitialized":false` means no
account exists yet, which is what you want one step before you make one. If the loop never
leaves `502`, run `docker compose logs --tail 20 database` first, because a database that never
reports healthy holds everything else back, and `docker compose logs --tail 40 immich-server`
second. A running container is not success; these three responses are.

The first screen at https://<DOMAIN> shows the heading `Welcome to Immich` and a
`Getting Started` button. Open it now, click `Getting Started`, and fill in the
`Admin Registration` form. Whoever loads that page first becomes the administrator of this
server, so it should be you and it should be now.

Then close setup permanently and recreate the server container:

```bash
cd /srv/immich
sed -i 's/^IMMICH_ALLOW_SETUP=true$/IMMICH_ALLOW_SETUP=false/' /srv/immich/.env
docker compose up -d --force-recreate immich-server
sleep 30
curl -sS https://<DOMAIN>/api/server/config
grep '^IMMICH_ALLOW_SETUP=' /srv/immich/.env
```

You should see: the config object now containing `"isInitialized":true`, and the line
`IMMICH_ALLOW_SETUP=false`.

If you do not: `"isInitialized":false` still means the registration form did not submit, so go
back to https://<DOMAIN> and finish it before running this block again. Every account after the
first is created by you from Administration > Users, so once these two checks pass there is no
open door left. If the grep printed `true`, the `sed` did not match; open the file and edit the
line by hand, then re-run the last three commands.

## 8. First backup and restore

Two artifacts, and they are not interchangeable. The dump is metadata: upstream is explicit that
a database backup holds no photos and no video. The photos are files under /srv/immich/data.

```bash
cd /srv/immich
docker compose exec -T database pg_dump --clean --if-exists --dbname=immich --username=immich | gzip > /srv/immich/backups/immich-db-$(date +%F).sql.gz
sudo tar -czf /srv/immich/backups/immich-config-$(date +%F).tar.gz -C /srv/immich compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/immich/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline,
because `pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error. Immich
also writes its own dump into /srv/immich/data/backups nightly at 2am and keeps the last
fourteen, so from tomorrow there will be two on this disk. Two copies on one disk is still one
disk.

A backup on the same disk as the data is not a backup. Run both of these on your own machine,
not the server:

```bash
mkdir -p ~/backups/immich
scp vps:/srv/immich/backups/* ~/backups/immich/
rsync -a --exclude 'thumbs/' --exclude 'encoded-video/' vps:/srv/immich/data/ ~/backups/immich/data/
```

You should see: two files copied by `scp`, then rsync working through the data directory, which
is nearly empty today and will not be in a year.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives. The two
excluded directories hold thumbnails and transcodes, which Immich regenerates from the
originals; everything else under data is irreplaceable, so do not add more excludes to make the
copy faster.

Now prove the restore, today, while the only thing at risk is an empty library:

```bash
cd /srv/immich
docker compose down
sudo rm -rf /srv/immich/postgres
sudo install -d -m 700 /srv/immich/postgres
docker compose up -d database
sleep 60
gunzip --stdout /srv/immich/backups/immich-db-$(date +%F).sql.gz | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" | docker compose exec -T database psql --dbname=immich --username=immich --single-transaction --set ON_ERROR_STOP=on
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/api/server/config
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then a config object containing
`"isInitialized":true`, which means your administrator account survived a database that was
deleted and rebuilt from the dump.

If you do not: `role "immich" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. That `sed` in the middle is not
decoration: it is the search_path rewrite upstream documents, and without it the restore loads
into a schema where the vector extension is invisible. Understand what you have proved and what
you have not. You have proved the metadata restores. The photos restore by copying
~/backups/immich/data back to /srv/immich/data, which is a longer operation on a full library
and worth timing once before you need it.

## 9. Updating later

Releases are listed at https://github.com/immich-app/immich/releases, and the ones that break
something carry a changelog:breaking-change label, filtered at
https://github.com/immich-app/immich/discussions?discussions_q=label%3Achangelog%3Abreaking-change+sort%3Adate_created.
Read the release notes before pulling, every time. Upstream does not backport patches and states
that downgrading, even within the same minor version, is not supported, so an upgrade you cannot
reverse is the normal case here. Take both backups first, then edit the four image lines in
/srv/immich/compose.yml to their new tags and digests.

```bash
cd /srv/immich
docker compose pull
docker compose up -d
docker compose logs --tail 30 immich-server
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tags and digests back and run the same three commands. Then re-run
the health check from step 7 before you call the update done. Across a major version, update
your phones before the server, which is the order upstream asks for, because the server only
speaks to clients on its own major version.

## 10. What will probably go wrong

The machine-learning container will look wedged, and it is not. The first time you search for a
word instead of a date, that container downloads a CLIP model into its cache volume and then
works through your library one asset at a time. On a two-core box I watched load average sit
above four for twenty minutes with nothing changing on screen, decided the install was broken,
and restarted things, which only made it start over. `docker compose logs --tail 20
immich-machine-learning` shows the download and then the inference lines. Leave it alone until
those stop.

## 11. Out of scope

- Do not enable hardware transcoding or machine-learning acceleration. Those are upstream's
  hwaccel.transcoding.yml and hwaccel.ml.yml, they need a matched driver on the host, and this
  install runs both workloads on the CPU on purpose.
- Do not configure OAuth. Immich has local accounts and you create the rest from
  Administration > Users.
- Do not configure SMTP. Immich runs without it; only invitation and album-share email needs it.
- Do not mount an external library. Pointing Immich at photos it does not own changes what a
  backup means, and that is a decision to make deliberately, not while installing.
