This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Tabby 0.32.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read this before step 1. Tabby runs its models on an NVIDIA GPU in that server. The published
image is built against CUDA 12.4.1, its inference process links `libcuda.so.1`, and there is no
CPU-only build: upstream closed that request in February 2026 and pointed at a third-party
image. A rented GPU instance costs more per month than a GitHub Copilot subscription, every
month, whether or not anyone is typing. If the box you have has no GPU, stop here rather than at
step 7.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
nvidia-smi | head -3
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64`, one GPU line with
at least 8000 MiB of memory, a `CUDA Version` of 12.4 or higher in the `nvidia-smi` header, and
your server's IP on the last line.

If you do not: `nvidia-smi: command not found` means this machine has no NVIDIA driver, and this
install cannot proceed on it. Installing a kernel driver yourself on a rented box is a fight
with the provider's image and is out of scope here; rebuild the instance from a GPU image that
ships the driver. A `CUDA Version` below 12.4 means the driver is older than the image expects,
which shows up later as an inference process that starts and dies. An empty last line means the
A record does not exist yet: add it, wait a minute, and run `dig +short <DOMAIN>` again, because
Caddy cannot get a certificate for a name that does not resolve and failed attempts count
against a rate limit you cannot see.

## 2. Layout and the GPU runtime

Prompt Zero installed Docker but not the NVIDIA Container Toolkit, which is what lets Docker
hand the card to a container. Paste this whole block.

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

You should see: a 1.6 GB image pull, then one `GPU 0:` line naming the same card step 1 saw,
then `backups` owned by you and `data` at mode `drwx------` owned by root.

If you do not: `could not select device driver with capabilities: [[gpu]]` means the toolkit is
installed but Docker never reloaded its configuration, so run `sudo systemctl restart docker`
again and repeat the `docker run` line. `E: Unable to locate package nvidia-container-toolkit`
means the apt source line did not land, so check that
/etc/apt/sources.list.d/nvidia-container-toolkit.list holds one line and re-run `apt-get update`.
Leave `data` owned by root: the container starts as root inside its own namespace and sets that
directory to 700 itself on every start.

## 3. Secrets

One secret: the key Tabby signs its session tokens with. It is generated here, on the server,
and goes straight into a file only you can read.

```bash
umask 077
cat > /srv/tabby/.env <<EOF
TABBY_WEBSERVER_JWT_TOKEN_SECRET=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
EOF
chmod 600 /srv/tabby/.env
umask 022
ls -l /srv/tabby/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Read the value once
with `sudo grep TABBY_WEBSERVER /srv/tabby/.env` and put it in your password manager.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/tabby/.env` and carry
on. The 8-4-4-4-12 shape is not decoration: Tabby exits rather than warning if this value does
not parse as a UUID, and the `sed` is what turns 128 bits of `openssl` entropy into that shape.
Without the variable the server invents a new key every time it starts, which signs everyone out
on every restart.

Do not paste that file, the secret, or any command output containing it into this chat window.
The agent path never sees the value; this one will hand it to a third party unless you keep it
out.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/tabby/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal,
so run `rm /srv/tabby/compose.yml` and paste again in one go. The two model names are the pinned
part of the model choice: Tabby resolves each name against its registry and checks the file it
downloads against the SHA-256 the registry publishes, so a corrupted or substituted file is
fetched again rather than served.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-tabby /etc/caddy/Caddyfile`, reload, and
paste again. Caddy requests the certificate on the first request to the hostname and renews it
on its own, so there is nothing to schedule and nothing to put in cron.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8134` or `8080`.

If you do not: delete anything for 8134 with `sudo ufw delete allow 8134`. 8134 is bound to
127.0.0.1 by the compose file, so Caddy is the only thing that can reach it and a firewall rule
would only widen that. The inference processes Tabby starts take ports above 30888 on loopback
inside the container's own namespace and never reach the host at all. `Status: inactive` is a
different problem: Prompt Zero left this firewall enabled, so something has turned it off since,
and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The first start downloads about 3 GB of model files before anything answers. Expect the loop
below to print `000` for a long time. Do not interrupt it.

```bash
cd /srv/tabby
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 20; done
curl -sS -H 'Content-Type: application/json' -d '{"query":"{ serverInfo { isAdminInitialized isChatEnabled allowSelfSignup } }"}' https://<DOMAIN>/graphql; echo
docker compose logs --tail 5 tabby
```

You should see, in order: the loop reaching `200`, then a JSON object containing
`"isAdminInitialized":false` and `"isChatEnabled":true`, then a log tail with the `Listening at`
banner in it.

If you do not: run `docker compose logs --tail 60 tabby` and read for one of three things. A
line containing `libcuda.so.1` or `could not select device driver` means step 2 did not finish,
so repeat it. A process that exits right after saying something about a UUID means the value in
.env is not in the 8-4-4-4-12 shape, so redo step 3. A Caddy `502` against a container that
`docker compose ps` calls healthy means step 5, not step 7. If the log is still printing download
progress, nothing is wrong: it is fetching three model files, and a restart mid-download leaves a
partial file that fails its checksum and is fetched again from the start.

Now open https://<DOMAIN> in a browser. A server with no administrator sends you to
https://<DOMAIN>/auth/signup?isAdmin=true, whose first screen reads `Welcome!` above
`Your tabby server is live and ready to use.` with a `Start` button. The step after it is headed
`Create Admin Account` and tells you the password cannot be recovered, which is true: there is no
mail server here to send you a reset. Save it as you type it, then confirm the window is closed:

```bash
curl -sS -H 'Content-Type: application/json' -d '{"query":"{ serverInfo { isAdminInitialized allowSelfSignup } }"}' https://<DOMAIN>/graphql; echo
```

You should see: `"isAdminInitialized":true` and `"allowSelfSignup":false`.

If you do not: `"isAdminInitialized":false` means the account was not created and the next
stranger who loads that hostname can still claim your server, so go back and finish the form
before anything else. The `allowSelfSignup` half is the security check worth understanding.
Tabby offers self-registration only when an SMTP server and an allowed email domain are both
configured, and this install has neither, so from here a second person gets an account only from
an invitation you send. A green `docker compose ps` on its own is not success; these two fields
are. Your own editor is the last step: install a Tabby extension there and point it at this
server with a token from the dashboard.

## 8. First backup and restore

One archive: the accounts database, the compose file, the secret and the live Caddy site block.
The model files under data/models are deliberately left out. They are 3 GB, they are
re-downloadable, and Tabby checks them against a published SHA-256 on every start.

```bash
cd /srv/tabby
docker compose stop
sudo tar -czf /srv/tabby/backups/tabby-$(date +%F).tar.gz -C /srv/tabby data/ee compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/tabby/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install. The container is stopped
for a few seconds on purpose, because a SQLite database copied mid-write is not a backup.

If you do not: a `tar: data/ee: Cannot stat` error means step 7 never got far enough to create
the database, so the server has not run yet and there is nothing to back up. Fix step 7 first.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/tabby
scp vps:/srv/tabby/backups/*.tar.gz ~/backups/tabby/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/tabby/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one account:

```bash
cd /srv/tabby
docker compose down
sudo rm -rf /srv/tabby/data/ee
sudo tar -xzf /srv/tabby/backups/tabby-$(date +%F).tar.gz -C /srv/tabby data/ee
docker compose up -d
sleep 60
curl -sS -H 'Content-Type: application/json' -d '{"query":"{ serverInfo { isAdminInitialized } }"}' https://<DOMAIN>/graphql; echo
```

You should see: `"isAdminInitialized":true`, which means the account survived a database that was
deleted and put back.

If you do not: sixty seconds may not be enough, because the models are checked against their
checksums on the way up. Wait and run the last line again before concluding anything. Understand
what the stakes are: `data/ee/db.sqlite` holds your account, the access tokens your editors use,
and every repository you have connected, and `.env` holds the key that validates existing
sessions, so a database restored without its .env signs everyone out. Upstream states that Tabby
does not support downgrading, which makes this archive the only way back from an upgrade that
goes wrong.

## 9. Updating later

New versions are listed at https://github.com/TabbyML/tabby/releases. The Docker tag drops the
leading `v`, so release `v0.33.0` is image tag `0.33.0`. Take the backup from step 8 first,
because there is no downgrade path, then edit the `image:` line in /srv/tabby/compose.yml to the
new tag and its digest.

```bash
cd /srv/tabby
docker compose pull
docker compose up -d
docker compose logs --tail 30 tabby
```

You should see: migration output, then the `Listening at` banner, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
GraphQL check from step 7 before you call the update done, because a server that answers on the
dashboard can still be failing to serve completions if a model file changed name upstream.

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
  you register yourself, and this install gives you the server it would talk to.
- Do not raise `--parallelism` or swap in a larger model. Both multiply the GPU memory needed,
  and step 1 measured the card for the two models in compose.yml.
