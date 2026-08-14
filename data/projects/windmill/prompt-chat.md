This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Windmill 1.789.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record
already points at the box.

Read this before step 1. `<DOMAIN>` becomes `BASE_URL`, and Windmill builds every webhook
URL it hands to an outside service from it. A service you connect in March calls back to
that hostname in June, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `30` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: the disk floor is the one that catches people. One Windmill image carries
Python, Bun, Deno, Go, PHP, Java, Ruby, .NET and PowerShell, because a worker has to be able
to run whatever language a script is written in, and upstream's worker raises a critical
alert of its own once free space drops under 15 GB. An empty last line means the A record
does not exist yet: add it, wait a minute, and run `dig +short <DOMAIN>` again, because Caddy
cannot get a certificate for a name that does not resolve and failed attempts count against
a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/windmill /srv/windmill/backups
sudo install -d -m 700 /srv/windmill/postgres
ls -la /srv/windmill
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes
it refuse to initialise. There is no third directory here: the worker's language caches and
the spilled job logs go into Docker named volumes, because the image ships that cache
directory already filled with the Python runtime and a bind mount over it would hide the lot.

## 3. Secrets

Two secrets: the PostgreSQL password, and the password that will replace Windmill's seeded
superadmin in step 7. Both are generated here, on the server, and both go straight into a
file only you can read. Hex rather than base64, because one travels inside a connection
string and the other inside a JSON request body.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>`
on the third line with your real hostname before you paste.

Do not paste the contents of that file, either password, or any command output containing
one back into this chat window. Everything you paste here leaves your machine. Read the
admin password once, on the server, with
`sudo grep WM_ADMIN_PASSWORD /srv/windmill/.env`, and put it straight into your password
manager. No SMTP is configured, so there is no reset link if you lose it.

If you do not see mode `-rw-------`: the `umask 077` line did not run in the same shell as
the heredoc. Delete the file and paste the whole block again in one go.

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

You should see: `compose OK` and nothing else.

If you do not: a `variable is not set` warning means the shell wrote `.env` somewhere other
than /srv/windmill, or step 3 was skipped. `docker compose config` reads `.env` from the
directory you run it in, which is why the `cd` is part of the command. Three services, one
published port on loopback, one bind mount.

## 5. Caddy and TLS

Copy the Caddyfile before you touch it: a syntax error here takes down every other site on
the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.
Replace `<DOMAIN>` in the block with your hostname before you paste.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-windmill /etc/caddy/Caddyfile` and reload, then read
what validate objected to. The usual cause is a `<DOMAIN>` left literal. Caddy fetches the
certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 80/tcp, 443/tcp and 443/udp only.

If you do not: if 8193 or 5432 appears, remove it with `sudo ufw delete allow 8193`. Neither
needs a rule: 8193 is bound to 127.0.0.1 so only Caddy on this box can reach it, and compose
never publishes 5432 at all. Upstream's own compose also publishes port 25 for email
triggers; this install runs none, so 25 stays closed too.

## 7. Start and verify

The pull is well over a gigabyte and the server runs the database migrations on the way up.
Expect minutes, not seconds.

```bash
cd /srv/windmill
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/version); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/version; echo
curl -sS https://<DOMAIN>/api/health/status; echo
```

You should see: the loop counting up and ending on `200`, then a version string, then a JSON
object containing `"database_healthy":true` and `"workers_alive":1`.

If you do not: `502` for the first few minutes is normal while the migrations run. If it is
still `502` after ten minutes, run `docker compose logs --tail 40 windmill_server`. If
`workers_alive` is `0`, the server is fine and the worker is not: run
`docker compose logs --tail 40 windmill_worker`. A container that shows as running in
`docker compose ps` is not success on its own.

Windmill seeds exactly one account, `admin@windmill.dev`, with the password `changeme`, and
upstream's README tells new self-hosters to sign in with it. It is a superadmin, and the
login screen prefills both fields for you. Replace it now, before you open the page in a
browser. Paste this whole block at once, because the later lines use variables the first
lines set:

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

You should see, in this order: `setpassword 200`, `replay-default 400`, `unauth-whoami 401`,
one line reading `"email":"admin@windmill.dev"`, then `Created workspace main`, then
`windmill-selfhost-check`.

If you do not: `replay-default 400` is the important one. `400` with the body `Invalid login`
is what upstream returns for a wrong password, so a `400` here means the seeded credential is
dead. Anything else means it may still work, on a box that is on the public internet, and you
should stop and work out why before you go any further. `setpassword 401` means the first
login did not return a token, which happens if somebody has already changed the password.
`unauth-whoami 401` proves the rest of the API is closed: Windmill has no signup route, so
there is no registration to disable. The one-line email list only comes back for a valid
superadmin token, so it is also your proof the new password works. If the last call returns
an error about waiting for a result, run it once more; the worker's first job pays for
warming caches it keeps from then on. None of the values in `$WM_PASS`, `$TOKEN` or `$T`
belong in this chat window.

Now open https://<DOMAIN> in a browser and sign in as `admin@windmill.dev` with the password
you read in step 3. You should land in the `Main` workspace, with `Home` and `Runs` in the
left rail. That is the install finished; the rest of this page is the part that keeps it.

## 8. First backup and restore

Two artifacts. The database holds every script, flow, app, schedule, run and workspace key.
The config archive holds the files that rebuild the service around it.

```bash
cd /srv/windmill
docker compose exec -T db pg_dump -U windmill -d windmill | gzip > /srv/windmill/backups/windmill-db-$(date +%F).sql.gz
sudo tar -czf /srv/windmill/backups/windmill-config-$(date +%F).tar.gz -C /srv/windmill compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/windmill/backups/
```

You should see: two files, both with a size in kilobytes or better, neither at `0`.

If you do not: a zero-byte dump means the `db` container is not running or the password in
`.env` no longer matches the one PostgreSQL initialised with. Nothing is stopped for this,
because `pg_dump` snapshots a running database consistently, and a tar of `postgres/` would
be a copy of a live data directory rather than a backup. The two named volumes are left out
on purpose: they hold language caches and spilled logs, and both rebuild.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/windmill
scp vps:/srv/windmill/backups/* ~/backups/windmill/
```

To restore, cold, months from now: `docker compose down`, then
`sudo rm -rf /srv/windmill/postgres`, then recreate that directory exactly as step 2 did,
then untar the config archive into /srv/windmill so `.env` is back before anything starts,
then `docker compose up -d db` and wait for `docker compose ps` to show it healthy, then
`gunzip -c backups/windmill-db-<date>.sql.gz | docker compose exec -T db psql -U windmill -d windmill`,
and only then `docker compose up -d`. The order is the part people get wrong: the server
migrates the schema at boot, so a server that starts before the dump is loaded migrates an
empty database and the load collides with it.

## 9. Updating later

New versions are listed at https://github.com/windmill-labs/windmill/releases. Expect a
release most working days: the tag went from v1.780.0 to v1.789.0 in the ten days before this
was written, so treat the pin as a decision you re-make on your own schedule rather than a
queue to keep up with. The image tag drops the leading `v`: release `v1.789.0` is image tag
`1.789.0`. PostgreSQL stays on the 16 line, the major upstream's own compose file runs. Take
both backup artifacts first, then edit the two image lines in /srv/windmill/compose.yml to
the new tag and its digest, and run:

```bash
cd /srv/windmill
docker compose pull
docker compose up -d
docker compose logs --tail 40 windmill_server
```

You should see: the migrations run and the log settle, then `/api/version` from step 7
returning the new number.

If you do not: a container that restarts in a loop after an update is almost always a
migration that did not finish. Read the log before rolling back, and roll back by putting the
old tag and digest into compose.yml rather than by restoring the database, unless the log
says the schema itself moved.

## 10. What will probably go wrong

The pull. I watched it sit on what looked like a stalled progress bar for eleven minutes and
decided the registry was broken. It was not: one image carries Python, Bun, Deno, Go, PHP,
Java, Ruby, .NET, PowerShell, kubectl and helm, because a worker has to run whatever language
a script is written in, and that is gigabytes to move and unpack. The second surprise came
right after, when the first bash job took far longer than the second, because the worker was
warming caches it keeps from then on. If step 7's loop still prints `502` after ten minutes,
read `docker compose logs windmill_server`: the migrations are there.

## 11. Out of scope

- Do not set `NO_AUTH`. Every request then arrives as the `admin@windmill.dev` superadmin,
  and upstream means it only for an instance behind an authenticating gateway.
- Do not mount `/var/run/docker.sock` into the worker. Upstream comments that line out with a
  warning, and it hands every script author root on this host.
- Do not add `privileged: true` or turn nsjail on now. For job isolation later, upstream
  documents a route that keeps the container boundary: `DISABLE_NSJAIL=false` with
  `DISABLE_NUSER=true` and the `SYS_ADMIN`, `SYS_RESOURCE` and `SETPCAP` capabilities.
- Do not configure SMTP or an OAuth provider. Each is a separate signup.
