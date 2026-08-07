#!/usr/bin/env bash
# Easy!Appointments · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=book.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/alextselegidis/easyappointments-docker/blob/master/README.md
#   https://github.com/alextselegidis/easyappointments-docker/blob/master/assets/docker-entrypoint.sh
#   https://github.com/alextselegidis/easyappointments/blob/1.6.0/docs/installation-guide.md
#   https://caddyserver.com/docs/automatic-https
#
# Two secrets are generated here, on this machine: the MySQL root password and
# the password the application connects with. Both go into
# /srv/easyappointments/.env with mode 600 and neither is ever printed.
#
# There is one thing this script cannot do for you. The administrator account is
# created in a browser, on the installation page, with a password you choose.
# The script opens that page, waits for you to finish, and only then verifies.
#
# DOMAIN_HOST is also BASE_URL, the address printed inside every booking link.
# Choose it once. Changing it later breaks links your customers already hold.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/easyappointments}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. book.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1536 ] || die "only ${avail_mb} MB of RAM available; PHP plus MySQL 8.4 wants 1536 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# No directory for the application itself: every appointment, customer, service
# and setting is a row in MySQL, and the container's storage folder holds only
# sessions, cache and logs. The MySQL directory stays root-owned, because the
# image chowns it to its own uid on first start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mysql"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64: both travel inside a connection string, and neither
# wants escaping. Read them later with
#   sudo grep -E 'DB_PASSWORD|MYSQL_ROOT_PASSWORD' /srv/easyappointments/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BASE_URL=https://${DOMAIN_HOST}
		DB_PASSWORD=$(openssl rand -hex 32)
		MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-easyappointments"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8160 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8160 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MySQL initialises from nothing on the first start, which takes a minute or
# two, and compose holds the application container back until it reports
# healthy.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/index.php/installation"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/index.php/installation" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the installation page answered ${code:-nothing}. Check: docker compose logs --tail 40 easyappointments"

curl -sS "https://${DOMAIN_HOST}/index.php/installation" | grep -qF 'Easy!Appointments Installation' \
	|| die "that page answered 200 without the installation heading. Check: docker compose logs --tail 40 easyappointments"

# --- 7. The one step only a human can do -------------------------------------
#
# That page is an open form on a public hostname and it hands the administrator
# account to whoever loads it first, so it is closed by being used, now.

cat <<-OPEN

	==> Open this page in a browser and create the administrator account:

	      https://${DOMAIN_HOST}/index.php/installation

	    Your name, email, a username, a password of at least 8 characters,
	    your company name and company email. Then press Install.

	    This script is waiting, and gives up after 20 minutes.

OPEN

# A redirect means the users table now exists, so the form has closed itself.
# CodeIgniter answers a redirected GET with 307; accept any 3xx.
for _ in $(seq 1 120); do
	installed="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/index.php/installation" || true)"
	case "$installed" in 3??) break ;; esac
	sleep 10
done
case "${installed:-}" in
	3??) ;;
	*) die "the installation page still answers ${installed:-nothing}, so no account was created. It is open to the internet until it is used." ;;
esac

curl -sS "https://${DOMAIN_HOST}/" | grep -qF 'Book Appointment With' \
	|| die "the booking page did not carry its title. Check: docker compose logs --tail 40 easyappointments"

# The API must refuse an unauthenticated call. Upstream answers 401 to a caller
# with no bearer token and no basic-auth credentials.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/index.php/api/v1/appointments" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T easyappointments-db sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction easyappointments' \
	| gzip > "$APP_DIR/backups/easyappointments-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/easyappointments-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/easyappointments-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Easy!Appointments is answering at https://${DOMAIN_HOST}/

	  1. The public booking page is https://${DOMAIN_HOST}/ and your backend is
	     https://${DOMAIN_HOST}/index.php/calendar, with the username and
	     password you entered on the installation page. That password was
	     yours to choose and this script never saw it.
	  2. Set your working hours under Settings, then add your services and
	     your providers. The installer left one sample service and one sample
	     provider behind for you to edit or delete.
	  3. No mail is configured. A customer who books will see a screen saying
	     the details were emailed to them, and no email will arrive. Turn
	     Customer Notifications off under Settings until you add a relay.
	  4. First backup written to $APP_DIR/backups: a database dump and a
	     config archive. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight.

DONE
