You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Immich 3.1.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and it has to be a hostname of its own: upstream
states Immich cannot be served from a sub-path.

Upstream publishes a floor of 6 GB of RAM and recommends 8 GB, and this install runs the
machine-learning container, so 6 GB is a floor rather than a suggestion. Budget 20 GB of disk
before a single photo: about 5 GB of images, a model cache that fills as searches run, and a
database upstream puts at 1 to 3 GB. Immich runs on amd64 and arm64; since v3 the amd64
machine-learning image needs x86-64-v2, which server CPUs have had since about 2012. Step 4's
health gate needs Docker Engine 25 or newer.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
docker version --format '{{.Server.Version}}'
dig +short <DOMAIN>
```

If available RAM is under 6144 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope, and do not fall back to the machine-learning-disabled variant to fit a
4 GB box: that is a different install. If the Docker version is below 25, or `dig +short` prints
nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/immich /srv/immich/data /srv/immich/backups
sudo install -d -m 700 /srv/immich/postgres
ls -la /srv/immich
```

Assert: `data` and `backups` are owned by the login user, and `postgres` is mode `drwx------`
owned by root. Leave that one alone: the PostgreSQL image chowns its own data directory on first
start and refuses one already chowned to somebody else. `/srv/immich/data` is the photo library.

## 3. Secrets

One secret, the PostgreSQL password. Generate it on the server, do not print it, do not repeat
it in your summary, and keep it out of every log line. Hex rather than base64, because upstream
restricts this password to A-Za-z0-9.

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

Assert: the file exists with mode `-rw-------`. `TZ` is the fallback zone for a photo carrying
none of its own, and the user can change it later. `IMMICH_ALLOW_SETUP` is true only until step
7 closes it.

## 4. compose.yml

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

Assert: that prints `compose OK`. Do not swap a stock `postgres` image into the database line:
VectorChord is why upstream builds its own, and a plain postgres fails on the first migration.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-immich, reload, and report what it objected to. Caddy issues the
certificate on the first request to that hostname and renews it unattended.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8098 stays closed because it is bound to 127.0.0.1; 5432 and 6379 have no host port to
firewall at all. Assert: `ufw status verbose` prints `Status: active`, shows those three, and no
rule for 8098, 5432 or 6379.

## 7. Start and verify

The pull is roughly 5 GB and the first database start builds its extensions, so this is the slow
step. The loop allows twelve minutes.

```bash
cd /srv/immich
docker compose pull
docker compose up -d
for i in $(seq 1 72); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/server/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/server/ping
curl -sS https://<DOMAIN>/api/server/version
curl -sS https://<DOMAIN>/api/server/config
```

Assert all four and print what you received for each. The loop ends on `200`. The ping response
is exactly `{"res":"pong"}`, the string the container's own health script checks for. The
version response contains `"major":3` and `"minor":1`, confirming the digest you pinned is the
version this prompt claims. The config response contains `"isInitialized":false`: no account
exists yet. If any of the four misses, stop, run
`docker compose logs --tail 40 immich-server` and `docker compose logs --tail 20 database`, and
name the likely earlier step. A database that never reports healthy points at step 2, and a
`502` where JSON was expected means the server is still starting. A running container is not
success.

The first screen at https://<DOMAIN> shows the heading `Welcome to Immich` and a
`Getting Started` button.

STOP: tell the user to open https://<DOMAIN>, click `Getting Started`, and fill in the
`Admin Registration` form, and wait. Do not continue until they confirm. Whoever loads that page
first becomes the administrator here, so it should be them and it should be now.

Once they confirm, close setup permanently:

```bash
cd /srv/immich
sed -i 's/^IMMICH_ALLOW_SETUP=true$/IMMICH_ALLOW_SETUP=false/' /srv/immich/.env
docker compose up -d --force-recreate immich-server
sleep 30
curl -sS https://<DOMAIN>/api/server/config
grep '^IMMICH_ALLOW_SETUP=' /srv/immich/.env
```

Assert: the config response now contains `"isInitialized":true`, and the grep prints
`IMMICH_ALLOW_SETUP=false`. Both must pass before you report success. Every later account is
made by the administrator, so there is no other registration door to close.

## 8. First backup and restore

Two artifacts, not interchangeable. Upstream is explicit that a database backup holds no photos
and no video; the photos are files under /srv/immich/data.

```bash
cd /srv/immich
docker compose exec -T database pg_dump --clean --if-exists --dbname=immich --username=immich | gzip > /srv/immich/backups/immich-db-$(date +%F).sql.gz
sudo tar -czf /srv/immich/backups/immich-config-$(date +%F).tar.gz -C /srv/immich compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/immich/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. Immich also dumps itself into
/srv/immich/data/backups nightly at 2am. Two copies on one disk is one disk, so run both of
these from the user's machine, not the server:

```bash
mkdir -p ~/backups/immich
scp vps:/srv/immich/backups/* ~/backups/immich/
rsync -a --exclude 'thumbs/' --exclude 'encoded-video/' vps:/srv/immich/data/ ~/backups/immich/data/
```

Thumbnails and transcodes are excluded because Immich regenerates them; everything else under
data is irreplaceable.

To restore: `docker compose down`, `sudo rm -rf /srv/immich/postgres`, recreate it as in step 2,
put compose.yml and .env back from the config archive, `docker compose up -d database`, wait a
minute for healthy, then load the dump with the search_path rewrite upstream documents:

```bash
gunzip --stdout /srv/immich/backups/immich-db-$(date +%F).sql.gz | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" | docker compose exec -T database psql --dbname=immich --username=immich --single-transaction --set ON_ERROR_STOP=on
```

Then rsync the data directory back and run `docker compose up -d`. Tell the user the stakes:
the dump knows where every photo is, the data directory is every photo, and either one alone
rebuilds nothing.

## 9. Updating later

Releases are at https://github.com/immich-app/immich/releases, and the ones that break something
carry a changelog:breaking-change label, filtered at
https://github.com/immich-app/immich/discussions?discussions_q=label%3Achangelog%3Abreaking-change+sort%3Adate_created.
Read the release notes before pulling, every time. Upstream does not backport patches and states
that downgrading, even within the same minor version, is not supported, so an upgrade you cannot
reverse is the normal case. Take both backups, then edit the four image lines in
/srv/immich/compose.yml to their new tags and digests:

```bash
cd /srv/immich
docker compose pull
docker compose up -d
docker compose logs --tail 30 immich-server
```

Immich migrates its own database on the way up, so watch that log until it settles, then re-run
step 7's health check. Across a major version, update mobile clients before the server, as
upstream asks.

## 10. What will probably go wrong

The machine-learning container will look wedged, and it is not. The first time the user searches
for a word instead of a date, that container downloads a CLIP model into its cache volume and
then works through the library one asset at a time. On a two-core box I watched load average sit
above four for twenty minutes with nothing changing on screen, decided the install was broken,
and restarted things, which made it start over. `docker compose logs --tail 20
immich-machine-learning` shows the download and then the inference lines; leave it alone until
those stop.

## 11. Out of scope

- Do not enable hardware transcoding or machine-learning acceleration. Upstream's
  hwaccel.transcoding.yml and hwaccel.ml.yml need a matched host driver, and this install runs
  both workloads on the CPU on purpose.
- Do not configure OAuth. Immich has local accounts and the administrator creates the rest.
- Do not configure SMTP. Immich runs without it; only invitation mail needs it.
- Do not mount an external library. Pointing Immich at photos it does not own changes what a
  backup means, and that is the user's call.
