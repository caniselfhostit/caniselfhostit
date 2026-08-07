You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install PhotoPrism 260728-ce on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer. Its
A record must already point here, and it becomes `PHOTOPRISM_SITE_URL`, the address in every share
link, so moving it later breaks the links already handed out.

Say this to the user first, because it decides whether they want the install at all: PhotoPrism
organises, searches and shows photographs, and it does not develop them. No exposure slider, no
masking, no presets, no history stack. It replaces the catalogue half of Lightroom, not the other
half.

Upstream asks for 2 cores, 3 GB of physical memory and 4 GB of swap, and this wants 10 GB free on
/srv before the first photograph. Both images publish amd64 and arm64. Measure all five:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
free -m | awk '/^Swap:/ {print $2 " MB swap"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 3072 MB or free disk is under 10 GB, print both numbers and stop. Do not
install and hope. A box sold as 3 GB shows less than 3072 MB available, so plan on 4 GB. Under
1 GB of total memory PhotoPrism turns TensorFlow and RAW indexing off by itself, which is this
install with the search quietly missing. If swap prints `0`, say so: the indexer spikes on large
files and needs the headroom. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/photoprism /srv/photoprism/backups /srv/photoprism/originals /srv/photoprism/storage
sudo install -d -m 700 /srv/photoprism/mariadb
ls -la /srv/photoprism
```

Assert: `backups`, `originals` and `storage` owned by the login user, `mariadb` at mode `700`
owned by root. Leave that one alone; the MariaDB image chowns its own data directory and refuses
one somebody claimed first. `originals` is the library; `storage` is cache, sidecar YAML and the
nightly dump PhotoPrism writes itself.

## 3. Secrets

Three secrets: the initial admin password, the `photoprism` database user's password and the
MariaDB root password. Print none of them and keep all three out of your summary and every log
line.

```bash
umask 077
cat > /srv/photoprism/.env <<EOF
PHOTOPRISM_SITE_URL=https://<DOMAIN>/
PHOTOPRISM_ADMIN_PASSWORD=$(openssl rand -hex 24)
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
printf 'PHOTOPRISM_UID=%s\nPHOTOPRISM_GID=%s\n' "$(id -u)" "$(id -g)" >> /srv/photoprism/.env
chmod 600 /srv/photoprism/.env
umask 022
ls -l /srv/photoprism/.env
id -u
```

Assert: mode `-rw-------`, the login user's name twice, and `id -u` inside the ranges upstream
supports for the id the container drops to after start-up: 0, 33, 50-99, 500-600, 900-1250 and
2000-2100. A first user on a fresh VPS is 1000. Outside those, stop and say so rather than editing
the file. Compose reads this .env for the `${...}` substitutions and never mounts it.
`PHOTOPRISM_ADMIN_PASSWORD` is read once, when the superadmin is created on the first start;
editing the file later changes nothing, and step 7 says where the real change is made.

## 4. compose.yml

```bash
cat > /srv/photoprism/compose.yml <<'EOF'
# PhotoPrism · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose .. https://docs.photoprism.app/getting-started/docker-compose/
#   config options .. https://docs.photoprism.app/getting-started/config-options/
#   behind a proxy .. https://docs.photoprism.app/getting-started/proxies/traefik/
#   open source faq . https://www.photoprism.app/oss/faq
#
# Two services: PhotoPrism and the MariaDB holding the index. The image is the
# "ce" build, which upstream describes as the Community Edition distributed
# under the AGPL; the unsuffixed Docker Hub tags carry their Plus License.
# MariaDB 11.8 is the current long-term release, above the 10.5.12 floor
# upstream states. PHOTOPRISM_INIT is empty and DEFAULT_TLS false, so the
# container installs nothing and generates no certificate at start-up. Every
# ${...} comes from /srv/photoprism/.env, mode 600, which Compose reads and
# never mounts. Digests read 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mariadb:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: photoprism-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    environment:
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DATABASE: photoprism
      MARIADB_USER: photoprism
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    volumes:
      - /srv/photoprism/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  photoprism:
    image: photoprism/photoprism:260728-ce@sha256:15deeb6cc6c31f043625579a29a0e26f5f7b328441fc3945a7a0b7e4b54c0a18
    container_name: photoprism
    restart: unless-stopped
    # Relaxed as upstream's example does, for the tools the indexer runs.
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    working_dir: /photoprism
    environment:
      PHOTOPRISM_ADMIN_USER: "admin"
      PHOTOPRISM_ADMIN_PASSWORD: "${PHOTOPRISM_ADMIN_PASSWORD}"
      PHOTOPRISM_AUTH_MODE: "password"
      # Caddy reaches this over the Docker bridge, inside the proxy range
      # PhotoPrism trusts by default.
      PHOTOPRISM_SITE_URL: "${PHOTOPRISM_SITE_URL}"
      PHOTOPRISM_SITE_CAPTION: ""
      PHOTOPRISM_DISABLE_TLS: "true"
      PHOTOPRISM_DEFAULT_TLS: "false"
      # Nothing is installed on first start: the container downloads nothing.
      PHOTOPRISM_INIT: ""
      PHOTOPRISM_DISABLE_MCP: "true"
      PHOTOPRISM_BACKUP_DATABASE: "true"
      PHOTOPRISM_DATABASE_DRIVER: "mysql"
      PHOTOPRISM_DATABASE_SERVER: "mariadb:3306"
      PHOTOPRISM_DATABASE_NAME: "photoprism"
      PHOTOPRISM_DATABASE_USER: "photoprism"
      PHOTOPRISM_DATABASE_PASSWORD: "${DB_PASSWORD}"
      # Drops to the login user after start-up, so the photographs belong
      # to a person rather than to root.
      PHOTOPRISM_UID: "${PHOTOPRISM_UID}"
      PHOTOPRISM_GID: "${PHOTOPRISM_GID}"
    volumes:
      # The library: everything indexed lives here.
      - /srv/photoprism/originals:/photoprism/originals
      # Cache, sidecar YAML and the nightly dump.
      - /srv/photoprism/storage:/photoprism/storage
    ports:
      # Loopback only: the host's Caddy alone reaches 8164.
      - "127.0.0.1:8164:2342"
    depends_on:
      mariadb:
        condition: service_healthy
EOF
cd /srv/photoprism && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No database port is published and no credential is written here;
all three arrive from .env.

## 5. Caddy and TLS

Append the block below, with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-photoprism
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# PhotoPrism · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.photoprism.app/getting-started/proxies/traefik/ and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# PHOTOPRISM_SITE_URL in .env, and the two have to say the same thing.

<DOMAIN> {
	# No `encode`: PhotoPrism compresses its own API responses, and JPEG,
	# HEIC and video do not compress twice.

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8164 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8164
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-photoprism, reload,
and report the objection. Caddy asks for the certificate on the first request and renews it
itself. `PHOTOPRISM_DISABLE_TLS` is true in compose.yml for that reason.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3. 8164 is bound to
127.0.0.1 and 3306 is never published, so neither has a host port a rule could apply to. Assert:
`Status: active`, rules for 80, 443/tcp and 443/udp, nothing else.

## 7. Start and verify

The first start creates the schema and the superadmin account. The image is about a gigabyte.

```bash
cd /srv/photoprism
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v1/status
curl -sS -o /dev/null -w '%{http_code}\n' 'https://<DOMAIN>/api/v1/photos?count=1'
curl -sS https://<DOMAIN>/ | grep -c '<title>PhotoPrism</title>'
```

Assert all four, printing what you received for each. The loop ends on `200`. The status body is
exactly `{"status":"operational"}`. The unauthenticated search prints `401`, the security assert
here: it proves `PHOTOPRISM_AUTH_MODE` is `password` rather than `public`, and a `200` would mean
every photograph is visible to anyone who finds the address. The grep prints `1`. If any of the
four misses, stop, run `docker compose logs --tail 40 photoprism` and
`docker compose logs --tail 20 mariadb`, and name the likely step: a database that never reports
healthy is step 2, a lasting `502` is step 5. A running container is not success.

The first screen at https://<DOMAIN> is a sign-in card with a `Name` field, a `Password` field and
a `Sign in` button.

STOP: tell the user to open https://<DOMAIN> and sign in as `admin` with the password they read
themselves using `sudo grep PHOTOPRISM_ADMIN_PASSWORD /srv/photoprism/.env`, and wait.
Do not continue until they confirm. Tell them to put it in their password manager, and that it
changes in Settings, then Account: editing .env afterwards does nothing, because the variable is
read only when the account is created.

## 8. First backup and restore

Two artifacts, not interchangeable. The dump is the index: albums, labels, faces, places and where
every file is. The archive is the configuration and the sidecar YAML. Neither holds a photograph,
and the photographs are the third thing.

```bash
cd /srv/photoprism
docker compose exec -T mariadb sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/photoprism/backups/photoprism-db-$(date +%F).sql.gz
sudo tar --exclude='storage/cache' -czf /srv/photoprism/backups/photoprism-config-$(date +%F).tar.gz -C /srv/photoprism compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/photoprism/backups/
```

Assert: both exist, both are non-empty, both sizes printed. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database. `storage/cache` is left out: it is
thumbnails PhotoPrism regenerates, and the largest disposable thing on a real library's disk.

A backup on the same disk is not a backup. Run these from the user's machine, not the server:

```bash
mkdir -p ~/backups/photoprism
scp vps:/srv/photoprism/backups/* ~/backups/photoprism/
rsync -a vps:/srv/photoprism/originals/ ~/backups/photoprism/originals/
```

To restore: `docker compose down`, `sudo rm -rf /srv/photoprism/mariadb`, recreate it as step 2
does, untar the config archive into /srv/photoprism so .env is back before anything starts,
`docker compose up -d mariadb`, wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
rsync the originals back, then `docker compose up -d`. Tell the user the stakes: MariaDB takes its
password from .env the moment it initialises an empty directory, and the dump alone rebuilds an
index of files that are not there.

## 9. Updating later

Releases are datestamped and listed at https://github.com/photoprism/photoprism/releases, and the
AGPL image for each carries the `-ce` suffix on Docker Hub. Take both backups first, then edit the
photoprism image line in /srv/photoprism/compose.yml to the new tag and digest:

```bash
cd /srv/photoprism
docker compose pull
docker compose up -d
docker compose logs --tail 40 photoprism
```

PhotoPrism migrates its own schema on the way up, so watch that log until it settles, then re-run
step 7's status check. Upstream does not backport fixes to older datestamps, so an install left
alone for a year updates in one jump.

## 10. What will probably go wrong

You will copy a folder of photographs into /srv/photoprism/originals, reload the browser, and see
an empty library. I did, and spent ten minutes checking the mount, which was fine. PhotoPrism does
not watch that directory: the automatic index fires only for files arriving over WebDAV, and
anything put there another way sits unseen until somebody runs
`docker compose exec -T photoprism photoprism index`, which takes a while on a large folder.

## 11. Out of scope

- Do not add the ollama or open-webui services from upstream's example compose file. They are two
  more containers and a multi-gigabyte model download.
- Do not set `PHOTOPRISM_AUTH_MODE` to `public`. It removes the sign-in screen from a service the
  whole internet can reach, and step 7 asserts against that.
- Do not switch to the unsuffixed image tag for membership features. That build ships under
  PhotoPrism's Plus License rather than the AGPL, and the licence is the user's decision.
- Do not configure hardware video transcoding or mount /dev/dri. It needs devices this prompt never
  checked for.
