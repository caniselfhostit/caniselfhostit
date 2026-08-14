This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Karakeep 0.33.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1, because it decides whether you want this at all. Karakeep saves a page
by driving a real headless browser inside your server's network, so anyone who holds an account
here can make this box fetch a URL of their choosing and then read the result. Upstream's first
mitigation for that is limiting access to trusted users, and Karakeep gives the administrator
role to whoever registers while the users table is empty. Step 7 is where you claim that account
and shut the door behind you, and the minutes between starting the containers and finishing that
form are the only window this install has.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that does
not resolve and failed attempts count against a rate limit you cannot see. On the memory line,
4096 MB is not padding: a headless Chrome renders a full page while Meilisearch holds its index
in memory, and a 2 GB box gets through the install and then starts losing crawls to the OOM
killer, which looks random and is not. The 20 GB is about the third month rather than the first
day, because every crawled link can leave a screenshot and a cached image behind.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/karakeep /srv/karakeep/backups
sudo install -d -m 750 /srv/karakeep/data /srv/karakeep/meili
ls -la /srv/karakeep
```

You should see: `backups` owned by you, `data` and `meili` owned by `root`, all at mode `750`.

If you do not: those owners are deliberate. The Karakeep image and the Meilisearch image both
run as root inside their containers and write to their mounts, so a directory owned by your
login user is one they would have to be given permission for, and root-owned is the honest
answer rather than a chmod that hides the question. Keep `/srv/karakeep/data` on the server's
local disk: the database is a SQLite file, and a network mount corrupts one quietly, weeks
later, in a way no error message names.

## 3. Secrets

Two secrets, both generated here on the server, both landing in a file only you can read.
`NEXTAUTH_SECRET` signs your session tokens. `MEILI_MASTER_KEY` is the only credential the
search engine accepts, and upstream documents this exact pair of commands for them. Two more
values sit in the same file and are not secrets: `NEXTAUTH_URL` is the public address Karakeep
hands out, spelled `https://` with no trailing slash, and `DISABLE_SIGNUPS` is open for exactly
one step.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when
the lines are pasted separately into different shells. Run `chmod 600 /srv/karakeep/.env` and
carry on. If the file already existed from an earlier attempt this block has now replaced both
secrets, which is harmless before the first start and awkward after: a new `MEILI_MASTER_KEY`
cannot open an index written under the old one, and the fix is Reindex All Bookmarks from the
admin screens once you are signed in.

Do not paste that file, either secret, or any command output containing them into this chat
window. Read them yourself with
`sudo grep -E 'NEXTAUTH_SECRET|MEILI_MASTER_KEY' /srv/karakeep/.env` and put them in your
password manager. Changing `NEXTAUTH_SECRET` later signs everybody out.

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

You should see: `compose OK` and nothing else.

If you do not: a complaint about `MEILI_MASTER_KEY` being unset means you ran this from another
directory. Docker compose reads `.env` from the folder the compose file lives in, so every
compose command in this install runs after `cd /srv/karakeep`. A YAML error usually means the
heredoc was pasted in two pieces; delete the file and paste the whole block at once. Three
services here, and each one buys something named: the web container is the app, the workers and
the database migration together, the chrome container renders and screenshots pages, and
Meilisearch is the search engine that upstream says is the difference between search working and
search being switched off entirely.

## 5. Caddy and TLS

Copy the Caddyfile first. A syntax error here takes down every other site on this box.

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

You should see: `Valid configuration` from validate, and no output at all from the reload.
Replace `<DOMAIN>` in the block with your real hostname before you paste.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-karakeep /etc/caddy/Caddyfile`, reload, and read what
validate objected to. The usual cause is a `<DOMAIN>` left literal, which Caddy reads as a
hostname it is being asked to certify. The hostname in this block and `NEXTAUTH_URL` in .env
have to be the same string: Caddy terminates TLS and speaks plain http to the container, so that
variable is the only thing telling Karakeep its outside address is https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 80/tcp, 443/tcp and 443/udp. Nothing for 8182,
7700, 9222 or 3000.

If you do not: an inactive firewall means Prompt Zero did not finish, and you should go back
rather than carry on. If a rule for 8182 is listed from an earlier attempt, remove it with
`sudo ufw delete allow 8182`. 8182 is bound to 127.0.0.1 by the compose file, so Caddy reaches
it and nothing else can. 7700 and 9222 are never published at all, and 9222 is the one that
would matter: it remote-controls a real browser for anything that can open a socket to it.

## 7. Start and verify

The web image runs the database migration, the app and the background workers together, so the
first boot writes the schema before it answers anything. The first pull is roughly a gigabyte
across three images, so the loop below is doing real waiting rather than being polite.

```bash
cd /srv/karakeep
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
```

You should see: a column of numbers ending in `200`. The first several are usually `502` or
`000` while the images pull and the schema is written.

If you do not: if it never leaves `000`, the certificate is the problem, and
`sudo journalctl -u caddy --since -10min | tail -30` says so. If it sits at `502` with all three
containers running, Caddy is reaching the wrong port, so re-read step 5. If a container is
missing from `docker compose ps`, read `docker compose logs --tail 40 web`.

```bash
curl -sS https://<DOMAIN>/api/health; echo
curl -sSL https://<DOMAIN>/signin | grep -c 'Welcome Back'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/bookmarks
docker compose exec -T web curl -sS -o /dev/null -w '%{http_code}\n' http://meilisearch:7700/indexes
curl -sSL https://<DOMAIN>/signup | grep -c 'Create Your Account'
```

You should see: `{"status":"ok","message":"Web app is working"}`, then a number above `0`, then
`401`, then `401`, then a number above `0`.

If you do not: a `200` from the Meilisearch line instead of `401` means the master key never
reached that container, which is step 4 and the directory you ran it from, and it matters
because an unauthenticated search engine on your compose network will hand its whole index to
anything that can reach it. A `0` from the `Welcome Back` count with a healthy `/api/health`
means Caddy is proxying to something other than Karakeep. Anything other than `401` from the
bookmarks call means the API is answering unauthenticated requests, and you should stop and
work out why before going further.

Now claim the instance. That last count above `0` is a registration form open to whoever loads
this hostname, and the first account created on it becomes the administrator.

Open https://<DOMAIN>/signup in a browser, create your account with a password your password
manager generates, and come straight back. Do not wander off in the middle of this.

```bash
sed -i 's/^DISABLE_SIGNUPS=false$/DISABLE_SIGNUPS=true/' /srv/karakeep/.env
cd /srv/karakeep && docker compose up -d --force-recreate --no-deps web
sleep 20
docker compose exec -T web printenv DISABLE_SIGNUPS
curl -sSL https://<DOMAIN>/signup | grep -c 'Create Your Account'
```

You should see: `true`, then `0`.

If you do not: `false` from `printenv` means the container was not recreated. A plain
`docker compose restart` will not do it, because compose reads `.env` when it creates a
container and not when it restarts one, so the page keeps offering registrations while the file
on disk says otherwise. Run the `up -d --force-recreate --no-deps web` line again and check
again. Do not treat this install as finished until both lines are right.

Now sign in at https://<DOMAIN>, paste any article URL into the bookmark box, and watch that
card for a minute. When a real title and a preview image replace the bare URL, the whole stack
has answered at once: the app took it, a worker queued it, the chrome container rendered it, and
Meilisearch indexed it.

## 8. First backup and restore

One archive: the SQLite database and every archived asset, the environment file, the compose
file, and the live Caddy site block. The search index is deliberately left out, because
Meilisearch rebuilds from the database with Reindex All Bookmarks in the admin screens and an
index is not worth carrying twice.

```bash
cd /srv/karakeep
docker compose stop
sudo tar -czf /srv/karakeep/backups/karakeep-$(date +%F).tar.gz -C /srv/karakeep data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/karakeep/backups/
```

You should see: one `.tar.gz` with a real size next to it, and the site answering again within a
few seconds.

If you do not: a `tar: Removing leading /` warning is normal and not an error. A zero-byte
archive means the `-C /srv/karakeep` path is wrong for your install. The containers are stopped
on purpose: a SQLite file copied while it is being written is not a backup, it is a file that
restores into a database with a hole in it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not on
the server:

```bash
mkdir -p ~/backups/karakeep
scp vps:/srv/karakeep/backups/*.tar.gz ~/backups/karakeep/
```

To restore, cold, at 2am: `cd /srv/karakeep`, `docker compose down`, then
`sudo rm -rf /srv/karakeep/data /srv/karakeep/meili`, recreate both directories exactly as in
step 2, untar the archive back into /srv/karakeep, put the Caddy block back into
/etc/caddy/Caddyfile if that is what was lost, then `docker compose up -d` and run Reindex All
Bookmarks once you are signed in. The order matters: `.env` has to be in place before the first
start, because a container created without `MEILI_MASTER_KEY` writes an index that the restored
key cannot open. What is in that archive, in plain terms: `data` is every bookmark, every
highlight, every archived page and your own account, and `.env` is the key that opens your
sessions and the search index.

## 9. Updating later

New versions are listed at https://github.com/karakeep-app/karakeep/releases. The release tag
carries a `v` and the image tag does not, so release `v0.34.0` is image tag `0.34.0`. Take a
backup first, then edit the `web` image line in /srv/karakeep/compose.yml to the new tag and its
digest, and run:

```bash
cd /srv/karakeep
docker compose pull
docker compose up -d
docker compose logs --tail 30 web
```

You should see: the migration lines scroll past, then the app reporting it is listening.

If you do not: leave Meilisearch alone while you debug. It is pinned to 1.41.0 on purpose,
because upstream names that as the version Karakeep is built against and advises against
upgrading it by itself: a newer engine refuses to open an older index, and the recovery upstream
documents is stopping that container, erasing the `data.ms` folder inside /srv/karakeep/meili,
starting it again, and reindexing every bookmark. Karakeep migrates its own SQLite schema on the
way up, so let that log settle before you decide anything is wrong, then re-run the health check
and the `Welcome Back` count from step 7.

## 10. What will probably go wrong

Your first bookmark will look like a broken install. I pasted a URL, got a card with the raw
address on it and nothing else, refreshed twice and started reading logs. Nothing was wrong: the
crawl is a background job, the browser has to start, render and screenshot the page, and on a
small box the first one took most of a minute while the card sat there empty. The page does not
refresh itself while you watch it either. Give it sixty seconds and reload before touching
anything. If the title is still missing, read `docker compose logs --tail 40 web` and look for
the crawler line rather than restarting: a crawl that failed says so, and the usual cause is a
chrome container that never came up, which `docker compose ps` shows in one line.

## 11. Out of scope

- Do not set `OPENAI_API_KEY` or `OLLAMA_BASE_URL` today. AI tagging is the piece of this that
  bills your own account, and it is worth adding deliberately once the rest is boring.
- Do not turn on `CRAWLER_FULL_PAGE_ARCHIVE`, `CRAWLER_STORE_PDF` or `CRAWLER_VIDEO_DOWNLOAD`.
  Each multiplies the disk this install eats, and that trade wants a month of real usage first.
- Do not configure SMTP or `EMAIL_VERIFICATION_REQUIRED`. There is nobody to mail on a
  single-account install, and verification on a closed instance locks you out of your own box.
- Do not publish 3000, 7700 or 9222 on the host or open them in the firewall. Caddy is the only
  way in, and 9222 drives a browser for whoever reaches it.
