This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Metabase 0.63.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1, because it is the shape of the whole thing. Metabase keeps its own data
in a PostgreSQL you also run here: your accounts, your questions, your dashboards and the
encrypted connection details. The data you analyse is not in it. That lives in whatever
databases you connect afterwards, Metabase reads them live over the network, and step 7 is where
you connect the first one.

## 1. Preflight

Metabase runs on the JVM, which takes roughly a quarter of the memory it can see as its heap
ceiling. On a 2 GB box that is a 512 MB heap, and the bill arrives later as a container that
dies during somebody's third question. Upstream's own Azure guide asks for at least 3.5 GB.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that does
not resolve and failed attempts count against a rate limit you cannot see. If the memory number
is short, stop here rather than installing and hoping: this is the one number on this page that
is not a preference.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/metabase /srv/metabase/backups
sudo install -d -m 700 /srv/metabase/postgres
ls -la /srv/metabase
```

You should see: `backups` owned by you, and `postgres` at mode `700` owned by `root`.

If you do not: the two owners are deliberate. The PostgreSQL image chowns its own data directory
to its own uid on first start, so root is correct there and you should not fix it. Metabase gets
no directory at all: it drops to uid 2000 and writes only `/plugins` inside the container, where
it re-extracts the bundled Sample Database on every start. Nothing there needs to survive,
because every account, question, dashboard and connection detail is a row in PostgreSQL.

## 3. Secrets

Two secrets. `MB_DB_PASS` is the PostgreSQL password. `MB_ENCRYPTION_SECRET_KEY` is the key
Metabase encrypts stored connection details with, and the command below is upstream's own
instruction for making one. `MB_SITE_URL` shares the file and is not a secret: it is the address
Metabase builds its links from, and it takes no trailing slash.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take, which happens when the
lines are pasted separately into different shells. Run `chmod 600 /srv/metabase/.env` and carry
on. If the file already existed from an earlier attempt, this has now replaced both values, which
is harmless before the first boot and expensive afterwards: a changed `MB_DB_PASS` no longer
matches the database PostgreSQL already built, and a changed encryption key makes every stored
connection detail unreadable.

Do not paste that file, either value, or any command output containing them into this chat
window. Read the key once with `sudo grep MB_ENCRYPTION_SECRET_KEY /srv/metabase/.env`, put it in
your password manager, and keep it somewhere other than where your backups land. Upstream is
blunt about this: without that key, connection details in a restored database cannot be
decrypted and every data source has to be entered again.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK`, and nothing else.

If you do not: `variable is not set` for `MB_DB_PASS` means step 3's file is missing or is not in
/srv/metabase, because compose reads `.env` from the directory you run it in. A YAML error is
almost always a partial paste; delete the file and paste the whole block again in one go.

## 5. Caddy and TLS

Copy the Caddyfile first. A syntax error here takes down every site on this box, not only this
one.

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

You should see: `Valid configuration` from validate, and nothing at all from the reload.

If you do not: put the backup back with
`sudo cp /etc/caddy/Caddyfile.before-metabase /etc/caddy/Caddyfile`, reload, and read what
validate objected to. The usual cause is `<DOMAIN>` still being literal in the block you pasted.
Caddy gets the certificate on the first request and renews it itself, so there is nothing to
schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 80/tcp, 443/tcp and 443/udp.

If you do not: 80/tcp answers the ACME challenge, 443/tcp is the only way in, 443/udp is HTTP/3.
If you also see a rule for 8210 or 5432 from an earlier attempt, delete it with
`sudo ufw delete allow 8210`. Neither should ever be open: 8210 is bound to 127.0.0.1 and 5432
is never published to the host at all.

## 7. Start and verify

The first boot runs the whole migration set against an empty PostgreSQL and then extracts the
Sample Database, so it takes minutes rather than seconds. The loop is not decoration.

```bash
cd /srv/metabase
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health; echo
curl -sSL https://<DOMAIN>/ | grep -c '<title>Metabase</title>'
curl -sS https://<DOMAIN>/api/session/properties | grep -oE '"(has-user-setup":[a-z]*|setup-token":")'
```

You should see: the loop counting up and ending on `200`, then `{"status":"ok"}`, then a number
above `0`, then two lines, `"has-user-setup":false` and `"setup-token":"`.

If you do not: a `503` whose body reads `{"status":"initializing"` with a progress number is this
step unfinished rather than a failure, so let the loop run. A `502` from Caddy for all forty
iterations means the container is not answering at all: run `docker compose logs --tail 40
metabase` and `docker compose logs --tail 20 postgres`. A container that exits by itself on a
database error points back at step 3, because the password in .env and the one PostgreSQL was
built with have to match. A running container is not success.

Those last two lines are the open door, and you should read them as one sentence. Metabase mints
a setup token on first launch and publishes it as a public setting, so anyone who loads this
hostname right now can post it to `/api/setup` and become the administrator of your instance.
Nothing else is needed. Close it in the next five minutes rather than tomorrow.

Open https://<DOMAIN>/setup in a browser and complete the wizard, which creates your
administrator account. Two things while you are in there. Your password comes out of your
password manager at twenty characters or more, because upstream's shipped rule accepts six
characters with one digit and this hostname is on the open internet. And when the wizard offers
to connect a database, choose to add data later; you do that properly at the end of this step.

Then prove the door is shut:

```bash
curl -sS https://<DOMAIN>/api/session/properties | grep -oE '"(has-user-setup|setup-token)":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"token":"CHANGE_ME","user":{"first_name":"a","last_name":"b","email":"a@example.com","password":"CHANGE_ME"},"prefs":{"site_name":"x"}}' https://<DOMAIN>/api/setup
```

You should see: `"has-user-setup":true` and `"setup-token":null` from the first command, and
`400` from the second.

If you do not: `"has-user-setup":false` means the wizard did not finish, so go back and finish
it, and do not walk away from the machine until it says true. Upstream clears the setup token the
moment the first user exists, which is why the value you saw a minute ago is now `null`, and
`/api/setup` answers `400` to a token that does not match. Both of these before you call this
done.

Now the part the install is for. Sign in and do two things. One: open `+ New`, choose `Question`,
pick the `Orders` table of the `Sample Database` that ships inside the image, summarize it as a
count of rows grouped by a date column, and save it. That is the entire loop, on data that is
already there, and it takes about a minute. Two: click the grid icon top right, choose `Admin`,
then `Databases` and `Add a database`, and connect one of your own. The address you type has to
be reachable from inside the container, so `localhost` there means the Metabase container and
not the VPS: a database running elsewhere on this same box is reached at the Docker bridge
address or by putting both on one compose network.

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

You should see: two files, both with a size that is not `0`.

If you do not: an empty `.sql.gz` means `pg_dump` failed, usually because the container is not up
yet. Nothing was stopped for this, because `pg_dump` snapshots a running database consistently.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/metabase
scp vps:/srv/metabase/backups/* ~/backups/metabase/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/metabase/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one saved question:

```bash
cd /srv/metabase
docker compose down
sudo rm -rf /srv/metabase/postgres
sudo install -d -m 700 /srv/metabase/postgres
sudo tar -C /srv/metabase -xzf /srv/metabase/backups/metabase-config-$(date +%F).tar.gz compose.yml .env
docker compose up -d postgres
sleep 20
gunzip -c /srv/metabase/backups/metabase-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U metabase -d metabase
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/session/properties | grep -oE '"has-user-setup":[a-z]*'
```

You should see: the loop ending on `200`, then `"has-user-setup":true`, from a database volume
that was deleted two minutes ago, which means your account and your saved question came back.

If you do not: `"has-user-setup":false` means Metabase started against an empty database and
wrote a fresh schema into it, which is what happens if you start the app before loading the dump.
That is why `docker compose up -d postgres` names the one service. Run the block again in order.
Neither archive contains any of the data you analyse: that is read live from the database you
connected and is its own owner's backup problem.

## 9. Updating later

New versions are listed at https://github.com/metabase/metabase/releases. Read the numbers. One
repository ships two lines: `v0.x` tags are the open source build published as the
`metabase/metabase` image, `v1.x` tags the commercial build published as
`metabase/metabase-enterprise`, which wants a license key. `v1.63.2` is this same release under a
different license, so stay on `v0`.

Docker Hub also carries patch tags upstream has not tagged in the repository, so a tag there is
not proof the source behind it is public. This install pins 0.63.2 because it is the newest
release upstream has both tagged and published.

Take both backup artifacts first, then edit the `image:` line in /srv/metabase/compose.yml to the
new tag and its digest.

```bash
cd /srv/metabase
docker compose pull
docker compose up -d
docker compose logs --tail 40 metabase
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Upstream is
explicit that a major version upgrade changes the application database schema, and that going
back afterwards means either restoring the backup or running `migrate down` from the higher
version, so the archive you took two minutes ago is the rollback plan rather than a formality.

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
