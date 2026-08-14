You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Crawl4AI 0.9.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say three things to the user first. One: this is a crawling API, not a website with accounts.
There is no sign-in to finish and no admin user to claim; they get an HTTP endpoint that turns a
URL into markdown or JSON. Two: the token is not a nicety. The entrypoint binds the server to
container loopback whenever no credential is configured, so an install without a token publishes
a port that answers nothing. Step 3 generates it. Three: what they crawl is their responsibility.
The crawler does not consult robots.txt unless a request asks it to, and nothing here enforces a
site's terms of service.

Crawl4AI needs 4096 MB of RAM available and 15 GB free on /srv, because the image carries a real
Chromium and starts one on the way up. It publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 15 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
hostname that does not resolve. The image is about 1.5 GB to download and more on disk once
unpacked, which is the slowest part of this install.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/crawl4ai /srv/crawl4ai/backups
ls -la /srv/crawl4ai
```

Assert: both directories exist and are owned by the login user. There is no `data/` directory,
which is deliberate: this compose file mounts nothing, and the crawl cache, the artifact store
and the in-container Redis are disposable.

## 3. Secrets

One secret: `CRAWL4AI_API_TOKEN`. Generate it on the server. Do not print it, do not repeat it
in your summary, and do not put it in any log line. Upstream's startup message suggests this form.

```bash
umask 077
cat > /srv/crawl4ai/.env <<EOF
CRAWL4AI_API_TOKEN=$(openssl rand -hex 32)
EOF
chmod 600 /srv/crawl4ai/.env
umask 022
ls -la /srv/crawl4ai/.env
```

Assert: `.env` is mode `-rw-------`. Print only the path, never the value. Tell the user the
token lives in /srv/crawl4ai/.env, that they read it with
`sudo grep CRAWL4AI_API_TOKEN /srv/crawl4ai/.env`, and that it belongs in their password manager.
Be plain about what it is: admin-scoped, with no read-only alternative on this install. Anyone
holding it can make this server fetch any URL it can reach, including private addresses.

## 4. compose.yml

```bash
cat > /srv/crawl4ai/compose.yml <<'EOF'
# Crawl4AI · the deterministic fallback. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker guide ........ https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/README.md
#   server config ....... https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/config.yml
#   bind and auth ....... https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/entrypoint.sh
#   license ............. https://github.com/unclecode/crawl4ai/blob/v0.9.2/LICENSE
#
# One container. The image bakes Chromium in through Playwright and runs its own
# Redis on container loopback, so there is no second service and no database.
# CRAWL4AI_API_TOKEN comes from env_file and is not optional: entrypoint.sh
# binds gunicorn to container loopback when no credential is set, and the
# published port would then reach nothing. GUNICORN_BIND is spelled out so the
# bind does not depend on IPv6. Tag and digest are the 0.9.2 release read from
# Docker Hub on 2026-08-14; the manifest list carries amd64 and arm64.
#
# Nothing is mounted on purpose: the crawl cache, the artifact store and the
# Redis working directory live inside the container and are disposable.
# Upstream's compose adds read_only with a tmpfs list keyed to uid 999, not
# copied here because the image creates its runtime user with `useradd -r`
# after installing redis-server, so that uid is not knowable from the source
# and a wrong one leaves Redis unable to write.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  crawl4ai:
    image: unclecode/crawl4ai:0.9.2@sha256:bd36741e7bdd35ddc1a05d9183e1d6d8cefb61dd640d944a25d026b76e917690
    container_name: crawl4ai
    restart: unless-stopped
    env_file: /srv/crawl4ai/.env
    environment:
      # entrypoint.sh honours GUNICORN_BIND only when a credential is present.
      GUNICORN_BIND: "0.0.0.0:11235"
    # Chromium wants shared memory. Without this it dies on heavy pages.
    shm_size: "1gb"
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    pids_limit: 512
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11235/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8198.
      - "127.0.0.1:8198:11235"
EOF
cd /srv/crawl4ai && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no volumes, no database.
Do not add a Caddy service to this file.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-crawl4ai
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Crawl4AI · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/unclecode/crawl4ai/blob/v0.9.2/deploy/docker/README.md and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project. Auth is the
# CRAWL4AI_API_TOKEN inside the container, not a browser login form: every API
# route answers 401 without an Authorization: Bearer header, and the application
# sets its own security headers, so this block adds only HSTS.
#
# Three prefixes stay public because the application serves them publicly:
# /playground, /dashboard and /static are static shells holding no data that
# cannot call the API without the token. /health is public because the
# container's healthcheck calls it. To stop serving the shells, add these two
# lines inside the site block, above reverse_proxy:
#
#	@ui path / /playground* /dashboard* /static*
#	respond @ui 404

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		-Server
	}

	# 8198 is the loopback port compose publishes; it is never in the firewall.
	# A slow crawl holds the connection open for a minute. Caddy sets no read
	# timeout on a reverse-proxied response by default, so that is fine.
	reverse_proxy 127.0.0.1:8198
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: validate and reload both exit 0. If validate fails, restore
/etc/caddy/Caddyfile.before-crawl4ai and reload, then report what it objected to. Caddy requests
the certificate on first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3. 8198 stays closed because compose binds it to 127.0.0.1, and 11235 is a
container port never published to the host. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule mentioning 8198 or 11235.

## 7. Start and verify

The first start pulls about 1.5 GB and launches Chromium, so allow a couple of minutes.

```bash
cd /srv/crawl4ai
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8198/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://127.0.0.1:8198/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/md -H 'Content-Type: application/json' --data-binary '{"url":"https://example.com","f":"raw"}'
TOKEN=$(grep CRAWL4AI_API_TOKEN /srv/crawl4ai/.env | cut -d= -f2-)
curl -sS -X POST https://<DOMAIN>/md -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' --data-binary '{"url":"https://example.com","f":"raw"}' | head -c 300; echo
unset TOKEN
curl -sSL https://<DOMAIN>/playground/ | grep -c '<title>Crawl4AI Playground</title>'
```

Assert all five, and print what each returned, never the token. The health loop ends on `200`
and the body contains `"status":"ok"`. The unauthenticated POST to `/md` prints `401`: that is the
security assert in this block. The authenticated POST returns JSON whose `markdown` field contains
`Example Domain`; `"f":"raw"` asks for the direct conversion, because the default readability
filter can prune a page this small down to nothing. The last command prints `1`.

If any assert misses, stop and run `docker compose logs --tail 40 crawl4ai`. A log line about
binding loopback only means `.env` did not load, which is step 3 or step 4. A 502 from Caddy with
a healthy container is step 5. A running container is not success. There is no sign-in page:
https://<DOMAIN>/ redirects to the playground UI, which does nothing until a token is pasted in.

STOP: tell the user to read their token with `sudo grep CRAWL4AI_API_TOKEN /srv/crawl4ai/.env`,
store it in their password manager, and understand that it is admin-scoped: there is no read-only
key to hand out, and pasting it into a browser on a shared machine hands over the whole crawler.
Do not continue until they confirm.

Once they confirm, run the core loop: a real crawl returning real markdown.

```bash
TOKEN=$(grep CRAWL4AI_API_TOKEN /srv/crawl4ai/.env | cut -d= -f2-)
curl -sS -X POST https://<DOMAIN>/crawl \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary '{"urls":["https://example.com"],"crawler_config":{"type":"CrawlerRunConfig","params":{"check_robots_txt":true}}}' \
  | head -c 600; echo
unset TOKEN
```

Assert: the response starts `{"success":true` and the results array carries the crawled page.
That is the product: a URL in, structured JSON with a markdown field out. `check_robots_txt` is
there on purpose, because it defaults to false and the user should see where the polite setting
lives. Tell them this endpoint is what their scripts call, and that a schedule is their own cron
entry calling this URL, because nothing here runs one.

## 8. First backup and restore

There is no application state to archive. This service mounts no volumes, so the backup is the
three files that rebuild it: the token, the compose file and the live Caddy site block. Say that
to the user rather than letting them think an archive is protecting crawl results.

```bash
cd /srv/crawl4ai
sudo tar -czf /srv/crawl4ai/backups/crawl4ai-$(date +%F).tar.gz -C /srv/crawl4ai .env compose.yml -C /etc/caddy Caddyfile
ls -lh /srv/crawl4ai/backups/
```

Assert: the archive exists and is non-empty. Print its size. No downtime, because nothing is
being written. Treat the archive as secret material: it holds the API token. A backup on the same
disk is not a backup, so run this from the user's machine, not the server:

```bash
mkdir -p ~/backups/crawl4ai
scp vps:/srv/crawl4ai/backups/*.tar.gz ~/backups/crawl4ai/
```

To restore on a fresh box: complete Prompt Zero, recreate the directories from step 2, untar the
archive into /srv/crawl4ai to bring back `.env` and `compose.yml`, append the archived Caddyfile
block to /etc/caddy/Caddyfile with the hostname substituted, validate and reload Caddy, then
`docker compose up -d` and re-run step 7's checks. Restoring `.env` before the first start
matters: a container that starts without the token binds loopback and answers nothing.

## 9. Updating later

New versions are listed at https://github.com/unclecode/crawl4ai/releases. The release tag
carries a leading `v` and the image tag does not, so release `v0.9.3` is image tag `0.9.3`. Take a
backup first, then edit the image line in /srv/crawl4ai/compose.yml to the new tag and digest:

```bash
cd /srv/crawl4ai
docker compose pull
docker compose up -d
docker compose logs --tail 30 crawl4ai
```

Watch that log until it settles, then re-run step 7's health check, the unauthenticated 401 and
one real crawl before calling the update done. This project moves quickly and its server API has
changed shape between minor versions, so read the release notes for endpoint changes.

## 10. What will probably go wrong

The container will look fine and answer nothing. I had a green `docker ps`, a clean log and a
connection reset on the published port, and I spent ten minutes on Caddy before reading the
container's own second line of output: no token, so it had bound its server to loopback inside
the container where a published port cannot reach it. That is correct behaviour and it looks
exactly like a broken network. If step 7 returns nothing rather than a 401, check `.env` first.

The second one is not fixable by configuration, so plan around it. Your VPS has a datacenter IP,
and a large share of the web treats datacenter IPs as hostile. Sites behind a bot challenge, and
sites that rate-limit whole hosting ranges, will serve your crawler a block page, and the crawl
will report success at fetching it. Read the markdown that comes back before you trust a pipeline
built on it. A residential proxy pool is much of what a hosted scraping bill buys; this has none.

## 11. Out of scope

- Do not set `CRAWL4AI_HOOKS_ENABLED` or `CRAWL4AI_EXECUTE_JS_ENABLED`. Upstream's own source
  calls them an arbitrary-code and SSRF surface and ships them off. Leave them off.
- Do not add an LLM provider API key. This install runs the readability filter, which needs no
  model, and a key here is a bill the crawler can run up by itself.
- Do not publish 11235 or 8198 in the firewall, and do not rebind either to 0.0.0.0 on the host.
  Caddy is the only way in.
- Do not build the image from the repository. The pinned digest is what this prompt installs.
