You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Tabby 0.32.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS. That server needs an NVIDIA GPU.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say this to the user first, because it decides whether they want this at all. Tabby runs the
model on an NVIDIA GPU in this server. The published image is built against CUDA 12.4.1, its
inference process links `libcuda.so.1`, and there is no CPU-only build: upstream closed that
request in February 2026 and pointed at a third-party image. A rented GPU instance costs more
per month than a GitHub Copilot subscription, every month, whether or not anyone is typing.

Tabby needs 4096 MB of RAM available, 20 GB free on /srv, and a GPU with at least 8 GB of memory
whose driver reports CUDA 12.4 or newer. The image is linux/amd64 only. Measure:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
nvidia-smi | head -3
dig +short <DOMAIN>
```

Stop, print the numbers, and install nothing if any of these is true: available RAM is under
4096 MB, free disk is under 20 GB, `dpkg --print-architecture` prints anything but `amd64`,
`nvidia-smi` is missing or reports no GPU, GPU memory is under 8000 MiB, the `CUDA Version` in
the `nvidia-smi` header is below 12.4, or `dig +short` prints nothing. This prompt installs no
NVIDIA driver: on a rented box that comes from the provider's image.

## 2. Layout and the GPU runtime

Two directories, then the piece Prompt Zero did not install: the NVIDIA Container Toolkit, which
lets Docker hand the card to a container.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/tabby /srv/tabby/backups
sudo install -d -m 700 /srv/tabby/data
sudo curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o /usr/share/keyrings/nvidia-container-toolkit.asc
sudo chmod a+r /usr/share/keyrings/nvidia-container-toolkit.asc
echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /" | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all --entrypoint nvidia-smi tabbyml/tabby:0.32.0@sha256:8de9da4d266b5cd0fb54fe1ffaa772311e5d886453ba1c3a0d1bbcee893e71a9 -L
ls -la /srv/tabby
```

Assert two things. `nvidia-smi -L` inside that container prints a `GPU 0:` line naming the card
step 1 saw, which proves the toolkit is wired into Docker rather than only installed. And
`ls -la` shows `backups` owned by the login user and `data` at mode `700` owned by root, which is
what Tabby sets its root to on every start. The signing key goes to a file and is named in the
apt source line; nothing is piped into a shell. A `could not select device driver` failure means
Docker never reloaded: run the restart again.

## 3. Secrets

One secret: the key Tabby signs session tokens with. Generate it on the server. Do not print it,
do not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/tabby/.env <<EOF
TABBY_WEBSERVER_JWT_TOKEN_SECRET=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
EOF
chmod 600 /srv/tabby/.env
umask 022
ls -l /srv/tabby/.env
```

Assert: the file exists with mode `-rw-------`. The shape is not decorative. Tabby exits rather
than warning if this value does not parse as a UUID, so the `sed` puts 128 bits of `openssl`
entropy into the 8-4-4-4-12 form. Without the variable the server invents a new key on every
start, which signs every user out on every restart. Tell the user it lives in /srv/tabby/.env,
that `sudo grep TABBY_WEBSERVER /srv/tabby/.env` prints it, and that it belongs in their
password manager.

## 4. compose.yml

```bash
cat > /srv/tabby/compose.yml <<'EOF'
# Tabby · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose ....... https://tabby.tabbyml.com/docs/quick-start/installation/docker-compose/
#   docker run ........... https://tabby.tabbyml.com/docs/quick-start/installation/docker/
#   models registry ...... https://tabby.tabbyml.com/docs/models/
#   upgrade .............. https://tabby.tabbyml.com/docs/administration/upgrade/
#
# One service, and it wants an NVIDIA GPU: the image is built from
# docker/Dockerfile.cuda against CUDA 12.4.1, its llama-server links
# libcuda.so.1, and there is no CPU-only build to fall back to. Everything
# Tabby keeps sits under TABBY_ROOT, which the image sets to /data: accounts in
# ee/db.sqlite, the search index, and three model files fetched on first start.
# Digests read on 2026-08-06, same on Docker Hub and ghcr.io; amd64 only.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  tabby:
    image: tabbyml/tabby:0.32.0@sha256:8de9da4d266b5cd0fb54fe1ffaa772311e5d886453ba1c3a0d1bbcee893e71a9
    container_name: tabby
    restart: unless-stopped
    # Upstream's own quick start, plus the embedding model the config
    # defaults to, which is downloaded alongside these two.
    command: serve --model StarCoder-1B --chat-model Qwen2-1.5B-Instruct --device cuda
    env_file: /srv/tabby/.env
    environment:
      # No anonymous usage reports leave this box.
      TABBY_DISABLE_USAGE_COLLECTION: "1"
    volumes:
      - /srv/tabby/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8134.
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
      # long start period is the 3 GB model download on first boot.
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 600s
EOF
cd /srv/tabby && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount. The model
names are the pinned part of that choice: Tabby resolves each name against its registry and
checks the downloaded file against the SHA-256 the registry publishes, so a file that does not
match is fetched again rather than served.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-tabby
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Tabby · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://tabby.tabbyml.com/docs/quick-start/installation/docker/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Tabby serves a
# plain HTTP listener on 8080 and terminates nothing itself.

<DOMAIN> {
	# The dashboard bundle and the JSON responses compress well; Caddy's
	# default matcher leaves everything else alone.
	encode zstd gzip

	# Tabby sets no transport or frame headers of its own. HSTS is on
	# because every request here carries a session cookie or an editor's
	# access token.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8134 is the loopback port compose publishes here. It is not a
	# container port and it is not open in the firewall. Caddy flushes the
	# streamed completions as they arrive and upgrades the dashboard's
	# /subscriptions WebSocket with no extra configuration.
	reverse_proxy 127.0.0.1:8134
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-tabby, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3. 8134 stays closed because compose binds it to 127.0.0.1. The llama-server
processes take ports above 30888 on loopback inside the container's own namespace, so none of
them reaches this firewall. Assert: `ufw status verbose` prints `Status: active`, shows 80,
443/tcp and 443/udp, and no rule mentioning 8134 or 8080.

## 7. Start and verify

The first start downloads about 3 GB of models. Budget twenty minutes.

```bash
cd /srv/tabby
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 20; done
curl -sS -H 'Content-Type: application/json' -d '{"query":"{ serverInfo { isAdminInitialized isChatEnabled allowSelfSignup } }"}' https://<DOMAIN>/graphql; echo
docker compose logs --tail 5 tabby
```

Assert all three, and print what you received for each: the loop ends printing `200`; the
GraphQL response contains `"isAdminInitialized":false` and `"isChatEnabled":true`; the log tail
shows the `Listening at` banner. That `false` means the server is up and nobody owns it yet. If
the loop never reaches 200, stop, run `docker compose logs --tail 60 tabby`, and name the likely
earlier step: a line about `libcuda.so.1` or `could not select device driver` is step 2, a
process that exits after saying something about a UUID is step 3, and a Caddy 502 over a healthy
container is step 5. A running container is not success.

STOP: tell the user to open https://<DOMAIN> and create their account, and wait. Do not continue
until they confirm. A server with no administrator redirects to
https://<DOMAIN>/auth/signup?isAdmin=true, whose first screen reads `Welcome!` above
`Your tabby server is live and ready to use.` with a `Start` button; the step after it is headed
`Create Admin Account` and says the password cannot be recovered. Have them save it as they
type it.

```bash
curl -sS -H 'Content-Type: application/json' -d '{"query":"{ serverInfo { isAdminInitialized allowSelfSignup } }"}' https://<DOMAIN>/graphql; echo
```

Assert: `"isAdminInitialized":true` and `"allowSelfSignup":false`. The second half is the
security assert: self-registration needs SMTP plus an allowed email domain, and this
install has neither, so a second person gets in only by invitation. If `isAdminInitialized`
still prints `false`, the account was not created and the server is still claimable; do not go
on. Then tell the user the next step is theirs: an editor extension pointed at this server,
with a token from the dashboard.

## 8. First backup and restore

One archive: the accounts database, the compose file, the secret and the live Caddy site block.
The model files under data/models are deliberately not in it: 3 GB, re-downloadable, and checked
against a published SHA-256 on every start.

```bash
cd /srv/tabby
docker compose stop
sudo tar -czf /srv/tabby/backups/tabby-$(date +%F).tar.gz -C /srv/tabby data/ee compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/tabby/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped on purpose,
because a SQLite database copied mid-write is not a backup; the restart costs a model load, not a
download.

A backup on the same disk is not a backup. Run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/tabby
scp vps:/srv/tabby/backups/*.tar.gz ~/backups/tabby/
```

To restore: `docker compose down`, `sudo rm -rf /srv/tabby/data/ee`, untar the archive back into
/srv/tabby, put the Caddy block back if that is what was lost, then `docker compose up -d`.
Accounts, access tokens and connected repositories are in `data/ee/db.sqlite`; the key that
validates existing sessions is in `.env`, and a database restored without it signs everyone out.
Upstream states that Tabby does not support downgrading, so this archive is the only way back
from a version that goes wrong.

## 9. Updating later

New versions are listed at https://github.com/TabbyML/tabby/releases. The Docker tag drops the
leading `v`, so `v0.33.0` is tag `0.33.0`. Take the step 8 backup first, there is no downgrade
path, then edit the image line in compose.yml to the new tag and digest:

```bash
cd /srv/tabby
docker compose pull
docker compose up -d
docker compose logs --tail 30 tabby
```

Tabby migrates its own database on the way up. Watch that log until it settles, then re-run
step 7's GraphQL check before calling the update done.

## 10. What will probably go wrong

The first `docker compose up -d` returns in about a second and then nothing answers for a quarter
of an hour. I refreshed https://<DOMAIN> for five minutes, got a connection error every time, and
started reading the compose file for a mistake that was not there. Tabby was downloading 3 GB of
model weights before opening its listener, and `docker compose logs -f tabby` had been showing
the progress all along. Watch the log, not the browser, and do not restart the container to hurry
it: a restart mid-download leaves a partial file that fails its checksum and starts over.

## 11. Out of scope

- Do not switch to the `-cuda11` tag or to a community CPU build. The pinned tag is the CUDA
  12.4.1 image upstream publishes, and step 1 already refused a driver too old for it.
- Do not configure SMTP. Leaving it unset is what keeps self-registration off, which step 7
  asserts; a mail server quietly changes that answer.
- Do not connect a GitHub or GitLab account to index repositories. That is an OAuth application
  the user registers themselves, and this prompt installs the server it would talk to.
- Do not raise `--parallelism` or swap in a larger model. Both multiply the GPU memory needed,
  and step 1 measured the card for the two models in compose.yml.
