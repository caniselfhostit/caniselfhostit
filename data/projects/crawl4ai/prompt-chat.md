This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Crawl4AI 0.9.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Read these three before step 1. This is a crawling API, not a website with accounts: there is no
sign-in to finish and no admin user to claim, and what you get is an HTTP endpoint that turns a
URL into markdown or JSON. The API token is not a nicety here: the container's entrypoint binds
its server to container loopback whenever no credential is configured, so an install without a
token publishes a port that answers nothing at all, and step 3 generates it. And what you crawl
is your responsibility, because the crawler does not consult robots.txt unless a request asks it
to, and nothing in this container enforces a site's terms of service.

One more thing worth knowing before you spend the evening. Your VPS has a datacenter IP, and a
large share of the web treats datacenter IPs as hostile. Sites behind a bot challenge will serve
this crawler a block page, and the crawl will report success at fetching it. A residential proxy
pool is much of what a hosted scraping bill buys, and this container has none.

## 1. Preflight

Crawl4AI needs 4096 MB of RAM available and 15 GB free on /srv, because the image carries a real
Chromium and starts one on the way up. It publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: a memory line with at least 4096 MB available, a disk line of 15 GB or more,
`amd64` or `arm64`, and one IP address that is this server's.

If you do not: stop here. Under the RAM floor, Chromium is killed mid-crawl and the failure looks
random rather than budgeted. If `dig +short` printed nothing, the DNS record is missing or has
not propagated, and Caddy cannot get a certificate for a hostname that does not resolve. Wait a
few minutes and run it again before doing anything else.

The image is about 1.5 GB to download and more on disk once unpacked, which is the slowest part
of this install.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/crawl4ai /srv/crawl4ai/backups
ls -la /srv/crawl4ai
```

You should see: two directories, both owned by your login user.

If you do not: the `install -d` line failed, usually because you are not in the sudoers group.
Fix that before continuing, because every later step writes under this path.

There is no `data` directory here, and that is deliberate. This install mounts no volumes: the
crawl cache, the artifact store and the in-container Redis are disposable, and your data is
whatever your own code does with the JSON that comes back.

## 3. Secrets

One secret: `CRAWL4AI_API_TOKEN`. Generate it on the server. Do not paste the value, the contents
of `.env`, or any command output containing it into this chat window: the agent path never sees
those values, and this path will hand them to a third party unless you keep them out.

```bash
umask 077
cat > /srv/crawl4ai/.env <<EOF
CRAWL4AI_API_TOKEN=$(openssl rand -hex 32)
EOF
chmod 600 /srv/crawl4ai/.env
umask 022
ls -la /srv/crawl4ai/.env
```

You should see: one file listed with mode `-rw-------`.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not run in the same shell as the
heredoc. Delete the file and run the whole block again as one paste.

Read it back later with `sudo grep CRAWL4AI_API_TOKEN /srv/crawl4ai/.env` and put it in your
password manager now. Be clear with yourself about what it is: admin-scoped, with no read-only
alternative on this install. Anyone holding it can make this server fetch any URL it can reach,
including private addresses inside your own network.

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

You should see: `compose OK`.

If you do not: `docker compose config` prints the line it objected to. The usual cause is a
heredoc that was pasted in two pieces, which breaks the YAML indentation. Delete
/srv/crawl4ai/compose.yml and paste the whole block in one go.

One service, one published port, no volumes, no database. Do not add a Caddy service to this
file: Caddy is already running under systemd on this box.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by your
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

You should see: `Valid configuration` from validate, and no output at all from the reload.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-crawl4ai /etc/caddy/Caddyfile`, reload, and read what
validate objected to. A stray `<DOMAIN>` that you forgot to replace is the most common one.
Caddy requests the certificate on the first request and renews it on its own; there is nothing to
schedule.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for 80/tcp, 443/tcp and 443/udp, and no rule mentioning
8198 or 11235.

If you do not: a rule for 8198 from an earlier experiment removes with
`sudo ufw delete allow 8198`. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp
is the only way in, and 443/udp is HTTP/3. 8198 stays closed because compose binds it to
127.0.0.1, and 11235 is a container port never published to the host.

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

You should see: the loop counting up and ending on `200`; a health body containing
`"status":"ok"`; then `401` from the unauthenticated POST, which is the security check in this
block; then JSON whose `markdown` field contains `Example Domain`; then `1`. The `"f":"raw"` in
those two calls asks for the direct conversion, because the default readability filter can prune
a page this small down to nothing.

If you do not: run `docker compose logs --tail 40 crawl4ai`. A log line about binding loopback
only means `.env` did not load, so check steps 3 and 4. A 502 from Caddy with a healthy container
means step 5 is pointing somewhere else. An empty reply rather than a `401` is the same missing
token, seen from outside. A running container is not success, and neither is a green
`docker compose ps`.

Do not paste the token or the full `.env` line into this chat while you debug. Paste the HTTP
status codes, which are what actually diagnose this.

There is no sign-in page. https://<DOMAIN>/ redirects to the playground UI, which can do nothing
until a token is pasted into its token bar.

STOP: read your token with `sudo grep CRAWL4AI_API_TOKEN /srv/crawl4ai/.env`, store it in your
password manager, and understand that it is admin-scoped: there is no read-only key to hand out,
and pasting it into a browser on a shared machine hands over the whole crawler. Do not continue
until you have it stored.

Now the core loop: a real crawl, returning real markdown.

```bash
TOKEN=$(grep CRAWL4AI_API_TOKEN /srv/crawl4ai/.env | cut -d= -f2-)
curl -sS -X POST https://<DOMAIN>/crawl \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary '{"urls":["https://example.com"],"crawler_config":{"type":"CrawlerRunConfig","params":{"check_robots_txt":true}}}' \
  | head -c 600; echo
unset TOKEN
```

You should see: a response starting `{"success":true` with a results array carrying the crawled
page. That is the product: a URL in, structured JSON with a markdown field out.

If you do not: a `401` means the token did not make it into the header, usually because `TOKEN`
was unset by a previous paste. A `403` on a site that works in your browser is that site blocking
your server's address, not a fault in the install. `check_robots_txt` is in that request on
purpose, because it defaults to false and you should see where the polite setting lives.

This endpoint is what your own scripts call. A schedule is your own cron entry calling this URL,
because nothing in this container runs one.

## 8. First backup and restore

There is no application state to archive. This install mounts no volumes, so the backup is the
three files that rebuild it: the token, the compose file and the live Caddy site block. Do not
let yourself believe an archive is protecting crawl results, because there are none on disk.

```bash
cd /srv/crawl4ai
sudo tar -czf /srv/crawl4ai/backups/crawl4ai-$(date +%F).tar.gz -C /srv/crawl4ai .env compose.yml -C /etc/caddy Caddyfile
ls -lh /srv/crawl4ai/backups/
```

You should see: one `.tar.gz` with a non-zero size.

If you do not: a `Cannot stat` error names the file it could not find, which is almost always
`.env` because step 3 was skipped. There is no downtime here, because nothing is being written.

Treat the archive as secret material: it holds the API token. A backup on the same disk as the
data is not a backup, so run this from your own machine, not the server:

```bash
mkdir -p ~/backups/crawl4ai
scp vps:/srv/crawl4ai/backups/*.tar.gz ~/backups/crawl4ai/
```

You should see: one file copied, with a progress line.

If you do not: `ssh vps` is not configured on the machine you are typing on. That is a Prompt
Zero step, and it is worth fixing now rather than the night you need the archive.

To restore on a fresh box: complete Prompt Zero, recreate the two directories from step 2, untar
the archive into /srv/crawl4ai to bring back `.env` and `compose.yml`, append the archived
Caddyfile block to /etc/caddy/Caddyfile with your hostname substituted, validate and reload
Caddy, then `docker compose up -d` and re-run the health and 401 checks from step 7. Restoring
`.env` before the first start matters: a container that starts without the token binds loopback
and the published port answers nothing.

## 9. Updating later

New versions are listed at https://github.com/unclecode/crawl4ai/releases. The release tag carries
a leading `v` and the image tag does not, so release `v0.9.3` is image tag `0.9.3`. Take a backup
first, then edit the image line in /srv/crawl4ai/compose.yml to the new tag and its digest:

```bash
cd /srv/crawl4ai
docker compose pull
docker compose up -d
docker compose logs --tail 30 crawl4ai
```

You should see: a pull, a recreate, and a log that settles within a minute or two.

If you do not: the pull failing on a digest mismatch means the tag and digest you pasted do not
belong together. Get both from the same registry read rather than assuming the digest carried
over. After every update, re-run the health check, the unauthenticated 401 and one real crawl
before calling it done. This project moves quickly and its server API has changed shape between
minor versions, so read the release notes for endpoint changes.

## 10. What will probably go wrong

The container will look fine and answer nothing. I had a green `docker ps`, a clean log and a
connection reset on the published port, and I spent ten minutes on Caddy before reading the
container's own second line of output: no token, so it had bound its server to loopback inside
the container, where a published port cannot reach it. That is correct behaviour and it looks
exactly like a broken network. If step 7 returns nothing rather than a 401, check `.env` before
you touch anything else.

The second one is not fixable by configuration, so plan around it. A block page is still a page:
the crawl succeeds, the JSON says `"success":true`, and the markdown is a challenge screen. Read
what comes back before you build a pipeline on top of it.

## 11. Out of scope

- Do not set `CRAWL4AI_HOOKS_ENABLED` or `CRAWL4AI_EXECUTE_JS_ENABLED`. Upstream's own source
  calls them an arbitrary-code and SSRF surface and ships them off. Leave them off.
- Do not add an LLM provider API key. This install runs the readability filter, which needs no
  model, and a key here is a bill the crawler can run up on its own.
- Do not publish 11235 or 8198 in the firewall, and do not rebind either to 0.0.0.0 on the host.
  Caddy is the only way in.
- Do not build the image from the repository. The pinned digest is what this install uses.

Two closing notes on the licence and the shells, because they are the parts people find later.
The LICENSE file at this tag is Apache-2.0 with an Attribution Requirement appended after the end
of the Apache terms: any distribution, publication or public use must carry a named credit to the
author and the project. Running this container for yourself is unaffected; shipping a product or
publishing a paper built on it is not. And three paths stay public on this hostname because the
application serves them publicly: /playground, /dashboard and /static are static shells that hold
no data and can call nothing without the token, while /health is public so the container's own
healthcheck works. The Caddy block above carries the two lines that close the shells if you would
rather not serve them.
