You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Karakeep 0.33.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and it becomes `NEXTAUTH_URL` in step 3.

Say this to the user first. Karakeep saves a page by driving a real headless browser inside this
server's network, so anyone with an account can make this box fetch a URL of their choosing and
read the result. Upstream's first mitigation is limiting access to trusted users, and the first
person to register is the administrator. Step 7 closes signups and proves it.

Karakeep needs 4096 MB of RAM available and 20 GB free on /srv. All three images publish amd64
and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both and stop. The memory
floor is a headless Chrome while Meilisearch holds its index; the disk floor is the third month
of screenshots. If `dig +short` prints nothing, print that and stop too.

## 2. Layout

Four directories, two owners: the Karakeep and Meilisearch images run as root and write to
their mounts, so those two stay with root.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/karakeep /srv/karakeep/backups
sudo install -d -m 750 /srv/karakeep/data /srv/karakeep/meili
ls -la /srv/karakeep
```

Assert: `backups` owned by the login user, `data` and `meili` owned by `root`, all mode `750`.
Keep `data` on local disk: SQLite on a network mount corrupts.

## 3. Secrets

Two secrets. `NEXTAUTH_SECRET` signs the session tokens; `MEILI_MASTER_KEY` is the only
credential the search engine accepts. Upstream documents the generator below for both, base64
for the first and alphanumerics only for the second. Generate both on the server, do not print
either, and keep them out of your summary and every log line. Two values here are not secrets:
`NEXTAUTH_URL` is the address Karakeep hands out, and `DISABLE_SIGNUPS` is open for one step,
until step 7 closes it.

```bash
umask 077
cat > /srv/karakeep/.env <<EOF
NEXTAUTH_URL=https://<DOMAIN>
DISABLE_SIGNUPS=false
NEXTAUTH_SECRET=$(openssl rand -base64 36)
MEILI_MASTER_KEY=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9')
EOF
chmod 600 /srv/karakeep/.env
umask 022
ls -l /srv/karakeep/.env
```

Assert: mode `-rw-------`, and `NEXTAUTH_URL` reads `https://` and the real hostname. The user
reads both with `sudo grep -E 'NEXTAUTH_SECRET|MEILI' /srv/karakeep/.env`.

## 4. compose.yml

```bash
cat > /srv/karakeep/compose.yml <<'EOF'
# Karakeep · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.karakeep.app/installation/docker
#   configuration ...... https://docs.karakeep.app/configuration/environment-variables
#   minimal install .... https://docs.karakeep.app/installation/minimal-install
#   image build ........ https://github.com/karakeep-app/karakeep/blob/v0.33.2/docker/Dockerfile
#
# Three services. `web` is upstream's all-in-one image: app, workers and the
# migration under s6, with SQLite in /data, so no Postgres appears here.
# `chrome` renders and screenshots pages; upstream says that without it
# javascript pages crawl badly. `meilisearch` is the search engine, without
# which upstream says search is disabled completely; it is pinned to the
# 1.41.0 Karakeep is built against, not the newer line on Meilisearch's own
# page here. MEILI_MASTER_KEY comes from the .env beside this file, so run
# compose from /srv/karakeep. Digests read 2026-08-14; all three ship arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  meilisearch:
    image: getmeili/meilisearch:v1.41.0@sha256:860fa4baed04ae1c235de870edab0c8006227546dea1bbb6411fbfc5e27cf1db
    container_name: karakeep-meilisearch
    restart: unless-stopped
    environment:
      # Production mode refuses to start without a master key.
      MEILI_ENV: production
      MEILI_MASTER_KEY: ${MEILI_MASTER_KEY}
      MEILI_NO_ANALYTICS: "true"
    volumes:
      # The index. Rebuilt from the database, so step 8 leaves it out.
      - /srv/karakeep/meili:/meili_data
    # No `ports:`: 7700 is reachable only from the other containers.

  chrome:
    image: ghcr.io/karakeep-app/karakeep-chrome:151.0.7922.47-r1@sha256:5b19bbb160e9ff60681a3abd97e1c4ec9f64212301410de658c3900ab7ef31e7
    container_name: karakeep-chrome
    restart: unless-stopped
    init: true
    command:
      - --disable-gpu
      - --disable-dev-shm-usage
      - --hide-scrollbars
      - --disable-blink-features=AutomationControlled
      - --window-size=1440,900
    # No `ports:` and no volume: 9222 remote-controls a real browser with no
    # credential, and only the web container shares this network.

  web:
    image: ghcr.io/karakeep-app/karakeep:0.33.2@sha256:b069e4307dec06ea06d16989c6861c30a1ff208568be44ed5fb5d422cd3e950c
    container_name: karakeep
    restart: unless-stopped
    env_file: /srv/karakeep/.env
    environment:
      MEILI_ADDR: http://meilisearch:7700
      BROWSER_WEB_URL: http://chrome:9222
      # Upstream's compose says DON'T CHANGE THIS. The mount moves.
      DATA_DIR: /data
      # The image ships debug. `info` is the quietest level it defines.
      LOG_LEVEL: info
    volumes:
      # The SQLite database and every archived asset: the product.
      - /srv/karakeep/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8182.
      - "127.0.0.1:8182:3000"
    # Start ordering only: web connects to both lazily and retries.
    depends_on:
      - meilisearch
      - chrome
EOF
cd /srv/karakeep && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`, with no warning that `MEILI_MASTER_KEY` is unset. Compose
reads it from the .env beside this file, so such a warning means the wrong directory: run every
compose command from /srv/karakeep.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-karakeep
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Karakeep · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.karakeep.app/installation/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also NEXTAUTH_URL in .env, https:// and no trailing slash: Caddy speaks plain
# http to the container, so that variable is what tells Karakeep it is https.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# One list can be public while the rest of the app sits behind a
		# login on the same hostname. SAMEORIGIN protects the second half.
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8182 is the loopback port compose publishes on this host: not a container
	# port, and not open in the firewall. Caddy sets no body limit, so an
	# upload's ceiling is MAX_ASSET_SIZE_MB, default 50.
	reverse_proxy 127.0.0.1:8182
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-karakeep, reload, and report what it objected to. This hostname and
`NEXTAUTH_URL` must match. Caddy gets the certificate on first request and renews it.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8182 is bound to 127.0.0.1, and 7700 and 9222 are never published; 9222 is the one that
matters, because it remote-controls a browser with no credential. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8182, 7700 or 9222.

## 7. Start and verify

The web image runs the migration, the app and the workers together under s6, so the first boot
writes the schema before it answers. The pull is about a gigabyte, so use the loop.

```bash
cd /srv/karakeep
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health; echo
curl -sSL https://<DOMAIN>/signin | grep -c 'Welcome Back'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/bookmarks
docker compose exec -T web curl -sS -o /dev/null -w '%{http_code}\n' http://meilisearch:7700/indexes
curl -sSL https://<DOMAIN>/signup | grep -c 'Create Your Account'
```

Assert all six, printing what you received. The loop ends at `200`. The health call prints
`{"status":"ok","message":"Web app is working"}`. The third is above `0`: `Welcome Back` is the
sign-in heading, the first screen here. The REST call prints `401`, and Meilisearch prints `401`
from inside the compose network, which is what `MEILI_MASTER_KEY` bought. The last is above `0`:
the open door.

On any miss, stop, run `docker compose logs --tail 40 web`, then
`docker compose logs --tail 20 meilisearch`, and name the earlier step. A 502 with all three up
points at step 5; a Meilisearch answering `200` means the master key never reached it, which is
step 4 and the working directory. A running container is not success.

STOP: tell the user to open https://<DOMAIN>/signup now, create their account with a password
their password manager generates, and wait. Do not continue until they confirm. Say why the
hurry: the first account created here is the administrator, and until they make it that offer
stands for anyone who knows the hostname.

Once they confirm, shut the door and prove it is shut:

```bash
sed -i 's/^DISABLE_SIGNUPS=false$/DISABLE_SIGNUPS=true/' /srv/karakeep/.env
cd /srv/karakeep && docker compose up -d --force-recreate --no-deps web
sleep 20
docker compose exec -T web printenv DISABLE_SIGNUPS
curl -sSL https://<DOMAIN>/signup | grep -c 'Create Your Account'
```

Assert both: `printenv` prints `true` from inside the running container, and the grep prints
`0`. Both must pass before you report success. The recreate matters and a restart will not do:
compose reads `.env` only when it creates a container, so `docker compose restart` would leave
registration open. If `printenv` prints `false`, recreate again and do not go on.

STOP: tell the user to sign in, paste any article URL into the bookmark box, and watch that card
for a minute. Do not continue until they confirm they see a real title rather than a bare URL.
That one card is the app, a worker, Chrome and the search engine all answering.

## 8. First backup and restore

One archive: the database and every archived asset, the environment file, the compose file and
the live Caddy site block. The index is left out, because Meilisearch rebuilds it from the
database with Reindex All Bookmarks.

```bash
cd /srv/karakeep
docker compose stop
sudo tar -czf /srv/karakeep/backups/karakeep-$(date +%F).tar.gz -C /srv/karakeep data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/karakeep/backups/
```

Assert: the archive exists and is non-empty. Print its size. The containers are stopped because
a SQLite file copied mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/karakeep
scp vps:/srv/karakeep/backups/*.tar.gz ~/backups/karakeep/
```

To restore: `docker compose down`, `sudo rm -rf /srv/karakeep/data /srv/karakeep/meili`,
recreate both as in step 2, untar the archive into /srv/karakeep, restore the Caddy block if
that is what was lost, then `docker compose up -d` and reindex. `.env` has to be in place before
that first start, or a container created without `MEILI_MASTER_KEY` writes an index the restored
key cannot open. `data` holds every bookmark, highlight and archived page.

## 9. Updating later

New versions are listed at https://github.com/karakeep-app/karakeep/releases. The release tag
carries a `v` and the image tag does not, so `v0.34.0` is image tag `0.34.0`. Back up
first, then edit the `web` image line in compose.yml to the new tag and digest:

```bash
cd /srv/karakeep
docker compose pull
docker compose up -d
docker compose logs --tail 30 web
```

Leave Meilisearch alone. It is pinned to 1.41.0 on purpose: upstream names that as the version
Karakeep is built against and advises against upgrading it alone, because a newer engine refuses
an older index, and the recovery is erasing `data.ms` and reindexing every bookmark. Karakeep
migrates its own schema on the way up, so watch that log settle, then re-run step 7's health
check.

## 10. What will probably go wrong

The first bookmark will look like a broken install. I pasted a URL, got a card with the raw
address on it and nothing else, refreshed twice and started reading logs. Nothing was wrong: the
crawl is a background job, the browser has to start, render and screenshot the page, and on a
small box the first one took most of a minute while the card sat there empty, and the page does
not refresh itself. Give it sixty seconds and reload before touching anything. If the title is
still missing, read `docker compose logs --tail 40 web` for the crawler line rather than
restarting: a failed crawl says so, and the usual cause is a Chrome container that never came up.

## 11. Out of scope

- Do not set `OPENAI_API_KEY` or `OLLAMA_BASE_URL`. AI tagging bills the user's own account.
- Do not turn on `CRAWLER_FULL_PAGE_ARCHIVE`, `CRAWLER_STORE_PDF` or `CRAWLER_VIDEO_DOWNLOAD`.
  Each multiplies the disk this install eats, and that trade wants a month of usage first.
- Do not configure SMTP or `EMAIL_VERIFICATION_REQUIRED`. There is nobody to mail on a
  one-account install, and verification on a closed instance locks the owner out.
- Do not publish 3000, 7700 or 9222 or open them in the firewall. 9222 drives a browser for
  whoever reaches it.
