#!/usr/bin/env bash
# Tabby · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=tabby.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://tabby.tabbyml.com/docs/quick-start/installation/docker-compose/
#   https://tabby.tabbyml.com/docs/quick-start/installation/docker/
#   https://tabby.tabbyml.com/docs/models/
#   https://tabby.tabbyml.com/docs/administration/upgrade/
#   https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
#
# This machine needs an NVIDIA GPU. The published image is built against CUDA
# 12.4.1, the inference process links libcuda.so.1, and there is no CPU-only
# build of it. The script refuses to run without a card and a driver new enough
# for that image, and it does not install a kernel driver: on a rented box that
# comes from the provider's image.
#
# One secret is generated here, on this machine: the key Tabby signs session
# tokens with. It goes into /srv/tabby/.env with mode 600 and is never printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/tabby}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. tabby.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is missing: this host has no NVIDIA driver, and Tabby has no CPU-only image"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "the Tabby image publishes linux/amd64 only; this host reports ${arch}"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; this install wants 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; the image and three model files want 20 GB"

vram_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc '0-9')"
[ -n "$vram_mib" ] || die "nvidia-smi reported no GPU"
[ "$vram_mib" -ge 8000 ] || die "the GPU reports ${vram_mib} MiB; the two models plus their context want 8000 MiB"

# nvidia-smi's header prints the highest CUDA version this driver supports. The
# image is built against 12.4.1, so an older driver starts and then dies.
cuda_ver="$(nvidia-smi | awk -F'CUDA Version: ' '/CUDA Version/ {print $2}' | awk '{print $1}')"
cuda_major="${cuda_ver%%.*}"
cuda_minor="${cuda_ver#*.}"
cuda_minor="${cuda_minor%%.*}"
[ -n "$cuda_major" ] || die "could not read a CUDA version out of nvidia-smi"
if [ "$cuda_major" -lt 12 ] || { [ "$cuda_major" -eq 12 ] && [ "$cuda_minor" -lt 4 ]; }; then
	die "the driver reports CUDA ${cuda_ver}; this image needs 12.4 or newer"
fi

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out, and give Docker the card --------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# The signing key is downloaded to a file and named in the apt source line.
# Nothing here is piped into a shell.
if ! docker info 2>/dev/null | grep -qi nvidia; then
	echo "==> installing the NVIDIA Container Toolkit"
	sudo curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /usr/share/keyrings/nvidia-container-toolkit.asc
	sudo chmod a+r /usr/share/keyrings/nvidia-container-toolkit.asc
	echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /" \
		| sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
	sudo apt-get update
	sudo apt-get install -y nvidia-container-toolkit
	sudo nvidia-ctk runtime configure --runtime=docker
	sudo systemctl restart docker
fi

image="$(awk -F'image: ' '/image: /{print $2; exit}' "$APP_DIR/compose.yml")"
docker run --rm --gpus all --entrypoint nvidia-smi "$image" -L | grep -q '^GPU 0:' \
	|| die "a container could not see the GPU. Check: docker info | grep -i nvidia"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Tabby exits rather than warning if this value does not parse as a UUID, so the
# sed puts 128 bits of openssl entropy into the 8-4-4-4-12 shape. Read it later
# with
#   sudo grep TABBY_WEBSERVER /srv/tabby/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		TABBY_WEBSERVER_JWT_TOKEN_SECRET=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-tabby"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8134 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8134 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start downloads about 3 GB of model files before the listener opens.
# Twenty minutes on a slow link is normal, so the wait loop is long on purpose.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ (first start downloads ~3 GB of models)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 20
done
[ "${code:-}" = "200" ] || die "the dashboard answered ${code:-nothing}. Check: docker compose logs --tail 60 tabby"

info="$(curl -sS -H 'Content-Type: application/json' \
	-d '{"query":"{ serverInfo { isAdminInitialized isChatEnabled allowSelfSignup } }"}' \
	"https://${DOMAIN_HOST}/graphql" || true)"

# No account exists yet, so the setup form is open and the next visitor claims
# the server. That is why the summary below is about creating it now.
echo "$info" | grep -q '"isAdminInitialized":false' \
	|| die "serverInfo did not report isAdminInitialized:false. Response: ${info}"
echo "$info" | grep -q '"isChatEnabled":true' \
	|| die "the chat model did not load. Check: docker compose logs --tail 60 tabby"
echo "$info" | grep -q '"allowSelfSignup":false' \
	|| die "self-signup is on, which this install does not configure. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------
#
# The models under data/models are left out on purpose: 3 GB, re-downloadable,
# and checked against a published SHA-256 on every start.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/tabby-${STAMP}.tar.gz" -C "$APP_DIR" data/ee compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/tabby-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Tabby is answering at https://${DOMAIN_HOST}

	  1. Nobody owns this server yet. Open https://${DOMAIN_HOST} now and
	     create the administrator account: the setup form is reachable by
	     anyone who loads that hostname until you do. The first screen reads
	     "Welcome!" and the step after it is "Create Admin Account".
	     There is no mail server here, so that password cannot be reset.
	  2. Your session-signing key is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep TABBY_WEBSERVER $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  3. Self-registration stays off, because it needs SMTP and an allowed
	     email domain and this install configures neither. A second person
	     gets in by an invitation you send from the dashboard. Your editor
	     connects with a Tabby extension pointed at this server, using a
	     token from that same dashboard.
	  4. First backup written to $APP_DIR/backups: the accounts database, the
	     compose file, the secret and the live Caddy block. The 3 GB of model
	     files are not in it and do not need to be. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/tabby/
	  5. Upstream does not support downgrading, so take a backup before every
	     version bump. New releases: https://github.com/TabbyML/tabby/releases

DONE
