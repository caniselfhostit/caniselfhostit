#!/usr/bin/env bash
# Plausible CE · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=stats.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://plausible.io/docs/self-hosting
#   https://github.com/plausible/community-edition
#   https://github.com/plausible/community-edition/wiki/configuration
#   https://github.com/plausible/community-edition/wiki/reverse-proxy
#   https://clickhouse.com/docs/en/operations/tips
#
# Three secrets are generated here, on this machine: the session key base, the
# key that encrypts two-factor secrets at rest, and the PostgreSQL password.
# All three go into /srv/plausible/.env with mode 600 and none is ever printed.
#
# DOMAIN_HOST is also BASE_URL, and it is written into the tracking snippet on
# every page you measure. Choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/plausible}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. stats.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; ClickHouse plus PostgreSQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

grep -q -E 'sse4_2|asimd' /proc/cpuinfo \
	|| die "this CPU reports neither SSE 4.2 nor NEON, and ClickHouse needs one of them"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres/ and clickhouse/data stay root-owned at 700: each image chowns its
# own data directory on first start. data/ goes to uid 999, the uid the
# Plausible image runs as.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/clickhouse"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/clickhouse/data"
sudo install -d -m 750 -o 999 -g 999 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# ClickHouse ships tuned for a 16 GB machine. This is what holds it inside a
# small VPS; compose.yml mounts it read-only.
cat > "$APP_DIR/clickhouse/plausible-ce.xml" <<'EOF'
<clickhouse>
  <!-- Sized for a small machine, not the 16 GB one ClickHouse assumes. -->
  <logger><level>warning</level><console>true</console></logger>
  <listen_host>0.0.0.0</listen_host>
  <mark_cache_size>524288000</mark_cache_size>
  <max_server_memory_usage_to_ram_ratio>0.6</max_server_memory_usage_to_ram_ratio>
  <metric_log remove="remove"/><asynchronous_metric_log remove="remove"/>
  <query_log remove="remove"/><query_thread_log remove="remove"/>
  <trace_log remove="remove"/><part_log remove="remove"/>
</clickhouse>
EOF
chmod 644 "$APP_DIR/clickhouse/plausible-ce.xml"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Base64 for the two Elixir keys because upstream documents them that way, hex
# for the database password because it travels inside a connection string.
# Read them later with
#   sudo grep -E 'SECRET_KEY_BASE|TOTP_VAULT_KEY|POSTGRES_PASSWORD' /srv/plausible/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BASE_URL=https://${DOMAIN_HOST}
		SECRET_KEY_BASE=$(openssl rand -base64 48)
		TOTP_VAULT_KEY=$(openssl rand -base64 32)
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-plausible"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8093, 5432 or 8123 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8093, 5432 and 8123 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The command line in compose.yml creates both databases, runs every pending
# migration across them, then starts the server. ClickHouse takes minutes to lay
# out its data directory on the first start, so the wait below is generous.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/system/health/ready (up to ten minutes)"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/system/health/ready" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "the health endpoint answered ${code:-nothing}. Check: docker compose logs --tail 40 plausible"

health="$(curl -sS "https://${DOMAIN_HOST}/api/system/health/ready" || true)"
case "$health" in
	*'"clickhouse":"ok"'*) : ;;
	*) die "ClickHouse is not reporting ok: ${health}. Check: docker compose logs --tail 40 plausible_events_db" ;;
esac
case "$health" in
	*'"postgres":"ok"'*) : ;;
	*) die "PostgreSQL is not reporting ok: ${health}. Check: docker compose logs --tail 20 plausible_db" ;;
esac

# The first screen. With no account yet the root URL redirects to /register.
curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'Register your Plausible CE account' \
	|| die "the first screen did not carry 'Register your Plausible CE account'. Either an account already exists on this instance, or Caddy is not reaching the container."

# --- 7. The first backup, before day one ends --------------------------------
#
# pg_dump runs against a live database. The ClickHouse archive is taken cold,
# because copying that directory under a running server restores into corruption.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T plausible_db pg_dump -U plausible -d plausible_db | gzip > "$APP_DIR/backups/plausible-pg-${STAMP}.sql.gz"
docker compose stop
sudo tar -C "$APP_DIR/clickhouse" -czf "$APP_DIR/backups/plausible-events-${STAMP}.tar.gz" data
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/plausible-config-${STAMP}.tar.gz" compose.yml .env clickhouse/plausible-ce.xml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/plausible-pg-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/plausible-events-${STAMP}.tar.gz" ] || die "the events archive is empty"
[ -s "$APP_DIR/backups/plausible-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Plausible CE is answering at https://${DOMAIN_HOST}/api/system/health/ready

	  1. Open https://${DOMAIN_HOST}/register and create the first account. That
	     page works exactly once: DISABLE_REGISTRATION is true, which upstream
	     bypasses only while the instance has no users. Afterwards, confirm it:
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/register
	     That must print 302. If it prints 200, stop and investigate.
	  2. Your three secrets are in $APP_DIR/.env, mode 600. Read them with
	       sudo grep -E 'SECRET_KEY_BASE|TOTP_VAULT_KEY|POSTGRES_PASSWORD' $APP_DIR/.env
	     and put them in your password manager. None was printed here.
	  3. Add your site in the dashboard, then paste the snippet it gives you into
	     the pages you want counted. Nothing is measured until you do.
	  4. First backup written to $APP_DIR/backups: a PostgreSQL dump, a ClickHouse
	     archive and a config archive. They are on the same disk as the data,
	     which is not a backup. Copy them off the box tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/plausible/

DONE
