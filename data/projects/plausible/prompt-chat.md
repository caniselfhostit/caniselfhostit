This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Plausible CE 3.2.1 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `BASE_URL`, and it is written into the tracking
snippet you paste on every page you measure. Changing it later means editing every one of those
pages, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
grep -o -m1 -E 'sse4_2|asimd' /proc/cpuinfo || echo "NO SSE4.2 OR NEON"
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, then
`sse4_2` on an Intel or AMD box or `asimd` on an Arm one, then your server's IP.

If you do not: `NO SSE4.2 OR NEON` means ClickHouse will not start on this processor, and no
amount of configuration fixes that, so move to a different box. Under 2048 MB is the one to take
seriously here. ClickHouse is a column store built for machines with 16 GB, and on a box that is
short of memory the kernel kills it, usually in the middle of writing rather than politely at
start-up. An empty last line means the A record does not exist yet: add it, wait a minute, run
`dig +short <DOMAIN>` again. Caddy cannot get a certificate for a name that does not resolve,
and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/plausible /srv/plausible/backups /srv/plausible/clickhouse
sudo install -d -m 700 /srv/plausible/postgres /srv/plausible/clickhouse/data
sudo install -d -m 750 -o 999 -g 999 /srv/plausible/data
```

You should see: nothing at all. Then paste the ClickHouse tuning file, which the compose file in
step 4 mounts read-only. Without it ClickHouse behaves as though this were a 16 GB machine.

```bash
cat > /srv/plausible/clickhouse/plausible-ce.xml <<'EOF'
<clickhouse>
  <!-- Sized for a small machine, not the 16 GB one ClickHouse assumes. -->
  <logger><level>warning</level><console>true</console></logger>
  <listen_host>0.0.0.0</listen_host>
  <mark_cache_size>524288000</mark_cache_size>
  <max_server_memory_usage_to_ram_ratio>0.6</max_server_memory_usage_to_ram_ratio>
  <metric_log remove="remove"/><asynchronous_metric_log remove="remove"/>
  <query_log remove="remove"/><query_thread_log remove="remove"/>
  <trace_log remove="remove"/><part_log remove="remove"/>
</clickhouse>
EOF
chmod 644 /srv/plausible/clickhouse/*.xml
ls -la /srv/plausible /srv/plausible/clickhouse
```

You should see: `backups` and `clickhouse` owned by you, `postgres` and `clickhouse/data` at
`drwx------` owned by root, `data` owned by `999`, and `plausible-ce.xml` in the second listing.

If you do not: leave those three ownerships exactly as they are. PostgreSQL and ClickHouse each
chown their own data directory the first time they start, and one you have already chowned to
yourself makes them refuse to initialise. The `999` on `data` is the uid the Plausible image runs
as, and it needs to write exports and temporary files there.

## 3. Secrets

Three secrets, all generated here on the server: the session key base, the key that encrypts
two-factor secrets at rest, and the PostgreSQL password. Replace `<DOMAIN>` on the first line
with your hostname before you paste.

```bash
umask 077
cat > /srv/plausible/.env <<EOF
BASE_URL=https://<DOMAIN>
SECRET_KEY_BASE=$(openssl rand -base64 48)
TOTP_VAULT_KEY=$(openssl rand -base64 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/plausible/.env
umask 022
ls -l /srv/plausible/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Upstream documents the
key base as needing at least a 64-byte string, which `openssl rand -base64 48` produces, and the
vault key as a 32-byte value that encrypts two-factor secrets with AES256-GCM.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when
you paste the lines separately into different shells. Run `chmod 600 /srv/plausible/.env` and
carry on. If the file already existed from an earlier attempt you have now overwritten all three
values, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed one on an existing data directory shows up as an
authentication failure in the Plausible log rather than as anything about passwords.

Do not paste that file, any of the three values, or any command output containing them into this
chat window. They are the only copies you have, and step 8 is what backs them up.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/plausible/compose.yml <<'EOF'
# Plausible CE · the deterministic fallback, authored by caniselfhostit from
# https://plausible.io/docs/self-hosting , the quick start at
# https://github.com/plausible/community-edition , its wiki page
# https://github.com/plausible/community-edition/wiki/configuration and
# https://clickhouse.com/docs/en/operations/tips . Not copied from a repository.
#
# Three services: the app, the PostgreSQL holding accounts and sites, and the
# ClickHouse holding every pageview event, which assumes a 16 GB machine and is
# cut down by the read-only XML file step 2 writes. Neither database
# publishes a host port. Digests read 2026-08-05; amd64 and arm64 both.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  plausible_db:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_DB: plausible_db
      POSTGRES_USER: plausible
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/plausible/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U plausible -d plausible_db"]
      interval: 10s
      retries: 18
    # No `ports:`: 5432 is reachable only from the other containers.

  plausible_events_db:
    image: clickhouse/clickhouse-server:24.12.6.70-alpine@sha256:cd450891db46cc6ffe313ca2b0fb7dbfb897a6873ca74a724cbe050a2cf62621
    restart: unless-stopped
    environment:
      CLICKHOUSE_SKIP_USER_SETUP: "1"
    volumes:
      - /srv/plausible/clickhouse/data:/var/lib/clickhouse
      - /srv/plausible/clickhouse/plausible-ce.xml:/etc/clickhouse-server/config.d/plausible-ce.xml:ro
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8123/ping || exit 1"]
      interval: 10s
      retries: 18
    # No `ports:`: 8123 stays on the compose network.

  plausible:
    image: ghcr.io/plausible/community-edition:v3.2.1@sha256:33e60bfb40f2df5da00f8753b76fad04f67dba3abe6d73eb516e440e3fb62985
    restart: unless-stopped
    command: sh -c "/entrypoint.sh db createdb && /entrypoint.sh db migrate && /entrypoint.sh run"
    env_file: /srv/plausible/.env
    environment:
      TMPDIR: /var/lib/plausible/tmp
      # Caddy terminates TLS on the host, so HTTPS_PORT stays unset here.
      HTTP_PORT: "8000"
      DISABLE_REGISTRATION: "true"
      DATABASE_URL: postgres://plausible:${POSTGRES_PASSWORD}@plausible_db:5432/plausible_db
      CLICKHOUSE_DATABASE_URL: http://plausible_events_db:8123/plausible_events_db
    volumes:
      - /srv/plausible/data:/var/lib/plausible
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8093.
      - "127.0.0.1:8093:8000"
    depends_on:
      plausible_db:
        condition: service_healthy
      plausible_events_db:
        condition: service_healthy
EOF
cd /srv/plausible && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/plausible/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal;
run `rm /srv/plausible/compose.yml` and paste again in one go. The `command:` line is upstream's
and it is safe on every restart: it creates both databases, runs every pending migration across
them, then starts the server, and a database that already exists is reported and skipped.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-plausible
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Plausible CE · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/plausible/community-edition/wiki/reverse-proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box, which is also BASE_URL
# in .env and is baked into the tracking snippet on every page you measure. The
# dashboard is a LiveView: reverse_proxy passes its WebSocket upgrade unaided.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No X-Frame-Options: Plausible's shared dashboards are meant to be iframed.

	# 8093 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8093
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-plausible /etc/caddy/Caddyfile`, reload,
and paste again. Caddy asks for the certificate on the first request and renews it on its own,
so there is nothing to schedule and nothing to renew by hand later.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8093`, `5432` or `8123`.

If you do not: delete anything for those three with `sudo ufw delete allow 8093`. 8093 is bound
to 127.0.0.1 by the compose file, and 5432 and 8123 are never published at all, so neither
database has a host port a firewall rule could apply to. 80/tcp is there to answer the ACME
challenge and redirect to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy
offers by default. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first start creates both databases and runs every migration, and ClickHouse takes minutes to
lay out its data directory. The loop below waits up to ten minutes. Let it run.

```bash
cd /srv/plausible
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/system/health/ready); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/system/health/ready
curl -sSL https://<DOMAIN>/ | grep -c 'Register your Plausible CE account'
```

You should see, in order: the loop counting up and ending on `200`, then a small JSON object in
which `"clickhouse"` and `"postgres"` both read `ok`, then `1`. That `1` is the real test: with
no account yet, https://<DOMAIN>/ redirects to https://<DOMAIN>/register, whose first screen
carries the heading `Register your Plausible CE account`.

If you do not: run `docker compose logs --tail 40 plausible`. `connection refused` against
ClickHouse points back at step 2, where a missing or unreadable XML file stops that container.
A 502 from Caddy means Plausible is still migrating, which is normal for the first few minutes.
A certificate error means the A record from step 1. A `0` from the last command with a `200`
from the loop usually means an account already exists on this instance, in which case the root
URL goes to the login page instead.

STOP: open https://<DOMAIN>/register in a browser, create your account with an email address and
a password you keep in your password manager, then come back here.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
```

You should see: `302`.

If you do not: a `200` means registration is still open, which it must not be. Check that
`DISABLE_REGISTRATION` is `true` in /srv/plausible/compose.yml and that your account really was
created. Upstream lets that setting be bypassed exactly once, for the first account on an
instance with no users; after that the register page redirects to the login form and nobody can
sign themselves up. A running container is not success. Both of these asserts have to pass.

## 8. First backup and restore

Three artifacts. PostgreSQL holds the accounts, the sites and the settings. ClickHouse holds
every event ever recorded. The config archive holds what rebuilds the service around them,
including the only copy of your three secrets.

```bash
cd /srv/plausible
docker compose exec -T plausible_db pg_dump -U plausible -d plausible_db | gzip > /srv/plausible/backups/plausible-pg-$(date +%F).sql.gz
docker compose stop
sudo tar -C /srv/plausible/clickhouse -czf /srv/plausible/backups/plausible-events-$(date +%F).tar.gz data
sudo tar -C /srv/plausible -czf /srv/plausible/backups/plausible-config-$(date +%F).tar.gz compose.yml .env clickhouse/plausible-ce.xml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/plausible/backups/
```

You should see: three files, none of them tiny. The site is down for about half a minute while
the events archive is taken.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error. The
ClickHouse archive is deliberately taken with the containers stopped, because copying that
directory underneath a running server produces an archive that restores into corruption.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/plausible
scp vps:/srv/plausible/backups/* ~/backups/plausible/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/plausible/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/plausible
docker compose down
sudo rm -rf /srv/plausible/postgres /srv/plausible/clickhouse/data
sudo install -d -m 700 /srv/plausible/postgres /srv/plausible/clickhouse/data
sudo tar -C /srv/plausible/clickhouse -xzf /srv/plausible/backups/plausible-events-$(date +%F).tar.gz
docker compose up -d plausible_db
sleep 30
gunzip -c /srv/plausible/backups/plausible-pg-$(date +%F).sql.gz | docker compose exec -T plausible_db psql -U plausible -d plausible_db
docker compose up -d
sleep 60
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/system/health/ready
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command, and
your account still works when you log in.

If you do not: `role "plausible" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. If you ever restore onto a new
machine, put the config archive back before anything starts: PostgreSQL reads .env the moment it
initialises an empty directory, and a missing .env means a blank password and a database that
will not come up.

## 9. Updating later

New versions are listed at https://github.com/plausible/analytics/releases, and upstream ships
roughly two a year. Take all three backup artifacts first, then edit the `image:` line in
/srv/plausible/compose.yml to the new tag and its digest.

```bash
cd /srv/plausible
docker compose pull
docker compose up -d
docker compose logs --tail 40 plausible
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Read the release
notes for a major version before you take one: those can carry a data migration that runs longer
than the container's own start-up allowance, and interrupting it halfway is worse than waiting.
Re-run the health check from step 7 before you call the update done.

## 10. What will probably go wrong

ClickHouse is the part that will scare you. On the first start it lays out its data directory and
answers nothing for minutes while Plausible retries migrations against it and logs connection
failures that read like a broken install. I reached for `docker compose down` twice before the
health endpoint went green at about the four-minute mark, both times interrupting an install that
was working. Let step 7's loop run its full ten minutes first. And the XML file in step 2 is load
bearing: delete it because the install "works without it", and ClickHouse goes back to assuming
16 GB with the kernel taking that container in your first busy hour.

## 11. Out of scope

- Do not configure SMTP. Plausible CE runs without it; what you give up is password-reset mail
  and the emailed weekly report, neither worth a port-25 fight on a fresh VPS.
- Do not set `MAXMIND_LICENSE_KEY` or `IP_GEOLOCATION_DB`. Country data needs a MaxMind account,
  and this install trades the map for not having one.
- Do not set `GOOGLE_CLIENT_ID` or `GOOGLE_CLIENT_SECRET`. Search Console is its own registration
  in Google Cloud.
- Do not set `HTTPS_PORT` and do not publish 80 or 443 from the container. The image carries its
  own certbot, which would fight Caddy over one certificate.
