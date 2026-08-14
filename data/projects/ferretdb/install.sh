#!/usr/bin/env bash
# FerretDB · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   ./install.sh
#
# There is no domain to pass and nothing is published to the internet. FerretDB
# answers the MongoDB wire protocol on 127.0.0.1:8191, so the clients are
# applications on this box, containers that join this compose project's network,
# and people who forward the port over their own ssh session.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.ferretdb.io/installation/ferretdb/docker/
#   https://docs.ferretdb.io/installation/documentdb/docker/
#   https://docs.ferretdb.io/configuration/flags/
#   https://docs.ferretdb.io/security/authentication/
#
# One secret is generated here, on this machine: the PostgreSQL password. It is
# also the password every MongoDB client sends, because FerretDB stores no
# accounts of its own. It goes into /srv/ferretdb/.env with mode 600 and is
# never printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/ferretdb}"
MSH="ghcr.io/ferretdb/ferretdb-eval:2.7.0@sha256:1bf47a449dd65839aabfc1a535d1370c98326f8a90de20437eda0aeb30bd8dd5"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; FerretDB plus PostgreSQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres stays root-owned at 700: the PostgreSQL image chowns its own data
# directory on first start and refuses one that is already claimed. state is
# uid 1000 because that is the uid in the FerretDB image's passwd file.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/state"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64 because it travels inside a connection string. Read it
# later with
#   sudo grep POSTGRES_PASSWORD /srv/ferretdb/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy: no site block, on purpose -------------------------------------
#
# The MongoDB wire protocol is not HTTP, so reverse_proxy has nothing to carry
# and there is no hostname to certify. The Caddyfile installed above is the
# record of that decision; /etc/caddy is left exactly as it was.

if [ -f /etc/caddy/Caddyfile ]; then
	caddy_hits="$(sudo awk '/ferretdb/ {n++} END {print n+0}' /etc/caddy/Caddyfile)"
	[ "$caddy_hits" = "0" ] || die "/etc/caddy/Caddyfile mentions ferretdb ${caddy_hits} time(s). An earlier attempt published this database. Remove that site block, reload caddy, and run this again."
fi

# --- 5. Ports: none open, and neither 8191 nor 5432 is one of them -----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> this install opens no port; 8191 is loopback and 5432 is never published"
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The image carries a HEALTHCHECK that upstream documents as behaving like a
# readiness probe: it passes only when a MongoDB protocol connection can be made
# and DocumentDB is installed correctly, so one word covers both containers.

docker compose pull
docker compose up -d

echo "==> waiting for the ferretdb container to report healthy"
health=""
for _ in $(seq 1 36); do
	health="$(docker inspect --format '{{.State.Health.Status}}' ferretdb 2>/dev/null)" || health=""
	[ "$health" = "healthy" ] && break
	sleep 5
done
[ "$health" = "healthy" ] || die "the ferretdb container reported '${health:-nothing}'. Check: docker compose logs --tail 40 ferretdb"

# The wire protocol, end to end: a write and a read through mongosh. The shell
# comes from FerretDB's own evaluation image, pinned by digest and run with its
# entrypoint overridden so none of the services it carries ever start. That pull
# is roughly 600 MB and nothing keeps it afterwards.

echo "==> pulling the MongoDB shell image (about 600 MB, used once)"
docker pull "$MSH" >/dev/null

PGPW="$(sudo grep '^POSTGRES_PASSWORD=' "$APP_DIR/.env" | cut -d= -f2-)"
docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet \
	"mongodb://ferretdb:${PGPW}@127.0.0.1:27017/appdb" \
	--eval 'db.selfhost_check.insertOne({ok:1}); printjson(db.selfhost_check.findOne())'
unset PGPW

# An anonymous client can open a socket to FerretDB. What it must not be able to
# do is read or write anything, and that is what this asserts.
if anon="$(docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet \
	"mongodb://127.0.0.1:27017/appdb" \
	--eval 'db.selfhost_check.insertOne({anon:1})' 2>&1)"; then
	printf '%s\n' "$anon"
	die "an unauthenticated client inserted a document. Authentication is not being enforced: check FERRETDB_POSTGRESQL_URL in compose.yml and stop until it is fixed."
fi
printf '==> unauthenticated write refused, as it must be:\n%s\n' "$anon"

# --- 7. The first backup, before day one ends --------------------------------
#
# Cold, because a PostgreSQL data directory copied while the server is writing
# is not a backup and a file copy of a stopped cluster is correct at any size.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/ferretdb-${STAMP}.tar.gz" -C "$APP_DIR" postgres state .env compose.yml Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/ferretdb-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	FerretDB is answering the MongoDB wire protocol on 127.0.0.1:8191

	  1. Your connection string is
	       mongodb://ferretdb:<the value in .env>@127.0.0.1:8191/appdb
	     It works from an application on this box as written, and from a
	     container in another compose project only if that container joins
	     this project's network, where the host becomes ferretdb:27017.
	     From your own laptop, forward the port first, on the laptop:
	       ssh -N -L 27017:127.0.0.1:8191 vps
	  2. The password is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep POSTGRES_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here. It is
	     the whole security boundary: upstream states authorization is not
	     yet supported, so every valid login has full access to everything.
	  3. A test document was written to appdb.selfhost_check and read back.
	     Drop it whenever you like through the same shell:
	       db.selfhost_check.drop()
	  4. There is no web interface, no sign-in screen and no public hostname.
	     Nothing was added to /etc/caddy/Caddyfile and no port was opened.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.
	     Treat that archive as credential material, because .env and every
	     document you have written are inside it.
	  6. The two image tags are a matched pair. When you update, move the
	     PostgreSQL image first, run ALTER EXTENSION documentdb UPDATE, then
	     move FerretDB. Releases: github.com/FerretDB/FerretDB/releases

DONE
