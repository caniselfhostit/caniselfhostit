This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Meilisearch 1.52.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read these before step 1. This is a search API, not a website with accounts: there is no browser
sign-in to finish and no admin dashboard to claim. Without a master key the instance is not gated
the way a public hostname requires, so you will generate that key before the container starts.
Never put the master key in a browser; frontends get a search-scoped key from /keys. The tree at
the pinned tag is dual-licensed MIT AND BUSL-1.1: this install uses the MIT search API path, not
Enterprise Edition production features that need a commercial agreement.

## 1. Preflight

Its A record must already point at this server.

Meilisearch needs 1024 MB of RAM available and 10 GB free on /srv. The image publishes amd64
and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a hostname that does not resolve. The 1 GB floor is for a small personal index; multi-million
document catalogues need more RAM. A search engine without an application in front of it is an
empty box: this install starts the engine, and you still write the code that posts documents
and runs queries.


## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/meilisearch /srv/meilisearch/backups /srv/meilisearch/data
ls -la /srv/meilisearch
```

You should see `backups` and `data` owned by your login user. Nothing is written outside
/srv/meilisearch. Index files appear under `data/` after the first documents are added. Until
then the directory stays almost empty, which is normal.


## 3. Secrets

One secret: the master key. Generate it on the server. Do not paste the value into chat or into a public page. Upstream requires at least 16 bytes of valid
UTF-8; hex 32 is more than enough.

```bash
umask 077
cat > /srv/meilisearch/.env <<EOF
MEILI_MASTER_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/meilisearch/.env
umask 022
ls -la /srv/meilisearch/.env
```

Assert: `.env` is mode 600. Print only the path, never the key. Read it later with
`sudo grep MEILI_MASTER_KEY /srv/meilisearch/.env` and store it offline. Never put the master
key in a browser or public frontend. Step 7 creates a search-scoped key for client use.

## 4. compose.yml

```bash
cat > /srv/meilisearch/compose.yml <<'EOF'
# Meilisearch · the deterministic fallback. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker .............. https://www.meilisearch.com/docs/guides/misc/docker
#   security ............ https://www.meilisearch.com/docs/learn/security/basic_security
#   configuration ....... https://www.meilisearch.com/docs/resources/self_hosting/configuration/reference
#   license ............. https://github.com/meilisearch/meilisearch/blob/v1.52.0/LICENSE
#
# One container. MEILI_MASTER_KEY comes from env_file (generated on the server).
# MEILI_NO_ANALYTICS opts out of telemetry. Indexes live under /meili_data.
# Tag and digest are the v1.52.0 release read from Docker Hub on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  meilisearch:
    image: getmeili/meilisearch:v1.52.0@sha256:d36e713e8f89483af1ab0d72011bbd503f5ab100b68ccbfad51c39e3f0a0567d
    container_name: meilisearch
    restart: unless-stopped
    env_file: /srv/meilisearch/.env
    environment:
      MEILI_ENV: production
      MEILI_NO_ANALYTICS: "true"
    volumes:
      - /srv/meilisearch/data:/meili_data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8203.
      - "127.0.0.1:8203:7700"
EOF
cd /srv/meilisearch && docker compose config >/dev/null && echo "compose OK"
```

You should see `compose OK`. One service, one published port, no database container: indexes
live under `data/`. `MEILI_ENV=production` and `MEILI_NO_ANALYTICS=true` are set in the file;
the master key stays only in `.env`. Do not add a Caddy service to this file. Telemetry is off
on purpose so anonymous usage stats do not leave this box.


## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
cat > /srv/meilisearch/Caddyfile <<'EOF'
# Meilisearch · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.meilisearch.com/docs/learn/security/basic_security and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project. Auth is the
# master key inside Meilisearch, not a browser login form.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8203 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8203
}
EOF
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-meilisearch
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sed "s|<DOMAIN>|${REAL_DOMAIN}|g" /srv/meilisearch/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `REAL_DOMAIN` to your real hostname before running sed (example:
`REAL_DOMAIN=search.example.com`). Do not wrap the value in extra quotes inside the sed
replacement. Validate and reload should exit 0. If validate fails, restore
`/etc/caddy/Caddyfile.before-meilisearch`, reload, and read the error. Caddy requests the
certificate on the first request and renews it on its own.

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
443/udp is HTTP/3. 8203 stays closed because compose binds it to 127.0.0.1. You should see
`Status: active`, rules for 80 and 443, and no rule mentioning 8203 or 7700. Opening 7700 would
put the API on the public internet without Caddy's TLS path.


## 7. Start and verify

```bash
cd /srv/meilisearch
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8203/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://127.0.0.1:8203/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/indexes
MASTER=$(grep MEILI_MASTER_KEY /srv/meilisearch/.env | cut -d= -f2-)
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${MASTER}" https://<DOMAIN>/indexes
curl -sS -H "Authorization: Bearer ${MASTER}" https://<DOMAIN>/keys
```

You should see: health loop ends on `200`; unauthenticated `/indexes` is `401` (the security
assert); authenticated `/indexes` is `200`; `/keys` lists default keys including a search key.
Print HTTP codes, not the master key. If any miss, run `docker compose logs --tail 40
meilisearch`. Unset `MASTER` when done: `unset MASTER`.

There is no sign-in page. Opening https://<DOMAIN>/ shows API JSON, not an account form.

STOP: read the master key with `sudo grep MEILI_MASTER_KEY /srv/meilisearch/.env`, store it
offline, and plan to use only a search-scoped key from `/keys` in any browser. Do not continue until they confirm they have the master key stored and understand the search key is what frontends receive.

Sample handoff once stored (do not paste secret values into chat):

```bash
MASTER=$(grep MEILI_MASTER_KEY /srv/meilisearch/.env | cut -d= -f2-)
curl -sS -X POST https://<DOMAIN>/indexes \
  -H "Authorization: Bearer ${MASTER}" \
  -H 'Content-Type: application/json' \
  --data-binary '{"uid":"movies","primaryKey":"id"}'
curl -sS -X POST 'https://<DOMAIN>/indexes/movies/documents' \
  -H "Authorization: Bearer ${MASTER}" \
  -H 'Content-Type: application/json' \
  --data-binary '[{"id":1,"title":"Carol"},{"id":2,"title":"Wonder Woman"}]'
unset MASTER
```

Both calls should return task JSON without a 401. Documents index asynchronously; a search a
few seconds later with a search API key should find `Carol`.

## 8. First backup and restore

One archive: the index data, the master key in `.env`, compose, and the live Caddy site block.

```bash
cd /srv/meilisearch
docker compose stop
sudo tar -czf /srv/meilisearch/backups/meilisearch-$(date +%F).tar.gz -C /srv/meilisearch data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/meilisearch/backups/
```

The archive should exist and be non-empty. Print its size. Downtime is about five seconds.
Treat the archive as secret material: it holds the master key.

A backup on the same disk is not a backup. From your own machine:

```bash
mkdir -p ~/backups/meilisearch
scp vps:/srv/meilisearch/backups/*.tar.gz ~/backups/meilisearch/
```

To restore: `docker compose down`, remove `data`, recreate it, untar into /srv/meilisearch,
put the Caddy block back if needed, then `docker compose up -d`. `data/` is every document you
indexed; `.env` is the master key. They travel together or the API stays locked.



After the first real application is wired, run one deliberate search and one deliberate delete
of a test index so you know which key can do which. A search key that unexpectedly returns 403
on a write is correct behaviour. An admin key in a browser is the failure mode step 10 describes.

On restore after disk loss: bring Docker and Caddy back (Prompt Zero), restore the tar into
/srv/meilisearch, restore the Caddyfile, `docker compose up -d`, then prove unauthenticated
calls still return 401 and authenticated /health or /indexes still return 200 with the restored
master key. If you only restore `data/` and regenerate `.env`, the instance starts but old
application keys and assumptions about the previous master key no longer hold.

## 9. Updating later

New versions are listed at https://github.com/meilisearch/meilisearch/releases. The release tag
and the image tag are the same string, so release `v1.53.0` is image tag `v1.53.0`. Take a
backup first, then edit the image line in /srv/meilisearch/compose.yml to the new tag and its
digest:

```bash
cd /srv/meilisearch
docker compose pull
docker compose up -d
docker compose logs --tail 30 meilisearch
```

Watch that log until it settles, then re-run step 7's health and unauthenticated 401 checks
before calling the update done. If a release notes page mentions a one-way dump or reindex,
read it before pulling: index formats can force a rebuild after major jumps.


## 10. What will probably go wrong

You will paste the master key into a frontend "API key" field because it is the only string in
`.env` and it works in curl. I did that once on a demo page. Every visitor then held a key that
could delete indexes. Upstream is explicit: use the master key only to manage keys, and hand
browsers a search-scoped key from `/keys`. If you already leaked the master key, rotate by
stopping the container, generating a new `MEILI_MASTER_KEY` in `.env`, starting again, and
re-issuing every application key. Indexes survive; the old master key does not.

The other miss is disk. A bulk import of a large crawl without checking free space fills
`/srv/meilisearch/data` until the container cannot write. Watch `df -h /srv` during the first
real index job, and keep a second disk plan for anything that grows like a product catalogue.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy is already running under systemd on
  this box, and a second one would fight it for 80 and 443.
- Do not publish 7700 or 8203 on the public interface or open them in the firewall. Caddy is
  the only way in.
- Do not leave `MEILI_MASTER_KEY` empty and do not run without `MEILI_ENV=production` on a
  public hostname.
- Do not skip the first backup after indexes hold real data.
- Do not enable Enterprise Edition features that require a commercial agreement. This install
  is the MIT-covered search API path of the dual-licensed tree.

SPDX at the pin is MIT AND BUSL-1.1 in one repository. Community Edition search is MIT.
Enterprise Edition paths (sharding, S3-streaming snapshots and related EE work) are BUSL-1.1
and are not free to run in production without a commercial agreement with Meilisearch. Source-
available candor applies to the BUSL part: it is not OSI open source for those paths.

When you integrate with an app, prefer the default search API key listed by GET /keys for any
code that runs in a browser, and keep the default admin API key on the server the same way you
keep the master key. Upstream warns not to expose admin keys on a public frontend.

Keep one off-box copy of the backup whenever indexes hold data you cannot re-crawl cheaply.
