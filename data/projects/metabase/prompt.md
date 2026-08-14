You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Metabase 0.63.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and it becomes `MB_SITE_URL` in step 3.

Say one thing to the user first. Metabase runs on the JVM, which takes roughly a quarter of the
memory it can see as its heap ceiling: on a 2 GB box that is a 512 MB heap, and the bill arrives
later as a container that dies during somebody's third question. Upstream's own Azure guide asks
for at least 3.5 GB, so this install wants 4096 MB of RAM available and 10 GB free on /srv. Both
images publish amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 10 GB, print both numbers and stop. If
`dig +short` prints nothing, print that and stop: Caddy cannot certify a name that does not
resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/metabase /srv/metabase/backups
sudo install -d -m 700 /srv/metabase/postgres
ls -la /srv/metabase
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root, which the PostgreSQL image chowns to itself on first start. Metabase gets no directory: it
drops to uid 2000 and writes only `/plugins`, where it re-extracts the bundled Sample Database on
every start. Nothing there needs to survive, because every account, question, dashboard and
connection detail is a row in PostgreSQL.

## 3. Secrets

Two secrets, both generated on the server. `MB_DB_PASS` is the PostgreSQL password.
`MB_ENCRYPTION_SECRET_KEY` is the key Metabase encrypts stored connection details with, and the
command below is upstream's own instruction for making one. Do not print either, in your summary
or in any log line. `MB_SITE_URL` shares the file and is not a secret: it is the address Metabase
builds links from, with no trailing slash.

```bash
umask 077
cat > /srv/metabase/.env <<EOF
MB_SITE_URL=https://<DOMAIN>
MB_DB_PASS=$(openssl rand -hex 32)
MB_ENCRYPTION_SECRET_KEY=$(openssl rand -base64 32)
EOF
chmod 600 /srv/metabase/.env
umask 022
ls -l /srv/metabase/.env
```

Assert: mode `-rw-------`. Tell the user the key is in /srv/metabase/.env, that they read it with
`sudo grep MB_ENCRYPTION_SECRET_KEY /srv/metabase/.env`, and what upstream says about losing it:
connection details in a restored database cannot be decrypted without it. It goes in their
password manager today, somewhere other than where the backups land.

## 4. compose.yml

```bash
cat > /srv/metabase/compose.yml <<'EOF'
# Metabase · the deterministic fallback. Authored by caniselfhostit from the
# upstream docs and source at the pinned tag:
#   docker + app db .... https://github.com/metabase/metabase/blob/v0.63.2/docs/installation-and-operation/running-metabase-on-docker.md
#   variables .......... https://github.com/metabase/metabase/blob/v0.63.2/docs/configuring-metabase/environment-variables.md
#
# Two services: Metabase, and the PostgreSQL holding its own data, the
# accounts, questions, dashboards and encrypted connection details. What you
# analyse stays in the databases you connect later, read over the network.
#
# Digests read from Docker Hub on 2026-08-14; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.6-alpine@sha256:432b3b824c0769275ec9b0947736ef8b376d6997bcaa9de29818f613819c2feb
    container_name: metabase-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: metabase
      POSTGRES_USER: metabase
      POSTGRES_PASSWORD: ${MB_DB_PASS}
    volumes:
      # The 18 image puts the cluster one level down, so mount the parent.
      - /srv/metabase/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U metabase -d metabase"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  metabase:
    image: metabase/metabase:v0.63.2@sha256:252f8c9bd56dd21158005675b55876cf9fb838e0a0e0541581af859eafe1f32e
    container_name: metabase
    restart: unless-stopped
    # MB_SITE_URL, MB_DB_PASS and MB_ENCRYPTION_SECRET_KEY live here, mode 600.
    env_file: /srv/metabase/.env
    environment:
      # Without this the image writes an H2 file no mount here catches.
      MB_DB_TYPE: postgres
      MB_DB_HOST: postgres
      MB_DB_PORT: "5432"
      MB_DB_DBNAME: metabase
      MB_DB_USER: metabase
      # Default is true; an env var outranks what the wizard writes.
      MB_ANON_TRACKING_ENABLED: "false"
      # Every report and every scheduled hour is read in this zone.
      JAVA_TIMEZONE: UTC
    healthcheck:
      # Upstream's own: 503 with a progress number while migrations run.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://localhost:3000/api/health"]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 120s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8210.
      - "127.0.0.1:8210:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/metabase && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-metabase
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Metabase · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/metabase/metabase/blob/v0.63.2/src/metabase/server/middleware/security.clj
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also MB_SITE_URL in .env, which is
# where Metabase builds its links from. No security headers here: Metabase
# already sends HSTS, a CSP with frame-ancestors, X-Frame-Options DENY and
# nosniff of its own.

<DOMAIN> {
	encode zstd gzip

	header {
		-Server
	}

	# 8210 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8210
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-metabase, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it itself.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3. 8210 stays
closed because compose binds it to 127.0.0.1, 5432 because compose never publishes it. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8210, 5432 or 3000.

## 7. Start and verify

The first boot runs the whole migration set against an empty PostgreSQL and then extracts the
Sample Database, so it takes minutes rather than seconds. Use the loop.

```bash
cd /srv/metabase
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health; echo
curl -sSL https://<DOMAIN>/ | grep -c '<title>Metabase</title>'
curl -sS https://<DOMAIN>/api/session/properties | grep -oE '"(has-user-setup":[a-z]*|setup-token":")'
```

Assert all four and print what you received. The loop ends printing `200`. The health call prints
`{"status":"ok"}`, which upstream returns only once start-up is complete and the application
database answers. The third prints a number above `0`, that title being what Metabase renders
into its own page. The fourth prints `"has-user-setup":false` and `"setup-token":"`,
and that pair is the open door: Metabase mints a setup token on first
launch and publishes it as a public setting, so anyone loading this hostname can post it to
`/api/setup` and become the administrator here.

If any of the four misses, stop, run `docker compose logs --tail 40 metabase`, then
`docker compose logs --tail 20 postgres`, and name the likely earlier step. A `503` reading
`{"status":"initializing"` is this step unfinished, not a failure. A container that exits on a
database error points at step 3. A running container is not success.

STOP: tell the user to open https://<DOMAIN>/setup, complete the wizard that creates their
administrator account, and wait. Do not continue until they confirm.
Two things while they work. The password comes out of their password manager at twenty characters
or more, because upstream's shipped rule accepts six characters with one digit and this hostname
is public. And when the wizard offers to connect a database, choose to add data later.

Once they confirm, prove the door is shut:

```bash
curl -sS https://<DOMAIN>/api/session/properties | grep -oE '"(has-user-setup|setup-token)":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"token":"CHANGE_ME","user":{"first_name":"a","last_name":"b","email":"a@example.com","password":"CHANGE_ME"},"prefs":{"site_name":"x"}}' https://<DOMAIN>/api/setup
```

Assert: the first prints `"has-user-setup":true` and `"setup-token":null`, the second `400`.
Upstream clears the token the moment the first user exists, so the value published a minute ago
is gone for good, and `/api/setup` refuses a token that does not match. Both before you report
success.

STOP: tell the user to sign in and do two things, then wait. Do not continue until they confirm.
One: open `+ New`, choose `Question`, pick the `Orders` table of the `Sample Database` that ships
inside the image, summarize it as a count of rows grouped by a date column, and save it. That is
the whole loop, on data already there. Two: click the grid icon top right, choose `Admin`, then
`Databases` and `Add a database`, and connect one of their own. The address they type has to be
reachable from the container, so `localhost` there is the container and not the VPS.

## 8. First backup and restore

Two artifacts. The database holds every account, question, dashboard and connection detail; the
config archive holds what rebuilds the service around it, including the key without which those
connection details are unreadable.

```bash
cd /srv/metabase
docker compose exec -T postgres pg_dump -U metabase -d metabase | gzip > /srv/metabase/backups/metabase-db-$(date +%F).sql.gz
sudo tar -czf /srv/metabase/backups/metabase-config-$(date +%F).tar.gz -C /srv/metabase compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/metabase/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. A backup on the same disk is not a backup,
so run this from the user's machine:

```bash
mkdir -p ~/backups/metabase
scp vps:/srv/metabase/backups/* ~/backups/metabase/
```

To restore: `docker compose down`, `sudo rm -rf /srv/metabase/postgres`, recreate it as in step
2, untar the config archive into /srv/metabase so `.env` is back before anything starts,
`docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U metabase -d metabase`, then `docker compose up -d`.
Order matters: a Metabase started against an empty database writes a fresh schema and you do this
twice. Say what is in neither file, because it is what people assume: none of the data they
analyse, which is read live from the database they connected and never copied here.

## 9. Updating later

New versions are listed at https://github.com/metabase/metabase/releases. Read the numbers.
One repository ships two lines: `v0.x` tags are the open source build published as the
`metabase/metabase` image, `v1.x` tags the commercial build published as
`metabase/metabase-enterprise`, which wants a license key. `v1.63.2` is this same release under a
different license, so stay on `v0`.

Docker Hub also carries patch tags upstream has not tagged in the repository, so a tag there is
not proof the source behind it is public. This pins 0.63.2 because it is the newest release
upstream has both tagged and published.

Take both backup artifacts first, then edit the image line in /srv/metabase/compose.yml to the
new tag and its digest:

```bash
cd /srv/metabase
docker compose pull
docker compose up -d
docker compose logs --tail 40 metabase
```

Metabase migrates on the way up, and upstream is explicit that a major version upgrade changes
the schema, with going back meaning either the backup or a `migrate down` run from the higher
version. Watch the log until it settles, then re-run step 7's health check.

## 10. What will probably go wrong

The first boot looks like a hang. I ran `docker compose up -d`, curled the hostname, got a `502`
from Caddy, curled again a minute later and got a `503` whose body said `{"status":"initializing"`,
and spent several minutes certain the reverse proxy was wrong. It was not. Metabase runs its whole
migration set against an empty PostgreSQL before it answers anything, and on a small box that is
two to four minutes in which every symptom of a broken install is present. Do not restart the
container to hurry it, and leave the Caddy block alone until step 7's loop has run forty times.

## 11. Out of scope

- Do not configure SMTP. Metabase runs without it. Dashboard subscriptions, alerts and the
  password reset link do not, and each wants a relay a fresh VPS on port 25 will not be.
- Do not switch to the `metabase-enterprise` image and do not set a license token. That build is
  under the Metabase Commercial License and needs a subscription.
- Do not put driver jars in /plugins. It is rebuilt from the image on every start, and the pinned
  image already carries PostgreSQL, MySQL, SQL Server, SQLite, MongoDB and BigQuery.
- Do not publish 3000 or 5432 on the host and do not open either in the firewall. Caddy is the
  only way in, and PostgreSQL is reachable only from the other container.
