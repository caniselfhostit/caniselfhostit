You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Windmill 1.789.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. Say why: it becomes `BASE_URL`, and every webhook URL Windmill hands to an outside
service is built from it, so a service connected today calls back to that hostname tomorrow.
Its A record must already point at this server.

Windmill needs 4096 MB of RAM available and 30 GB free on /srv, and publishes amd64 and
arm64. The disk floor is not padding: the worker image carries Python, Bun, Deno, Go, PHP,
Java, Ruby, .NET and PowerShell, and upstream's worker alerts under 15 GB free.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB, free disk under 30 GB, or `dig +short` prints nothing,
print what you got and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/windmill /srv/windmill/backups
sudo install -d -m 700 /srv/windmill/postgres
ls -la /srv/windmill
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned
by root. The PostgreSQL image chowns its own data directory on first start, so leave it
alone. There is no third directory: the language caches and spilled job logs live in named
volumes, because the image ships that cache filled and a bind mount would hide it.

## 3. Secrets

Two secrets: the PostgreSQL password, and the password that replaces Windmill's seeded
superadmin in step 7. Generate both on the server. Do not print either, repeat them in your
summary, or put them in a log line. Hex rather than base64: one travels inside a connection
string, the other inside a JSON body.

```bash
umask 077
cat > /srv/windmill/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
WM_ADMIN_PASSWORD=$(openssl rand -hex 32)
BASE_URL=https://<DOMAIN>
EOF
chmod 600 /srv/windmill/.env
umask 022
ls -l /srv/windmill/.env
```

Assert: the file exists with mode `-rw-------`. No service uses `env_file`, so compose reads
it only to fill `${DB_PASSWORD}` and `${BASE_URL}`, and `WM_ADMIN_PASSWORD` never enters a
container. That matters: a job here can read its worker's environment.

## 4. compose.yml

```bash
cat > /srv/windmill/compose.yml <<'EOF'
# Windmill · the deterministic fallback. Authored by caniselfhostit from the
# upstream sources at https://github.com/windmill-labs/windmill/tree/v1.789.0
# (docker-compose.yml, Caddyfile, README.md, LICENSE, backend/Cargo.toml) and
# https://www.windmill.dev/docs/advanced/security_isolation
#
# The API server, one worker, and the PostgreSQL that is the whole product.
# Upstream's compose adds two more workers, an indexer at zero replicas and a
# windmill-extra container; one worker already carries every language tag, the
# indexer is Enterprise full-text search by upstream's own comment, and
# windmill-extra is EE multiplayer plus debug and LSP aids, traded away. No
# port 25 and no email trigger. No `privileged: true` either, which upstream's
# own security page says removes the container boundary entirely.
#
# Digests read on 2026-08-14; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# json-file does not rotate on its own and a busy worker fills a small disk.
x-logging: &wm-logging
  driver: json-file
  options:
    max-size: 20m
    max-file: "10"

services:
  db:
    image: postgres:16.15-alpine@sha256:ab5c955e9e57ae9879d4411ab49a912be9d162455676f7bf56e951b11ac73785
    container_name: windmill-db
    restart: unless-stopped
    shm_size: 1g
    environment:
      POSTGRES_DB: windmill
      POSTGRES_USER: windmill
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/windmill/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U windmill -d windmill"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  windmill_server:
    image: ghcr.io/windmill-labs/windmill:1.789.0@sha256:de85c0d6960e8f339a93e5d62c04fb3a77bd53699f1d3abc0081bdb32f97fe5b
    container_name: windmill-server
    restart: unless-stopped
    environment:
      MODE: server
      DATABASE_URL: postgres://windmill:${DB_PASSWORD}@db:5432/windmill
      # Every webhook URL and share link the UI prints is built from this.
      BASE_URL: ${BASE_URL}
    volumes:
      # Long job logs spill here out of the database and the server serves
      # them back, so this volume is shared with the worker.
      - windmill_logs:/tmp/windmill/logs
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8193.
      - "127.0.0.1:8193:8000"
    depends_on:
      db:
        condition: service_healthy
    logging: *wm-logging

  windmill_worker:
    image: ghcr.io/windmill-labs/windmill:1.789.0@sha256:de85c0d6960e8f339a93e5d62c04fb3a77bd53699f1d3abc0081bdb32f97fe5b
    container_name: windmill-worker
    restart: unless-stopped
    environment:
      MODE: worker
      WORKER_GROUP: default
      DATABASE_URL: postgres://windmill:${DB_PASSWORD}@db:5432/windmill
    volumes:
      # Named volume, never a bind mount: the image ships this directory
      # filled with the Python runtime and the bun, go and hub caches.
      - windmill_cache:/tmp/windmill/cache
      - windmill_logs:/tmp/windmill/logs
    depends_on:
      db:
        condition: service_healthy
    logging: *wm-logging

volumes:
  windmill_cache:
  windmill_logs:
EOF
cd /srv/windmill && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Three services, one published port.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by
the real hostname. Copy the file first: a syntax error takes down every other site here.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-windmill
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Windmill · the Caddy site block for this service. Authored by caniselfhostit
# from https://github.com/windmill-labs/windmill/blob/v1.789.0/Caddyfile and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# BASE_URL in .env, so changing it later breaks every webhook already aimed at
# it.

<DOMAIN> {
	# Caddy stops buffering text/event-stream itself, which the run view
	# needs to stream a log while a job is running.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# Not no-referrer: connecting a resource walks out to a
		# provider's OAuth screen and back.
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# Upstream sends /ws/*, /ws_mp/* and /ws_debug/* to a windmill-extra
	# container this install does not run: those paths answer 404 and the
	# editor loses in-browser type checking.
	reverse_proxy 127.0.0.1:8193
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-windmill, reload, and report what it objected to. Caddy
terminates TLS and speaks plain http to the container, which is why `BASE_URL` says
`https://`. Caddy renews on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's, and idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3. 8193 binds
to loopback, compose never publishes 5432, and 25 belongs to an email trigger this install
does not run. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8193, 5432 or 25.

## 7. Start and verify

The pull is over a gigabyte, because one image runs every language Windmill supports, and
the server migrates the database on the way up. Allow minutes.

```bash
cd /srv/windmill
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/version); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/version; echo
curl -sS https://<DOMAIN>/api/health/status; echo
```

Assert three, printing each. The loop ends on `200`. `/api/version` prints a version string.
`/api/health/status` prints `"database_healthy":true` and `"workers_alive"` of at least `1`.
If it is `0`, run `docker compose logs --tail 40 windmill_worker`. A running container is not
success.

Windmill seeds one account, `admin@windmill.dev`, password `changeme`, and upstream's README
tells new self-hosters to sign in with it. It is a superadmin and the login screen prefills
both fields. Replace it from the server, before a human opens the page, then use the new
credential for the first workspace and job:

```bash
U=https://<DOMAIN>
J='Content-Type: application/json'
D='{"email":"admin@windmill.dev","password":"changeme"}'
WM_PASS=$(sudo grep '^WM_ADMIN_PASSWORD=' /srv/windmill/.env | cut -d= -f2-)
N="{\"email\":\"admin@windmill.dev\",\"password\":\"$WM_PASS\"}"
TOKEN=$(curl -sS -X POST $U/api/auth/login -H "$J" --data "$D")
curl -sS -o /dev/null -w 'setpassword %{http_code}\n' -X POST $U/api/users/setpassword -H "Authorization: Bearer $TOKEN" -H "$J" --data "{\"password\":\"$WM_PASS\"}"
curl -sS -o /dev/null -w 'replay-default %{http_code}\n' -X POST $U/api/auth/login -H "$J" --data "$D"
curl -sS -o /dev/null -w 'unauth-whoami %{http_code}\n' $U/api/users/whoami
T=$(curl -sS -X POST $U/api/auth/login -H "$J" --data "$N")
curl -sS -H "Authorization: Bearer $T" "$U/api/users/list_as_super_admin?page=1&per_page=100" | grep -o '"email":"[^"]*"' | sort -u
curl -sS -X POST $U/api/workspaces/create -H "Authorization: Bearer $T" -H "$J" --data '{"id":"main","name":"Main"}'; echo
curl -sS -X POST $U/api/w/main/jobs/run_wait_result/preview -H "Authorization: Bearer $T" -H "$J" --data '{"language":"bash","content":"echo windmill-selfhost-check","args":{}}'; echo
```

Assert six, and print each. `setpassword 200`. `replay-default 400`, the status upstream
returns with the body `Invalid login`, so the seeded credential is dead. `unauth-whoami 401`:
there is no signup route and every path outside login needs a token. Then one line,
`"email":"admin@windmill.dev"`, which only a superadmin token gets, so it also proves the new
password works. Then `Created workspace main`, then `windmill-selfhost-check`: server queued,
worker ran bash, result came back. If the replay is not `400`, stop; the default may still
work on a public box. If the last call returns a waiting error, run it once more. Never print
`$WM_PASS`, `$TOKEN` or `$T`.

STOP: tell the user to open https://<DOMAIN>, sign in as `admin@windmill.dev` with the
password from `sudo grep WM_ADMIN_PASSWORD /srv/windmill/.env`, put it in their password
manager, and confirm they land in the `Main` workspace. Do not continue until they confirm.

## 8. First backup and restore

Two artifacts. The database holds every script, flow, app, schedule, run and workspace key.
The config archive holds what rebuilds the service around it.

```bash
cd /srv/windmill
docker compose exec -T db pg_dump -U windmill -d windmill | gzip > /srv/windmill/backups/windmill-db-$(date +%F).sql.gz
sudo tar -czf /srv/windmill/backups/windmill-config-$(date +%F).tar.gz -C /srv/windmill compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/windmill/backups/
```

Assert: both files exist, both are non-empty, and print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently, and tarring `postgres/` would copy a
live data directory, which is not a backup. The named volumes hold caches that rebuild.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/windmill
scp vps:/srv/windmill/backups/* ~/backups/windmill/
```

To restore: `docker compose down`, `sudo rm -rf /srv/windmill/postgres`, recreate it as in
step 2, untar the config archive there so `.env` is back first, bring up only the database
with `docker compose up -d db`, wait for healthy, load the dump by piping `gunzip -c` on the
`.sql.gz` into `docker compose exec -T db psql`, then `docker compose up -d`. Order matters:
a server started before the load migrates an empty database and collides.

## 9. Updating later

New versions are listed at https://github.com/windmill-labs/windmill/releases. Expect one
most working days: the tag went from v1.780.0 to v1.789.0 in the ten days before this was
written, so treat the pin as a decision you re-make on your own schedule. The image tag drops
the leading `v`: `v1.789.0` is tag `1.789.0`. PostgreSQL stays on the 16 line, the major
upstream's own compose runs. Back up first, then edit the two image lines:

```bash
cd /srv/windmill
docker compose pull
docker compose up -d
docker compose logs --tail 40 windmill_server
```

Watch it until the migrations settle, then re-run step 7's two checks.

## 10. What will probably go wrong

The pull. I watched it sit on what looked like a stalled progress bar for eleven minutes and
decided the registry was broken. It was not: one image carries Python, Bun, Deno, Go, PHP,
Java, Ruby, .NET, PowerShell, kubectl and helm, because a worker has to run whatever language
a script is written in, and that is gigabytes to move and unpack. Then the first bash job
took far longer than the second, because the worker was warming caches it keeps from then on.
If step 7's loop still prints `502` after ten minutes, read
`docker compose logs windmill_server`: the migrations are there.

## 11. Out of scope

- Do not set `NO_AUTH`. Every request then arrives as the `admin@windmill.dev` superadmin,
  and upstream means it only for an instance behind an authenticating gateway.
- Do not mount `/var/run/docker.sock` into the worker. Upstream comments that line out with a
  warning, and it hands every script author root on this host.
- Do not add `privileged: true` or turn nsjail on now. For job isolation later, upstream
  documents a route that keeps the container boundary: `DISABLE_NSJAIL=false` with
  `DISABLE_NUSER=true` and the `SYS_ADMIN`, `SYS_RESOURCE` and `SETPCAP` capabilities.
- Do not configure SMTP or an OAuth provider. Each is a separate signup.
