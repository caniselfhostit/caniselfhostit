You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Tabby 0.32.0 under ~/selfhost/tabby, answering at http://localhost:8134, with its models
running on the NVIDIA card in this computer.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this at all. The
model runs on the GPU in this machine, so the answer to "is my code sent anywhere" is no and the
answer to "how fast is it" is however fast this card is. Nothing here is reachable from their
phone or a second laptop, which costs little: this only has to be awake while they type.

Detect the OS and measure the machine:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
nvidia-smi | head -3
```

`Linux` is Linux; `MINGW` or `MSYS` is Windows under Git Bash. Both are supported.

STOP if `uname -s` printed `Darwin`. Tell the user this prompt cannot install Tabby on a Mac and
do not continue. The published image is linux/amd64 only and built against CUDA, and Docker
Desktop on macOS reaches neither an x86 GPU nor Apple's own. Upstream ships a macOS binary that
uses Metal; that is a different install and this prompt does not cover it.

Stop and print the numbers if any of these is true: `uname -m` prints anything but `x86_64`,
`nvidia-smi` is missing or reports no GPU, GPU memory is under 8000 MiB, the `CUDA Version` in
the `nvidia-smi` header is below 12.4, available RAM is under 4096 MB, or the home disk has under
20 GB free. Do not install and hope. On Windows that reads the Windows driver, the one WSL 2
hands to Docker, so it is the number to trust.

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

Docker also has to hand the card to a container. Windows does that through WSL 2; Linux needs the
NVIDIA Container Toolkit, from the next guarded fence:

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
docker run --rm --gpus all --entrypoint nvidia-smi tabbyml/tabby:0.32.0@sha256:8de9da4d266b5cd0fb54fe1ffaa772311e5d886453ba1c3a0d1bbcee893e71a9 -L
```

Assert: that last line prints a `GPU 0:` line naming the card step 1 saw; it pulls 1.6 GB the
first time. A `could not select device driver` failure means Docker has not taken the runtime up:
on Linux run the restart again, on Windows quit Docker Desktop and reopen.

## 3. Layout

```bash
mkdir -p ~/selfhost/tabby/data ~/selfhost/tabby/backups
ls -la ~/selfhost/tabby
```

Assert: `ls -la` shows `data` and `backups`, both owned by the user. No ownership fix is needed:
the container starts as root in its own namespace and sets its data directory to mode 700 on
every start, and on Windows Docker Desktop's file sharing owns it.

## 4. Secrets

One secret: the key Tabby signs session tokens with. Generate it here, print it nowhere, keep it
out of your summary and out of any log line.

```bash
umask 077
cat > ~/selfhost/tabby/.env <<EOF
TABBY_WEBSERVER_JWT_TOKEN_SECRET=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
EOF
chmod 600 ~/selfhost/tabby/.env
umask 022
ls -l ~/selfhost/tabby/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl and sed, so this runs the
same on both systems. The 8-4-4-4-12 shape matters: Tabby exits rather than warning if the value
is not a UUID, and without the variable it invents a new key on every start, signing the user out
whenever Docker restarts. On Windows those mode bits are advisory: NTFS does not enforce them,
and the real boundary is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/tabby/compose.yml <<'EOF'
# Tabby · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker compose ....... https://tabby.tabbyml.com/docs/quick-start/installation/docker-compose/
#   models registry ...... https://tabby.tabbyml.com/docs/models/
#   upgrade .............. https://tabby.tabbyml.com/docs/administration/upgrade/
#
# One service on the computer you are sitting at, and it wants the NVIDIA card
# in that computer. Paths are relative to ~/selfhost/tabby/, so data/ and
# backups/ open in your file manager. The image is built against CUDA 12.4.1
# and is linux/amd64 only, which is why this file has no macOS story. Digests
# read 2026-08-06 on Docker Hub.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  tabby:
    image: tabbyml/tabby:0.32.0@sha256:8de9da4d266b5cd0fb54fe1ffaa772311e5d886453ba1c3a0d1bbcee893e71a9
    container_name: tabby
    restart: unless-stopped
    # Upstream's own quick start, plus the default embedding model, which
    # is downloaded alongside these two.
    command: serve --model StarCoder-1B --chat-model Qwen2-1.5B-Instruct --device cuda
    env_file: ./.env
    environment:
      # No anonymous usage reports leave this computer.
      TABBY_DISABLE_USAGE_COLLECTION: "1"
    volumes:
      - ./data:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8134.
      - "127.0.0.1:8134:8080"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    healthcheck:
      # The dashboard answers unauthenticated; the /v1 API does not. The
      # long start period is the 3 GB model download.
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 600s
EOF
cd ~/selfhost/tabby && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount. Tabby checks
each downloaded model against the SHA-256 its registry publishes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the dashboard works.
- No firewall rule. Nothing is published past loopback.

8134 is bound to 127.0.0.1, this computer only. The user's phone cannot reach it, nor a laptop on
the same wifi, nor anyone on the internet, and the editor that uses it runs here. Confirm:

```bash
grep -n '127.0.0.1' ~/selfhost/tabby/compose.yml
```

Assert: one line, `- "127.0.0.1:8134:8080"`. The llama-server processes take ports above 30888
inside the container's namespace and are published nowhere.

## 7. Start and verify

The first start downloads about 3 GB of models before anything answers. Budget 20 minutes.

```bash
cd ~/selfhost/tabby
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8134/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 20; done
curl -sS -H 'Content-Type: application/json' -d '{"query":"{ serverInfo { isAdminInitialized isChatEnabled allowSelfSignup } }"}' http://localhost:8134/graphql; echo
docker compose logs --tail 5 tabby
```

Assert all three, and print what you received for each: the loop ends printing `200`; the
GraphQL response contains `"isAdminInitialized":false` and `"isChatEnabled":true`; the log tail
shows the `Listening at` banner. If the loop never reaches 200, stop, run
`docker compose logs --tail 60 tabby`, and name the likely earlier step: a line about
`libcuda.so.1` or `could not select device driver` is step 2, and a process that exits after
saying something about a UUID is step 4. If `port is already allocated` came back, find what holds
8134 (`ss -ltnp | grep 8134`, or `netstat -ano | findstr :8134`) and stop until the user frees it.
A running container is not success.

STOP: tell the user to open http://localhost:8134 and create their account, and wait. Do not
continue until they confirm. A server with no administrator lands on the setup flow, whose first
screen reads `Welcome!` above `Your tabby server is live and ready to use.` with a `Start`
button; the step after is headed `Create Admin Account` and says the password cannot be
recovered. Have them save it as they type.

```bash
curl -sS -H 'Content-Type: application/json' -d '{"query":"{ serverInfo { isAdminInitialized allowSelfSignup } }"}' http://localhost:8134/graphql; echo
```

Assert: `"isAdminInitialized":true` and `"allowSelfSignup":false`. If it still prints `false`, the
account was not created; do not go on. Tell the user the next thing they need is an editor
extension pointed at http://localhost:8134 with a token from the dashboard, and that installing
it is theirs to do.

## 8. First backup and restore

One archive: the accounts database, the compose file and the secret. The models under data/models
are deliberately not in it: 3 GB, re-downloadable, checked on every start.

```bash
cd ~/selfhost/tabby
docker compose stop
tar -C ~/selfhost/tabby -czf ~/selfhost/tabby/backups/tabby-$(date +%F).tar.gz data/ee compose.yml .env
docker compose start
ls -lh ~/selfhost/tabby/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped because a
SQLite database copied mid-write is not a backup.

That archive sits on the same disk as the data, which is not a backup, and on one computer the
disk and the machine fail together. Ask the user for a destination that leaves this computer, a
sync folder or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is
`/d/Backups`, not `D:\Backups`. Assert: the user confirms the file is listed there. If they have
none, say plainly that this install has no backup.

To restore: `cd ~/selfhost/tabby`, `docker compose down`, `rm -rf data/ee`, untar the archive
there, then `docker compose up -d`. Accounts and access tokens are in `data/ee/db.sqlite`; the
key that validates existing sessions is in `.env`, and a database restored without it signs
everyone out. Upstream states that Tabby does not support downgrading, so this archive is the
only way back.

## 9. Updating later

New versions are listed at https://github.com/TabbyML/tabby/releases. The Docker tag drops the
leading `v`, so `v0.33.0` is tag `0.33.0`. Take the step 8 backup first, there is no downgrade
path, then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/tabby
docker compose pull
docker compose up -d
docker compose logs --tail 30 tabby
```

Watch that log until it settles, then re-run step 7's check before calling it done.

## 10. What will probably go wrong

I rebooted, opened the editor, typed for ten minutes with no completions, and assumed the
extension had lost its token. It had not: Docker Desktop never started with the session, so
nothing was listening on 8134 and every request failed quietly, which is exactly what an absent
code assistant looks like. `restart: unless-stopped` only takes effect once the Docker daemon is
up. Turn on Docker's start-at-login setting, and after a reboot run
`cd ~/selfhost/tabby && docker compose up -d` before concluding anything is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not switch to the `-cuda11` tag or a community CPU build. The pinned tag is the CUDA 12.4.1
  image upstream publishes, and step 1 already refused a driver too old for it.
- Do not configure SMTP. Leaving it unset is what keeps self-registration off.
- Do not raise `--parallelism` or swap in a larger model. Both multiply the GPU memory needed,
  and step 1 measured the card for the two models in compose.yml.
