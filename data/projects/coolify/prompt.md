You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Coolify 4.1.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say this before anything installs. Coolify holds a private key that logs into this host and
drives its Docker daemon: Prompt Zero called docker-group membership root-equivalent, and this
hands that to a web dashboard.

It needs 2048 MB of RAM available and 30 GB free on /, a floor rather than a budget because
builds run here too. Both architectures are published.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail / | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk under 30 GB, print both and stop. If `dig +short`
prints nothing, print that and stop too. Do not install and hope.

## 2. Layout and host access

The application writes deployment files to /data/coolify by name, so that path is not ours to
move. Our archives sit outside it, in /srv/coolify/backups.

```bash
sudo install -d -m 750 -o "$(id -u)" -g 9999 /data/coolify /data/coolify/source
sudo install -d -m 700 -o 9999 -g 9999 /data/coolify/{ssh,ssh/keys,ssh/mux,applications,databases,services,backups,proxy,proxy/dynamic}
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" /srv/coolify /srv/coolify/backups
KEY=/data/coolify/ssh/keys/id.$(id -un)@host.docker.internal
sudo ssh-keygen -t ed25519 -a 100 -N "" -C coolify -q -f "$KEY"
sudo cat "$KEY.pub" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sudo rm -f "$KEY.pub"
sudo chown 9999:9999 "$KEY" && sudo chmod 600 "$KEY"
printf '%s ALL=(ALL) %s ALL\n' "$(id -un)" 'NOPASSWD:' | sudo tee /etc/sudoers.d/coolify >/dev/null
sudo chmod 440 /etc/sudoers.d/coolify
sudo visudo -c -f /etc/sudoers.d/coolify
docker network create --attachable coolify || true
ls -la /data/coolify
```

Assert: `visudo -c` prints `parsed OK`, and `ls -la` shows `source` owned by the login user, the
rest at mode `700` owned by `9999`. The key file name carries the login user, which is how the
application picks the account it logs in as. This uses the Prompt Zero login user rather than
root, so no root login is re-enabled, and the sudoers line is upstream's requirement for that.

## 3. Secrets

Seven, all generated here: the instance id, the application key, the database and Redis
passwords, and three realtime credentials. Print none of them, and keep every one of them out of
your summary and your log lines. Hex, because two travel inside connection strings.

```bash
umask 077
cat > /data/coolify/source/.env <<EOF
APP_ID=$(openssl rand -hex 16)
APP_NAME=Coolify
AUTOUPDATE=false
APP_KEY=base64:$(openssl rand -base64 32)
DB_USERNAME=coolify
DB_DATABASE=coolify
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
PUSHER_APP_ID=$(openssl rand -hex 32)
PUSHER_APP_KEY=$(openssl rand -hex 32)
PUSHER_APP_SECRET=$(openssl rand -hex 32)
EOF
umask 022
sudo chown "$(id -u)":9999 /data/coolify/source/.env
chmod 640 /data/coolify/source/.env
ls -l /data/coolify/source/.env
```

Assert: mode `-rw-r-----`, group `9999`. 640 rather than 600 is the one file this install widens:
the container reads it as uid 9999 and nothing else is in that group. `APP_KEY` encrypts the keys
the dashboard stores; `AUTOUPDATE=false` stops it replacing the pinned image itself.

## 4. compose.yml

```bash
cat > /data/coolify/source/compose.yml <<'EOF'
# Coolify · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   manual install ..... https://coolify.io/docs/get-started/installation
#   ports and firewall . https://coolify.io/docs/knowledge-base/server/firewall
#   host connection .... https://coolify.io/docs/knowledge-base/server/openssh
#   proxy choices ...... https://coolify.io/docs/knowledge-base/server/proxies
#
# Four services: the application, its PostgreSQL, its Redis, and the realtime
# server behind the dashboard's live logs and web terminal. Container names, the
# network name and the /data/coolify paths are strings the application looks up
# by hand. Three loopback ports: 8115 dashboard, 6001 realtime, 6002 terminal;
# this server's proxy is Custom (None), so none competes with Caddy for 80 and
# 443. Digests read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  coolify:
    image: ghcr.io/coollabsio/coolify:4.1.2@sha256:3a27ba5f7f98ff7763a0a4d6715ec36e564f9622eea8f492c46f90716ea2525f
    container_name: coolify
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    env_file: /data/coolify/source/.env
    volumes:
      - /data/coolify/source/.env:/var/www/html/.env:ro
      - /data/coolify/ssh:/var/www/html/storage/app/ssh
      - /data/coolify/applications:/var/www/html/storage/app/applications
      - /data/coolify/databases:/var/www/html/storage/app/databases
      - /data/coolify/services:/var/www/html/storage/app/services
      - /data/coolify/backups:/var/www/html/storage/app/backups
    ports:
      # Loopback only, like 6001 and 6002 below. 5432 and 6379 stay inside.
      - "127.0.0.1:8115:8080"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8080/api/health || exit 1"]
      interval: 10s
      retries: 30
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      soketi:
        condition: service_started

  postgres:
    image: postgres:15.18-alpine@sha256:3d0f7584ed7d04e27fa050d6683a74746608faf21f202be78460d679cc56461f
    container_name: coolify-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: coolify
    volumes:
      - coolify-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coolify -d coolify"]
      interval: 10s
      retries: 30

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: coolify-redis
    restart: unless-stopped
    command: ["redis-server", "--save", "20", "1", "--requirepass", "${REDIS_PASSWORD}"]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    volumes:
      - coolify-redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping | grep -q PONG"]
      interval: 10s
      retries: 30

  soketi:
    image: ghcr.io/coollabsio/coolify-realtime:1.0.16@sha256:b5bb9d1c95d9b4ca59773b82d1e1a2bf4ccac5fbed33be19b9b3906574db3629
    container_name: coolify-realtime
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      SOKETI_DEFAULT_APP_ID: ${PUSHER_APP_ID}
      SOKETI_DEFAULT_APP_KEY: ${PUSHER_APP_KEY}
      SOKETI_DEFAULT_APP_SECRET: ${PUSHER_APP_SECRET}
    volumes:
      - /data/coolify/ssh:/var/www/html/storage/app/ssh
    ports:
      - "127.0.0.1:6001:6001"
      - "127.0.0.1:6002:6002"

networks:
  default:
    name: coolify
    external: true

volumes:
  coolify-db:
    name: coolify-db
  coolify-redis:
    name: coolify-redis
EOF
cd /data/coolify/source && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose reads .env from the project directory for the
`${...}` values; the application reads it again inside the container.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy first: a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-coolify
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Coolify · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://coolify.io/docs/knowledge-base/server/proxies and
# https://caddyserver.com/docs/automatic-https
#
# Three routes, because one hostname fronts three services, and this is the
# table upstream's own proxy writes for an instance with a domain. Drop either
# socket route and the dashboard loads while its live logs and web terminal
# never connect. Append it to /etc/caddy/Caddyfile with <DOMAIN> replaced by
# the hostname pointed at this box.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# Upstream's rules are PathPrefix(`/app`) for live logs and
	# PathPrefix(`/terminal/ws`) for the web terminal. These are those.
	reverse_proxy /app* 127.0.0.1:6001
	reverse_proxy /terminal/ws* 127.0.0.1:6002

	# Everything else is the dashboard. No loopback port is in the firewall.
	reverse_proxy 127.0.0.1:8115
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. On failure restore /etc/caddy/Caddyfile.before-coolify, reload, and report
what it objected to. Caddy gets the certificate on the first request and renews it itself.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the way in, 443/udp is HTTP/3. 8115, 6001 and 6002
stay closed because compose binds them to 127.0.0.1, 5432 and 6379 because compose never
publishes them. Upstream opens the first three for a dashboard reached by IP and says they can
close behind a domain, and one is in front here from the first request. Assert: `Status: active`,
rules for 80, 443/tcp and 443/udp, none for the five.

## 7. Start and verify

```bash
cd /data/coolify/source
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/health; echo
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/register | grep -c 'Create your account'
docker compose ps
```

Assert all five, printing what you got. The loop ends on `200`. `/api/health` answers the single
word `OK`. The root lands on `https://<DOMAIN>/register`, where an instance with no users sends
everyone. The grep prints at least `1`: that screen carries the heading `Coolify` above the line
`Create your account`. `ps` shows four containers up. On any miss, stop, run
`docker compose logs --tail 40 coolify` and name the cause: an unhealthy database is step 3 with
an empty `DB_PASSWORD`, a `502` is step 5. A running container is not success.

STOP: tell the user to open https://<DOMAIN> and create their account there. It is the only
moment it can be made and no mail server here can reset it, so have them save the password in a
manager first. Do not continue until they confirm.

```bash
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/register
```

Assert: `https://<DOMAIN>/login`. Registration closes once the first user exists.

STOP: tell the user to do three things in the dashboard. In Settings, set the instance's domain
to `https://<DOMAIN>`. In Servers, open `localhost`, go to Proxy, choose `Custom (None)` until
the page reads `Custom (None) Proxy Selected`, then press Validate and confirm it reports
reachable. Do not continue until they confirm all three.

```bash
docker ps -a --filter name=coolify-proxy --format '{{.Names}} {{.Status}}'
```

Assert: nothing, or a container that is `Exited`. A running `coolify-proxy` means Traefik is
still selected and still trying to take 80 and 443. Every assert here passes first.

## 8. First backup and restore

Two artifacts: the database holds every project, server, key and deployment record, the archive
what rebuilds the service around it, host key included.

```bash
cd /data/coolify/source
docker compose exec -T postgres pg_dump -U coolify -d coolify | gzip > /srv/coolify/backups/coolify-db-$(date +%F).sql.gz
sudo tar -czf /srv/coolify/backups/coolify-config-$(date +%F).tar.gz -C /data/coolify source ssh -C /etc/caddy Caddyfile
ls -lh /srv/coolify/backups/
```

Assert: both exist, both non-empty, print both sizes. Nothing goes down: `pg_dump` snapshots a
running database. A backup on the same disk is not a backup, so run this from the user's
machine:

```bash
mkdir -p ~/backups/coolify
scp vps:/srv/coolify/backups/* ~/backups/coolify/
```

To restore: `docker compose down`, untar the config archive back into /data/coolify so
source/.env and the host key land first, `docker compose up -d postgres`, wait for healthy, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U coolify -d coolify`,
then `docker compose up -d`. The stakes: those rows are encrypted with `APP_KEY` from that
`.env`, so a dump restored without the archive comes back unreadable.

## 9. Updating later

Versions are listed at https://github.com/coollabsio/coolify/releases, and the realtime image
pairing with each is named in `versions.json` at that tag. Back up first, then edit the two
image lines in compose.yml to the new tags and digests:

```bash
cd /data/coolify/source
docker compose pull
docker compose up -d
docker compose logs --tail 40 coolify
```

It migrates its own database on the way up, so watch that log settle, then re-run step 7's
health check. `AUTOUPDATE=false` keeps the dashboard's update button from doing this itself.

## 10. What will probably go wrong

The first boot fails at a proxy nobody asked for. A fresh instance seeds its own server entry
with Traefik selected and starts it at once, and Traefik wants 80 and 443, which Caddy holds. I
spent ten minutes reading a red `Bind for 0.0.0.0:80 failed: port is already allocated` before I
understood it was correct: Docker refused a second proxy those ports. `Custom (None)` ends it.

## 11. Out of scope

- Do not select Traefik or Caddy as this server's proxy, and do not stop the host Caddy to make
  room for one. Applications deployed here get a loopback port and a site block, as this did.
- Do not run upstream's one-line installer on this box. It fetches its own compose files, writes
  its own .env and installs a root login, and this install has done that work already.
- Do not configure SMTP, Slack or any other notification transport, add an S3 backup
  destination, or connect a GitHub App. Each is a separate credential and none is needed to get
  one application running by hand, which is what should happen first.
