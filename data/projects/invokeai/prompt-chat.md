This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing InvokeAI 6.13.7 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. That box needs an NVIDIA GPU. Run
everything over `ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname
whose A record already points at the box and `<ADMIN_EMAIL>` with the email address you want on
the administrator account.

Read this before step 1. A rented GPU instance costs several times a Midjourney subscription
every month, idle or not, so this pays off on hardware you already own. And the pictures are
decided by the checkpoint, not the studio around it: step 7 installs Stable Diffusion XL, which
does not draw like Midjourney.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $2 " MB total, " $7 " MB available"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
nvidia-smi | head -3
dig +short <DOMAIN>
```

You should see: at least `16384` MB total, at least `40` G free, `amd64`, one GPU line with at
least `8000` MiB of memory, a `CUDA Version` of 12 or higher in the `nvidia-smi` header, and your
server's IP on the last line.

If you do not: `nvidia-smi: command not found` means this box has no NVIDIA driver, and nothing
in this prompt installs one, because on a rented GPU instance it comes with the provider's image.
Pick an image that already has the driver, or a different provider. Under 16 GB of RAM is a real
stop rather than a suggestion: the checkpoint passes through system memory on its way to the
card, and the OOM killer arrives in the middle of your third picture rather than at start-up. An
empty last line means the A record does not exist yet: add it, wait a minute, run
`dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve and failed attempts count against a rate limit you cannot see.

## 2. Layout and the GPU runtime

Two directories, then the NVIDIA Container Toolkit, which is what lets Docker hand the card to a
container. Prompt Zero did not install it.

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

You should see: a 5 GB pull, then a line starting `GPU 0:` naming the same card step 1 saw, then
`backups` owned by you and `data` at mode `drwx------` owned by root.

If you do not: `could not select device driver with capabilities: [[gpu]]` means Docker has not
picked up the runtime the toolkit configured, so run `sudo systemctl restart docker` again and
retry that line. Leave `data` owned by root: the image's entrypoint starts as root, chowns its
own root directory to uid 1000 and then drops to it, so a directory you have already chowned to
yourself is the thing that breaks. The signing key is downloaded to a file and named in the apt
source line; nothing here is piped into a shell.

## 3. Secrets

One secret: the password on the administrator account you will sign in with. It is generated
here, on the server, into a file only you can read.

```bash
umask 077
openssl rand -hex 24 > /srv/invokeai/admin-password
chmod 600 /srv/invokeai/admin-password
umask 022
ls -l /srv/invokeai/admin-password
```

You should see: mode `-rw-------`, your own username twice, and the path. Read it once with
`sudo cat /srv/invokeai/admin-password` and put it in your password manager: it is the only
credential this install has, and there is no mail server here, so it has no reset path.

Do not paste that password, that file, or any command output containing it into this chat window.
The other tab's agent never sees the value; this path will hand it to a third party unless you
are deliberate about it.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately into different shells. Run `chmod 600 /srv/invokeai/admin-password`
and carry on. If the file already existed from an earlier attempt, this block has overwritten it,
which is harmless before step 7 has run and a problem afterwards: the account keeps the password
it was created with, and the way back from that is to delete
/srv/invokeai/data/databases/invokeai.db and start step 7 again.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal, so run `rm /srv/invokeai/compose.yml` and paste again in one go. There is no
`env_file` line and that is deliberate: no secret enters this container, because the password is
posted to the application's own setup endpoint in step 7 rather than injected as a variable.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-invokeai /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you forgot to replace, which Caddy reads
as a site address it cannot parse. Caddy requests the certificate on the first request to that
hostname and renews it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8162` or `9090`.

If you do not: delete anything for `8162` with `sudo ufw delete allow 8162`. That port is bound
to 127.0.0.1 by the compose file, and opening it would put a generator with nothing in front of
it on the internet, for anyone who scans your address. 80/tcp answers the ACME challenge and
redirects to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall on, so
something has turned it off, and `sudo ufw enable` puts it back.

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

You should see, in order: the loop reaching `200`, then `{"version":"6.13.7"}`, then a status
object containing `"multiuser_enabled":true` and `"setup_required":true`, then a response
containing `"success":true`, then the same status endpoint now reading `"setup_required":false`,
then `401`.

If you do not: that final `401` is the one worth understanding. It means an unauthenticated
caller cannot even list your models, which is the whole security result of this step, and a `200`
in its place means multiuser mode is off and the box is open. A `403` from the setup call means
the same thing one step earlier: `INVOKEAI_MULTIUSER` never reached the container, so re-read
step 4. If the loop never reaches `200`, run `docker compose logs --tail 60 invokeai`: a line
about `libcuda.so.1` is step 2 done wrong, and a Caddy 502 over a container that `docker compose
ps` calls healthy is step 5. The first start takes a couple of minutes, so give the loop its full
run before deciding anything.

Now sign in as that account and install the checkpoint. This downloads about 7 GB:

```bash
token=$(printf '{"email":"<ADMIN_EMAIL>","password":"%s"}' "$(cat /srv/invokeai/admin-password)" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- https://<DOMAIN>/api/v1/auth/login | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' 'https://<DOMAIN>/api/v2/models/install?source=stabilityai/stable-diffusion-xl-base-1.0:fp16'
for i in $(seq 1 60); do n=$(curl -sS -H "Authorization: Bearer $token" https://<DOMAIN>/api/v2/models/ | grep -c '"base":"sdxl"'); echo "$i sdxl=$n"; [ "$n" != "0" ] && break; sleep 20; done
curl -sS -H "Authorization: Bearer $token" https://<DOMAIN>/api/v2/models/install | grep -o '"status":"[^"]*"' | tail -1
```

You should see: `201`, then a loop that prints `sdxl=0` for several minutes and ends on `sdxl=1`,
then `"status":"completed"` from the last line.

If you do not: `401` from the install request means the token line came back empty, which happens
when the email you used here is not the one you used in the setup call above. A loop that runs out
at `sdxl=0` is usually the disk: the last line prints `"status":"error"`, so run `df -BG /srv` and
check you still have room for 7 GB. That checkpoint is
`stabilityai/stable-diffusion-xl-base-1.0`, fp16 variant, from a Hugging Face repository whose
files have not moved since October 2023. It carries the CreativeML Open
RAIL++-M licence, which allows commercial use and lists uses it forbids, and generating with it
is accepting that: the licence is on the model's page and it is worth two minutes of your time.

Now open https://<DOMAIN> in a browser. The first screen reads `Sign In to InvokeAI`. Sign in
with `<ADMIN_EMAIL>` and the password from `sudo cat /srv/invokeai/admin-password`. A running
container is not success; being inside the studio with a model in the picker is.

## 8. First backup and restore

One archive: the accounts and model records, every picture generated so far, the compose file,
the password and the live Caddy site block. data/models is left out on purpose: 7 GB, and
fetchable again by name.

```bash
cd /srv/invokeai
docker compose stop
sudo tar -czf /srv/invokeai/backups/invokeai-$(date +%F).tar.gz --exclude='data/models' --exclude='data/.cache' -C /srv/invokeai data compose.yml admin-password -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/invokeai/backups/
```

You should see: one `.tar.gz`, a few hundred kilobytes on a fresh install, and about five seconds
of downtime while the container stops and starts.

If you do not: an archive of about 20 bytes means tar found nothing to add, so check you ran the
command from /srv/invokeai. The container is stopped on purpose, because a SQLite database copied
mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/invokeai
scp vps:/srv/invokeai/backups/*.tar.gz ~/backups/invokeai/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/invokeai/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty gallery:

```bash
cd /srv/invokeai
docker compose down
sudo rm -rf /srv/invokeai/data/databases
sudo tar -xzf /srv/invokeai/backups/invokeai-$(date +%F).tar.gz -C /srv/invokeai data
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/api/v1/auth/status; echo
```

You should see: `"setup_required":false`, which means your administrator account came back out of
the archive. Sign in again to be sure.

If you do not: `"setup_required":true` means the databases directory did not restore, so check
the tar output for `data/databases/invokeai.db`. Understand what is at stake before you skip
this: that file is your account and the record of which models exist, and `data/outputs` is every
picture you decided to keep.

## 9. Updating later

New versions are listed at https://github.com/invoke-ai/InvokeAI/releases. The image tag is that
tag plus `-cuda`, so `v6.14.0` is `v6.14.0-cuda`. Take the step 8 backup first, then edit the
`image:` line in /srv/invokeai/compose.yml to the new tag and its digest.

```bash
cd /srv/invokeai
docker compose pull
docker compose up -d
docker compose logs --tail 30 invokeai
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
version and status checks from step 7 before you call the update done, because a container that
starts can still be failing to load models if a migration stopped halfway.

## 10. What will probably go wrong

The model download looks like a hung install. I sent the install request, got my `201`, watched
the job sit at `downloading` for eleven minutes with no byte count anywhere I was looking, and
restarted the container to unstick it. That threw the partial download away and started the seven
gigabytes over. The job list is the only place that progress lives, so while the loop in step 7
keeps printing `downloading`, leave the container alone.

## 11. Out of scope

- Do not switch to the `-cpu` or `-rocm` image. Step 1 measured an NVIDIA card for `-cuda`, and a
  CPU takes minutes per picture.
- Do not turn `INVOKEAI_MULTIUSER` off. It is the whole access control here, and step 7 asserts
  that an unauthenticated caller gets `401`.
- Do not install a gated checkpoint such as FLUX.1 dev or Stable Diffusion 3.5. Those need a
  Hugging Face account and an accepted licence, your call in your own browser.
- Do not configure SMTP. InvokeAI sends no mail and this version has no password reset.
