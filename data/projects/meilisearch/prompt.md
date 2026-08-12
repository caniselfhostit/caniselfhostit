You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Meilisearch 1.52.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things first. One: this is a search API, not a website with accounts. There is no
browser sign-in to finish and no admin dashboard to claim. Two: without a master key the
instance is not gated the way a public hostname requires, so step 3 generates that key before
the container starts.

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
document catalogues need more RAM.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/meilisearch /srv/meilisearch/backups /srv/meilisearch/data
ls -la /srv/meilisearch
```

Assert: the directories exist and are owned by the login user. Nothing is written outside
/srv/meilisearch. Index files will appear under `data/` after the first documents are added.

## 3. Secrets

One secret: the master key. Generate it on the server. Do not print it, do not repeat it in
your summary, and do not put it in any log line. Upstream requires at least 16 bytes of valid
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

Assert: `.env` is mode 600. Print only the path, never the key. Tell the user the key lives in
/srv/meilisearch/.env and they can read it later with
`sudo grep MEILI_MASTER_KEY /srv/meilisearch/.env`. It belongs in their password manager if
they will hand it to an application later. Never put the master key in a browser, a public
frontend, or a chat transcript. Step 7 creates a search-scoped key for client use.

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

Assert: that prints `compose OK`. One service, one published port, no database container:
indexes live under `data/`. `MEILI_ENV=production` and `MEILI_NO_ANALYTICS=true` are set in
the file; the master key stays only in `.env`. Do not add a Caddy service to this file.

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

Set `REAL_DOMAIN` to the hostname the user gave in step 1 before running sed. Do not wrap the
value in extra quotes inside the sed replacement. Assert: validate and reload exit 0. If
validate fails, restore `/etc/caddy/Caddyfile.before-meilisearch`, reload, and report what it
objected to. Caddy requests the certificate on the first request and renews it on its own.

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
443/udp is HTTP/3. 8203 stays closed because compose binds it to 127.0.0.1. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8203 or 7700.

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

Assert all five, and print the HTTP codes (not the master key). The health loop ends on `200`
and the body is a health payload. The unauthenticated call to `/indexes` prints `401`: that is
the security assert in this block. The authenticated `/indexes` call prints `200`. The `/keys`
call returns JSON that includes default API keys, among them a search key whose actions include
`search`. If any assert misses, stop, run `docker compose logs --tail 40 meilisearch`, and name
the likely earlier step: a container that exits on a missing master key is step 3, and a 502
from Caddy with a running container is step 5. Unset `MASTER` when you are done reading keys:
`unset MASTER`. A running container is not success.

There is no sign-in page. Opening https://<DOMAIN>/ in a browser shows the API root JSON, not
an account form. The product is HTTP with `Authorization: Bearer …` headers.

STOP: tell the user to read the master key with
`sudo grep MEILI_MASTER_KEY /srv/meilisearch/.env`, store it offline, and create a
search-scoped key for any browser or public client by calling `GET /keys` (or creating one with
`POST /keys`) using only the master key on the server. Do not continue until they confirm they
have the master key stored and understand the search key is what frontends receive. Never ship
the master key to a browser.

A minimal handoff once they confirm, still on the server, without printing secrets into chat:

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

Assert: both calls return task JSON (or index metadata) without a 401. Documents index
asynchronously; a search a few seconds later with a search API key should find `Carol`.

## 8. First backup and restore

One archive: the index data, the master key in `.env`, compose, and the live Caddy site block.

```bash
cd /srv/meilisearch
docker compose stop
sudo tar -czf /srv/meilisearch/backups/meilisearch-$(date +%F).tar.gz -C /srv/meilisearch data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/meilisearch/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds;
the container is stopped so index files are not copied mid-write. Treat the archive as secret
material: it holds the master key.

A backup on the same disk as the data is not a backup. Run this from the user's machine, not
the server:

```bash
mkdir -p ~/backups/meilisearch
scp vps:/srv/meilisearch/backups/*.tar.gz ~/backups/meilisearch/
```

To restore: `docker compose down`, `sudo rm -rf /srv/meilisearch/data`, recreate `data` as in
step 2, untar the archive back into /srv/meilisearch (restores `data/`, `.env`, compose.yml),
put the Caddy block back if that is what was lost, then `docker compose up -d`. Tell the user
the honest split: `data/` is every document they indexed, `.env` is the master key that gates
the API, and restoring data without the key leaves a locked instance. Losing the key without a
copy means minting a new master key and accepting that old keys no longer match that instance
policy.

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
before calling the update done.

## 10. What will probably go wrong

You will paste the master key into a frontend "API key" field because it is the only string in
`.env` and it works in curl. I did that once on a demo page. Every visitor then held a key that
could delete indexes. Upstream is explicit: use the master key only to manage keys, and hand
browsers a search-scoped key from `/keys`. If you already leaked the master key, rotate by
stopping the container, generating a new `MEILI_MASTER_KEY` in `.env`, starting again, and
re-issuing every application key. Indexes survive; the old master key does not.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy is already running under systemd on
  this box, and a second one would fight it for 80 and 443.
- Do not publish 7700 or 8203 on the public interface or open them in the firewall. Caddy is
  the only way in.
- Do not leave `MEILI_MASTER_KEY` empty and do not run without `MEILI_ENV=production` on a
  public hostname.
- Do not enable Enterprise Edition features that require a commercial agreement. This install
  is the MIT-covered search API path of the dual-licensed tree.
