You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install InvokeAI 6.13.7 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS. That server needs an NVIDIA GPU.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user once for the hostname and for the
email their administrator account will use, then stop until they answer. The A record must already
point here.

Say this to them first. A rented GPU instance costs several times a Midjourney subscription every
month, idle or not, so this pays off on hardware that already exists. And the pictures are decided
by the checkpoint, not the studio around it: step 7 installs Stable Diffusion XL, which does not
draw like Midjourney.

InvokeAI needs 16384 MB of RAM, 40 GB free on /srv, and a card with at least 8 GB of memory:
upstream's table gives 8 GB of VRAM and 16 GB of RAM as the SDXL floor. The image is linux/amd64
only. Measure:

```bash
free -m | awk '/^Mem:/ {print $2 " MB total, " $7 " MB available"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
nvidia-smi | head -3
dig +short <DOMAIN>
```

Stop, print the numbers, and install nothing if any of these is true: total RAM is under
16384 MB, free disk is under 40 GB, `dpkg --print-architecture` prints anything but `amd64`,
`nvidia-smi` is missing or reports no GPU, GPU memory is under 8000 MiB, the `CUDA Version` in
the header is below 12, or `dig +short` prints nothing. The floor is on total memory: a checkpoint
passes through system RAM on the way to the card. No NVIDIA driver is installed here; on a rented
box that comes from the provider's image.

## 2. Layout and the GPU runtime

Two directories, then the piece Prompt Zero did not install: the NVIDIA Container Toolkit, which
hands the card to a container.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/invokeai /srv/invokeai/backups
sudo install -d -m 700 /srv/invokeai/data
sudo curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /usr/share/keyrings/nvidia-container-toolkit.asc
sudo chmod a+r /usr/share/keyrings/nvidia-container-toolkit.asc
echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /" | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all --entrypoint nvidia-smi ghcr.io/invoke-ai/invokeai:v6.13.7-cuda@sha256:16e16aa96a1cc2df5373212baaa4b0e5827d2c1212a763bbdcea866db04b93c0 -L
ls -la /srv/invokeai
```

Assert two things. `nvidia-smi -L` inside that container prints a `GPU 0:` line naming the card
step 1 saw, which proves the toolkit is wired into Docker rather than only installed. And `ls -la`
shows `backups` owned by the login user and `data` at mode `700` owned by root: leave that one,
because the entrypoint starts as root, chowns its root directory to uid 1000 and drops to it. The
signing key goes to a file, never into a shell. That pull is 5 GB. A `could not select device
driver` failure means Docker never reloaded: restart again.

## 3. Secrets

One secret: the password on the administrator account. Generate it on the server. Do not print
it, do not repeat it in your summary, do not put it in any log line.

```bash
umask 077
openssl rand -hex 24 > /srv/invokeai/admin-password
chmod 600 /srv/invokeai/admin-password
umask 022
ls -l /srv/invokeai/admin-password
```

Assert: the file exists with mode `-rw-------`. Hex, because this gets typed into a sign-in box.
It never enters the container as an environment variable; step 7 posts it once to the setup
endpoint. InvokeAI makes its own token-signing key at first start, so nothing else is generated.

## 4. compose.yml

```bash
cat > /srv/invokeai/compose.yml <<'EOF'
# InvokeAI · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker ......... https://invoke.ai/configuration/docker/
#   configuration .. https://invoke.ai/configuration/invokeai-yaml/
#   requirements ... https://invoke.ai/start-here/system-requirements/
#   image build .... https://github.com/invoke-ai/InvokeAI/blob/v6.13.7/docker/Dockerfile
#
# One service, and it wants an NVIDIA GPU. Upstream's own workflow builds and
# pushes the -cuda image on every version tag, linux/amd64 only. Everything
# InvokeAI keeps is under INVOKEAI_ROOT, which the image sets to /invokeai:
# accounts and model records in databases/invokeai.db, checkpoints under models,
# pictures under outputs. Digest read from ghcr.io on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  invokeai:
    image: ghcr.io/invoke-ai/invokeai:v6.13.7-cuda@sha256:16e16aa96a1cc2df5373212baaa4b0e5827d2c1212a763bbdcea866db04b93c0
    container_name: invokeai
    restart: unless-stopped
    environment:
      # Upstream's default is single-user: no accounts, no sign-in, every
      # request served as an administrator. On a hostname that is an open
      # generator on somebody's GPU, so this install turns it off.
      INVOKEAI_MULTIUSER: "true"
      # The password is 192 bits of openssl output, not a phrase someone
      # typed, so the upper/lower/digit rule has nothing to add.
      INVOKEAI_STRICT_PASSWORD_CHECKING: "false"
    volumes:
      - /srv/invokeai/data:/invokeai
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8162.
      - "127.0.0.1:8162:9090"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    healthcheck:
      # No curl in this image; python is on PATH.
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9090/api/v1/app/version')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 180s
EOF
cd /srv/invokeai && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount, no database
container: accounts, boards and model records are one SQLite file in that mount.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy it first: a syntax error here takes down every other site.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-invokeai
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# InvokeAI · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://invoke.ai/configuration/docker/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. InvokeAI serves plain
# HTTP on 9090 and checks the credential itself, so nothing here is secret.

<DOMAIN> {
	encode zstd gzip

	# InvokeAI sets no transport or frame headers of its own. HSTS is on
	# because every request after sign-in carries a bearer token.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8162 is the loopback port compose publishes here, not a container port
	# and never open in the firewall. reverse_proxy upgrades the studio's
	# progress socket unaided.
	reverse_proxy 127.0.0.1:8162
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-invokeai, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8162 stays closed because compose binds it to 127.0.0.1; opening it would put a generator
with nothing in front of it on the internet. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule for 8162 or 9090.

## 7. Start and verify

Bring it up, claim the administrator account before anyone else can, then install the checkpoint.

```bash
cd /srv/invokeai
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/app/version); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v1/app/version; echo
curl -sS https://<DOMAIN>/api/v1/auth/status; echo
printf '{"email":"<ADMIN_EMAIL>","display_name":"Administrator","password":"%s"}' "$(cat /srv/invokeai/admin-password)" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- https://<DOMAIN>/api/v1/auth/setup; echo
curl -sS https://<DOMAIN>/api/v1/auth/status; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v2/models/
```

Assert all six and print what you received for each. The loop ends on `200`. The version endpoint
returns `{"version":"6.13.7"}`. The first status call carries `"multiuser_enabled":true` and
`"setup_required":true`: up, and nobody owns it yet. The setup call returns `"success":true`, and
the second status call reads `"setup_required":false`, so that door is shut and cannot be
reopened. The last prints `401`, an unauthenticated caller unable to so much as list the models,
and that is the security assert here. If any of the six misses, stop, run
`docker compose logs --tail 60 invokeai`, and name the likely earlier step: `libcuda.so.1` is
step 2, a Caddy 502 over a healthy container is step 5, and a `403` from the setup call is step 4.
A running container is not success.

Now sign in as that account and install the checkpoint. This downloads about 7 GB:

```bash
token=$(printf '{"email":"<ADMIN_EMAIL>","password":"%s"}' "$(cat /srv/invokeai/admin-password)" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- https://<DOMAIN>/api/v1/auth/login | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' 'https://<DOMAIN>/api/v2/models/install?source=stabilityai/stable-diffusion-xl-base-1.0:fp16'
for i in $(seq 1 60); do n=$(curl -sS -H "Authorization: Bearer $token" https://<DOMAIN>/api/v2/models/ | grep -c '"base":"sdxl"'); echo "$i sdxl=$n"; [ "$n" != "0" ] && break; sleep 20; done
curl -sS -H "Authorization: Bearer $token" https://<DOMAIN>/api/v2/models/install | grep -o '"status":"[^"]*"' | tail -1
```

Assert: the install request prints `201`, the loop ends printing `sdxl=1`, and the last command
prints `"status":"completed"`. If the loop runs out at `sdxl=0`, that last line says why. That
checkpoint is `stabilityai/stable-diffusion-xl-base-1.0`, fp16 variant, from a Hugging Face
repository whose files have not moved since October 2023. It carries the CreativeML Open RAIL++-M
licence, which allows commercial use and lists uses it forbids; tell the user that licence is on
the model's page and that generating is accepting it.

STOP: tell the user to open https://<DOMAIN>, where the first screen reads `Sign In to InvokeAI`,
sign in with `<ADMIN_EMAIL>` and the password from `sudo cat /srv/invokeai/admin-password`, put it
in their password manager, and wait. Do not continue until they confirm they are inside. There is
no mail here, so that password has no reset path.

## 8. First backup and restore

One archive: accounts and model records, every picture so far, the compose file, the password and
the live Caddy site block. data/models is left out on purpose: 7 GB, fetchable again by name.

```bash
cd /srv/invokeai
docker compose stop
sudo tar -czf /srv/invokeai/backups/invokeai-$(date +%F).tar.gz --exclude='data/models' --exclude='data/.cache' -C /srv/invokeai data compose.yml admin-password -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/invokeai/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped because a
SQLite database copied mid-write is not a backup, and one on the same disk is not either, so run
this from the user's machine, not the server:

```bash
mkdir -p ~/backups/invokeai
scp vps:/srv/invokeai/backups/*.tar.gz ~/backups/invokeai/
```

To restore: `docker compose down`, `sudo rm -rf /srv/invokeai/data/databases`, untar the archive
into /srv/invokeai, put the Caddy block back if that was lost, `docker compose up -d`, then re-run
step 7's install commands. `data/databases/invokeai.db` holds the accounts, boards and model
records, `data/outputs` holds every picture kept, `admin-password` is the way back in.

## 9. Updating later

New versions are listed at https://github.com/invoke-ai/InvokeAI/releases. The image tag is that
tag plus `-cuda`, so `v6.14.0` is `v6.14.0-cuda`. Back up first, then edit the image line in
/srv/invokeai/compose.yml to the new tag and digest:

```bash
cd /srv/invokeai
docker compose pull
docker compose up -d
docker compose logs --tail 30 invokeai
```

InvokeAI migrates its own database on the way up. Watch that log until it settles, then re-run
step 7's version and status checks.

## 10. What will probably go wrong

The model download looks like a hung install. I sent the install request, got my `201`, watched
the job sit at `downloading` for eleven minutes with no byte count anywhere I was looking, and
restarted the container to unstick it. That threw the partial download away and started the seven
gigabytes over. The job list is the only place that progress lives, so while step 7's loop keeps
printing `downloading`, leave the container alone.

## 11. Out of scope

- Do not switch to the `-cpu` or `-rocm` image. Step 1 measured an NVIDIA card for `-cuda`, and a
  CPU takes minutes per picture.
- Do not turn `INVOKEAI_MULTIUSER` off. It is the whole access control here, and step 7 asserts
  that an unauthenticated caller gets `401`.
- Do not install a gated checkpoint such as FLUX.1 dev or Stable Diffusion 3.5. Those need a
  Hugging Face account and an accepted licence, the user's call in their own browser.
- Do not configure SMTP. InvokeAI sends no mail and this version has no password reset.
