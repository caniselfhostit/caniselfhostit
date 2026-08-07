You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install InvokeAI 6.13.7 under ~/selfhost/invokeai, answering at http://localhost:8162, with the
model running on the NVIDIA card in this computer.

## 1. Preflight

Say this to the user before step 2 runs. The model runs on the card in this machine, so nothing
they type leaves the building and the speed is whatever that card can do. Every picture lands in
~/selfhost/invokeai/data/outputs: the gallery is theirs, and so is the disk it fills.

Detect the OS and measure this machine:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $2 " MB total, " $7 " MB available"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize" | awk '$1+0 {printf "%d MB total\n", $1/1024}' ;;
esac
df -h ~
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
nvidia-smi | head -3
```

`Linux` is Linux; `MINGW` or `MSYS` is Windows under Git Bash. Both work.

STOP if `uname -s` printed `Darwin`. Tell the user this prompt cannot install InvokeAI on a Mac
and do not continue. The image is linux/amd64 and built against CUDA, and Docker Desktop on macOS
reaches neither an x86 GPU nor Apple's own.

Stop and print the numbers if any of these is true: `uname -m` prints anything but `x86_64`,
`nvidia-smi` is missing or reports no GPU, GPU memory is under 8000 MiB, the `CUDA Version` in
the header is below 12, total RAM is under 16384 MB, or the home disk has under 40 GB free. Those
are upstream's floors for the checkpoint step 7 installs. Do not install and hope.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they confirm.
  Docker Desktop configures WSL 2 itself and may ask for a reboot; if it does, STOP, tell the
  user to reboot and come back, and resume at this step. Then STOP: have the user open Docker
  Desktop, accept its terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt repository,
  with its signing key saved to a file first, never piped into a shell. The fence is guarded, a
  no-op on anything but a Linux with apt.

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the user
  in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose plugin with
  their package manager, and to run this prompt again once `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Not one without the
other.

Docker also has to hand over the card. Windows does that through WSL 2; Linux needs the NVIDIA
Container Toolkit, from the next guarded fence:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /usr/share/keyrings/nvidia-container-toolkit.asc
  sudo chmod a+r /usr/share/keyrings/nvidia-container-toolkit.asc
  echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /" | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
fi
docker run --rm --gpus all --entrypoint nvidia-smi ghcr.io/invoke-ai/invokeai:v6.13.7-cuda@sha256:16e16aa96a1cc2df5373212baaa4b0e5827d2c1212a763bbdcea866db04b93c0 -L
```

Assert: that last line prints a `GPU 0:` line naming the card step 1 saw. A `could not select
device driver` failure means Docker has not taken the runtime up: on Linux restart it again, on
Windows quit Docker Desktop and reopen.

## 3. Layout

```bash
mkdir -p ~/selfhost/invokeai/data ~/selfhost/invokeai/backups
ls -la ~/selfhost/invokeai
```

Assert: `ls -la` shows `data` and `backups`, both owned by the user. No ownership fix is needed:
the entrypoint starts as root, chowns that directory to uid 1000 and drops to it.

## 4. Secrets

One secret: the administrator account's password. Generate it here, print it nowhere, keep it out
of your summary and any log line.

```bash
umask 077
openssl rand -hex 24 > ~/selfhost/invokeai/admin-password
chmod 600 ~/selfhost/invokeai/admin-password
umask 022
ls -l ~/selfhost/invokeai/admin-password
```

Assert: the file exists with mode `-rw-------`. On Windows those mode bits are advisory: NTFS
does not enforce them, and the real boundary is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/invokeai/compose.yml <<'EOF'
# InvokeAI · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker ......... https://invoke.ai/configuration/docker/
#   configuration .. https://invoke.ai/configuration/invokeai-yaml/
#   requirements ... https://invoke.ai/start-here/system-requirements/
#   image build .... https://github.com/invoke-ai/InvokeAI/blob/v6.13.7/docker/Dockerfile
#
# One service on the computer you are sitting at, and it wants the NVIDIA card in
# that computer. Paths are relative to ~/selfhost/invokeai/, so data/outputs
# opens in your file manager. The entrypoint starts as root, chowns that
# directory to uid 1000 and drops to it, so no ownership fix is needed first.
# The -cuda image is linux/amd64 only, which is why this file has no macOS
# story. Digest read from ghcr.io on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  invokeai:
    image: ghcr.io/invoke-ai/invokeai:v6.13.7-cuda@sha256:16e16aa96a1cc2df5373212baaa4b0e5827d2c1212a763bbdcea866db04b93c0
    container_name: invokeai
    restart: unless-stopped
    environment:
      # Upstream's default is single-user: no accounts, no sign-in, every
      # request served as an administrator. Loopback is not private on a
      # machine other people use, so this install turns it off.
      INVOKEAI_MULTIUSER: "true"
      # The password is 192 bits of openssl output, not a phrase someone
      # typed, so the upper/lower/digit rule has nothing to add.
      INVOKEAI_STRICT_PASSWORD_CHECKING: "false"
    volumes:
      - ./data:/invokeai
    ports:
      # Loopback only: no other device on the wifi can reach 8162.
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
cd ~/selfhost/invokeai && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait on.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the studio works.
- No firewall rule. Nothing is published past loopback.

8162 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. The sign-in step 7 sets up still earns its keep, because every program and account
on this machine can reach loopback. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/invokeai/compose.yml
```

Assert: that prints `1`, the published port `- "127.0.0.1:8162:9090"`.

## 7. Start and verify

Bring it up and claim the administrator account:

```bash
cd ~/selfhost/invokeai
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8162/api/v1/app/version); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8162/api/v1/app/version; echo
curl -sS http://localhost:8162/api/v1/auth/status; echo
printf '{"email":"admin@invokeai.local","display_name":"Administrator","password":"%s"}' "$(cat ~/selfhost/invokeai/admin-password)" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- http://localhost:8162/api/v1/auth/setup; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8162/api/v2/models/
```

Assert all five and print what you received for each: the loop ends on `200`; the version endpoint
returns `{"version":"6.13.7"}`; the first status call carries `"multiuser_enabled":true` and
`"setup_required":true`; the setup call returns `"success":true`; the last prints `401`, the
account gate working. If any of the five misses, stop, run
`docker compose logs --tail 60 invokeai`, and name the likely cause: `libcuda.so.1` is step 2. If
`port is already allocated` came back, find what holds 8162 (`ss -ltnp | grep 8162`) and stop
until the user frees it. A running container is not success.

Now sign in and install the checkpoint, about 7 GB:

```bash
token=$(printf '{"email":"admin@invokeai.local","password":"%s"}' "$(cat ~/selfhost/invokeai/admin-password)" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- http://localhost:8162/api/v1/auth/login | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d '{}' 'http://localhost:8162/api/v2/models/install?source=stabilityai/stable-diffusion-xl-base-1.0:fp16'
for i in $(seq 1 60); do n=$(curl -sS -H "Authorization: Bearer $token" http://localhost:8162/api/v2/models/ | grep -c '"base":"sdxl"'); echo "$i sdxl=$n"; [ "$n" != "0" ] && break; sleep 20; done
curl -sS -H "Authorization: Bearer $token" http://localhost:8162/api/v2/models/install | grep -o '"status":"[^"]*"' | tail -1
```

Assert: the install request prints `201`, the loop ends printing `sdxl=1`, and the last command
prints `"status":"completed"`. If the loop runs out at `sdxl=0`, that last line says why. That
checkpoint is `stabilityai/stable-diffusion-xl-base-1.0`, fp16 variant, from a Hugging Face
repository whose files have not moved since October 2023, under the CreativeML Open RAIL++-M
licence: commercial use allowed, a list of uses forbidden, and generating is accepting it. Tell
the user it is on the model's page.

STOP: tell the user to open http://localhost:8162, where the first screen reads
`Sign In to InvokeAI`, sign in as `admin@invokeai.local` with the password from
`cat ~/selfhost/invokeai/admin-password`, put it in their password manager, and wait.
Do not continue until they confirm they are inside. There is no mail here, so it has no
reset path.

## 8. First backup and restore

One archive: accounts and model records, every picture so far, the compose file and the password.
data/models is left out: 7 GB, fetchable again by name.

```bash
cd ~/selfhost/invokeai
docker compose stop
tar -C ~/selfhost/invokeai -czf ~/selfhost/invokeai/backups/invokeai-$(date +%F).tar.gz --exclude='data/models' --exclude='data/.cache' data compose.yml admin-password
docker compose start
ls -lh ~/selfhost/invokeai/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped because a
SQLite database copied mid-write is not a backup.

That archive sits on the same disk as the data, which is not a backup, and on one computer the
disk and the machine fail together. Ask the user for a destination that leaves this computer, a
sync folder or a USB stick, and copy it there with `cp`. Assert: the user confirms the file is
there. If they have nowhere, say plainly that this install has no backup.

To restore: `cd ~/selfhost/invokeai`, `docker compose down`, `rm -rf data/databases`, untar the
archive there, `docker compose up -d`, then re-run step 7's install commands.
`data/databases/invokeai.db` holds the accounts and model records, `data/outputs` every picture
kept, `admin-password` the way back in.

## 9. Updating later

New versions are listed at https://github.com/invoke-ai/InvokeAI/releases. The image tag is that
tag plus `-cuda`, so `v6.14.0` is `v6.14.0-cuda`. Back up first, then edit the image line in
compose.yml:

```bash
cd ~/selfhost/invokeai
docker compose pull
docker compose up -d
docker compose logs --tail 30 invokeai
```

Watch that log until it settles, then re-run step 7's version check.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8162, and got a connection error that reads like a lost
install. Nothing was lost: Docker Desktop had not started with the session,
so nothing was listening on 8162, and `restart: unless-stopped` takes effect only once the Docker
daemon is up. Turn on Docker's start-at-login setting, and after a reboot run
`cd ~/selfhost/invokeai && docker compose up -d` before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not switch to the `-cpu` or `-rocm` image. Step 1 measured an NVIDIA card, and a CPU takes
  minutes per picture.
- Do not install a gated checkpoint such as FLUX.1 dev or Stable Diffusion 3.5. Those need a
  Hugging Face account and an accepted licence, the user's call.
