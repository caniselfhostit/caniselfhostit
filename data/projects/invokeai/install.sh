#!/usr/bin/env bash
# InvokeAI · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=studio.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://invoke.ai/configuration/docker/
#   https://invoke.ai/configuration/invokeai-yaml/
#   https://invoke.ai/start-here/system-requirements/
#   https://github.com/invoke-ai/InvokeAI/blob/v6.13.7/docker/Dockerfile
#   https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
#
# This machine needs an NVIDIA GPU. The published -cuda image is linux/amd64 and
# there is no CPU build worth running a diffusion model on. The script refuses to
# start without a card, and it installs no kernel driver: on a rented box that
# comes from the provider's image.
#
# One secret is generated here, on this machine: the password on the
# administrator account. It goes into /srv/invokeai/admin-password with mode 600,
# is posted once to InvokeAI's own setup endpoint, and is never printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/invokeai}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
CHECKPOINT="stabilityai/stable-diffusion-xl-base-1.0:fp16"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. studio.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address you want on the administrator account"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is missing: this host has no NVIDIA driver"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "the InvokeAI image publishes linux/amd64 only; this host reports ${arch}"

total_mb="$(free -m | awk '/^Mem:/ {print $2}')"
[ "$total_mb" -ge 16384 ] || die "this machine has ${total_mb} MB of RAM; upstream's floor for SDXL is 16384 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 40 ] || die "only ${avail_gb} GB free on /srv; the image and the checkpoint want 40 GB"

vram_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc '0-9')"
[ -n "$vram_mib" ] || die "nvidia-smi reported no GPU"
[ "$vram_mib" -ge 8000 ] || die "the GPU reports ${vram_mib} MiB; SDXL wants 8000 MiB"

# nvidia-smi's header prints the highest CUDA version this driver supports. The
# image ships a CUDA 12 build of torch, so a CUDA 11 driver cannot run it.
cuda_major="$(nvidia-smi | awk -F'CUDA Version: ' '/CUDA Version/ {print $2}' | awk '{print $1}' | cut -d. -f1)"
[ -n "$cuda_major" ] || die "could not read a CUDA version out of nvidia-smi"
[ "$cuda_major" -ge 12 ] || die "the driver reports CUDA ${cuda_major}.x; this image needs 12 or newer"

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
# Read it later with
#   sudo cat /srv/invokeai/admin-password
# It is the only credential this install has, and there is no mail server here,
# so it has no reset path.

if [ ! -f "$APP_DIR/admin-password" ]; then
	umask 077
	openssl rand -hex 24 > "$APP_DIR/admin-password"
	chmod 600 "$APP_DIR/admin-password"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-invokeai"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8162 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8162 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it, and claim the administrator account ------------------------
#
# InvokeAI's multiuser mode leaves /api/v1/auth/setup open until an admin exists,
# so the account is claimed here, seconds after the listener opens, rather than
# left for whoever loads the hostname first.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v1/app/version"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/app/version" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the version endpoint answered ${code:-nothing}. Check: docker compose logs --tail 60 invokeai"

curl -sS "https://${DOMAIN_HOST}/api/v1/app/version" | grep -q '"version":"6.13.7"' \
	|| die "the server did not report version 6.13.7. Check the image line in compose.yml."

status="$(curl -sS "https://${DOMAIN_HOST}/api/v1/auth/status" || true)"
echo "$status" | grep -q '"multiuser_enabled":true' \
	|| die "multiuser mode is off, so this install has no sign-in. Check INVOKEAI_MULTIUSER in compose.yml."
echo "$status" | grep -q '"setup_required":true' \
	|| die "an administrator account already exists here. Response: ${status}"

printf '{"email":"%s","display_name":"Administrator","password":"%s"}' "$ADMIN_EMAIL" "$(cat "$APP_DIR/admin-password")" \
	| curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- \
		"https://${DOMAIN_HOST}/api/v1/auth/setup" | grep -q '"success":true' \
	|| die "the administrator account was not created. Check the email address in ADMIN_EMAIL."

curl -sS "https://${DOMAIN_HOST}/api/v1/auth/status" | grep -q '"setup_required":false' \
	|| die "setup still reports as required, so the account did not stick. Stop and investigate."

# The security assert: with multiuser on and no token, the model list is refused.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v2/models/" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated model listing returned ${unauth}, not 401. Stop and investigate."

# --- 7. Install the checkpoint -----------------------------------------------
#
# stabilityai/stable-diffusion-xl-base-1.0, fp16 variant, about 7 GB. Its
# licence is CreativeML Open RAIL++-M: commercial use allowed, with a list of
# uses it forbids, on the model's own Hugging Face page.

token="$(printf '{"email":"%s","password":"%s"}' "$ADMIN_EMAIL" "$(cat "$APP_DIR/admin-password")" \
	| curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- \
		"https://${DOMAIN_HOST}/api/v1/auth/login" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)"
[ -n "$token" ] || die "signing in as ${ADMIN_EMAIL} failed, so the checkpoint cannot be installed"

created="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
	-H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' -d '{}' \
	"https://${DOMAIN_HOST}/api/v2/models/install?source=${CHECKPOINT}" || true)"
[ "$created" = "201" ] || die "the model install request returned ${created}, not 201"

# The assert is the model appearing in the registry, not a status string: an
# install job carries one status per downloaded file as well as its own.

echo "==> downloading ${CHECKPOINT} (about 7 GB)"
registered=0
for _ in $(seq 1 60); do
	if curl -sS -H "Authorization: Bearer ${token}" "https://${DOMAIN_HOST}/api/v2/models/" \
		| grep -q '"base":"sdxl"'; then
		registered=1
		break
	fi
	echo "    still downloading"
	sleep 20
done
if [ "$registered" -ne 1 ]; then
	job="$(curl -sS -H "Authorization: Bearer ${token}" "https://${DOMAIN_HOST}/api/v2/models/install" \
		| grep -o '"status":"[^"]*"' | tail -1 || true)"
	die "the checkpoint never registered; the last install status was ${job:-nothing}"
fi

# --- 8. The first backup, before day one ends --------------------------------
#
# data/models is left out on purpose: 7 GB, and fetchable again by name.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/invokeai-${STAMP}.tar.gz" \
	--exclude='data/models' --exclude='data/.cache' \
	-C "$APP_DIR" data compose.yml admin-password -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/invokeai-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	InvokeAI is answering at https://${DOMAIN_HOST}

	  1. Sign in at https://${DOMAIN_HOST} with ${ADMIN_EMAIL}. The first
	     screen reads "Sign In to InvokeAI". Your password is in
	     $APP_DIR/admin-password, mode 600. Read it with
	       sudo cat $APP_DIR/admin-password
	     and put it in your password manager. It was not printed here, and
	     there is no mail server, so it has no reset path.
	  2. The administrator account was claimed by this script the moment the
	     server came up, so the setup form was never left open on a public
	     hostname. An unauthenticated caller gets 401 from the API.
	  3. One checkpoint is installed: ${CHECKPOINT}. Its licence is
	     CreativeML Open RAIL++-M, on the model's Hugging Face page. It
	     allows commercial use and lists uses it forbids. Read it.
	  4. First backup written to $APP_DIR/backups: accounts, model records,
	     outputs, the compose file, the password and the live Caddy block.
	     The 7 GB checkpoint is not in it and does not need to be. It is on
	     the same disk as the data, which is not a backup. Copy it tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/invokeai/
	  5. New releases: https://github.com/invoke-ai/InvokeAI/releases

DONE
