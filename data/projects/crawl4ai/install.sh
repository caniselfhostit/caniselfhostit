#!/usr/bin/env bash
# Crawl4AI · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=crawl.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/README.md
#   https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/config.yml
#   https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/entrypoint.sh
#   https://github.com/unclecode/crawl4ai/blob/v0.9.2/LICENSE
#
# One secret is generated here: CRAWL4AI_API_TOKEN. It goes into
# /srv/crawl4ai/.env with mode 600 and is never printed. There is no browser
# sign-in. The token is not optional: without it the container's entrypoint
# binds its server to container loopback and the published port answers
# nothing. With it, every API route returns 401 without a Bearer header.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/crawl4ai}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. crawl.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; this install wants 4096 MB because the image runs a real Chromium"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 15 ] || die "only ${avail_gb} GB free on /srv; this install wants 15 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# No data directory: this compose file mounts nothing. The crawl cache, the
# artifact store and the in-container Redis are all disposable.

# --- 3. API token on the server ----------------------------------------------

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-EOF
		CRAWL4AI_API_TOKEN=$(openssl rand -hex 32)
	EOF
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block -----------------------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-crawl4ai"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Firewall -------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8198 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start and assert -----------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for http://127.0.0.1:8198/health (the image is large and starts a browser)"
for _ in $(seq 1 36); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8198/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 crawl4ai"

unauth="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/md" \
	-H 'Content-Type: application/json' --data-binary '{"url":"https://example.com","f":"raw"}' || true)"
[ "$unauth" = "401" ] || die "unauthenticated POST /md returned ${unauth}, not 401. Stop and investigate."

TOKEN="$(grep CRAWL4AI_API_TOKEN "$APP_DIR/.env" | cut -d= -f2-)"
curl -sS -X POST "https://${DOMAIN_HOST}/md" \
	-H "Authorization: Bearer ${TOKEN}" \
	-H 'Content-Type: application/json' \
	--data-binary '{"url":"https://example.com","f":"raw"}' | grep -q 'Example Domain' \
	|| die "the authenticated /md call did not return the crawled page"

curl -sS -X POST "https://${DOMAIN_HOST}/crawl" \
	-H "Authorization: Bearer ${TOKEN}" \
	-H 'Content-Type: application/json' \
	--data-binary '{"urls":["https://example.com"],"crawler_config":{"type":"CrawlerRunConfig","params":{"check_robots_txt":true}}}' \
	| grep -q '"success":true' \
	|| die "the authenticated /crawl call did not report success"
unset TOKEN

curl -sSL "https://${DOMAIN_HOST}/playground/" | grep -q '<title>Crawl4AI Playground</title>' \
	|| die "the playground UI did not answer on https://${DOMAIN_HOST}/playground/"

# --- 7. First backup ---------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/crawl4ai-${STAMP}.tar.gz" \
	-C "$APP_DIR" .env compose.yml -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/crawl4ai-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Crawl4AI is answering at https://${DOMAIN_HOST}

	  1. There is no browser sign-in. The API expects Authorization: Bearer.
	  2. Read the API token with:
	       sudo grep CRAWL4AI_API_TOKEN ${APP_DIR}/.env
	     Store it offline. It is admin-scoped and there is no read-only key.
	  3. Crawl one page, with that value in the Authorization header:
	       curl -sS -X POST https://${DOMAIN_HOST}/crawl \\
	         -H "Authorization: Bearer <the value from .env>" \\
	         -H 'Content-Type: application/json' \\
	         --data-binary '{"urls":["https://example.com"]}'
	  4. Unauthenticated POST /md returns 401 (asserted above).
	  5. The playground is at https://${DOMAIN_HOST}/playground/ and needs the
	     same token pasted into its token bar.
	  6. First backup at ${APP_DIR}/backups (includes .env). Copy it off this disk.
	     Nothing else is on disk: this install mounts no volumes.
	  7. NOT YET VERIFIED on a clean harness machine.

DONE
