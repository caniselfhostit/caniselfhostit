You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install FerretDB 2.7.0 on that server, answering the MongoDB wire protocol on 127.0.0.1:8191,
with no public hostname and no site block added to Caddy.

## 1. Preflight

Say three things first; no later configuration changes them.

One, compatibility. FerretDB speaks the MongoDB wire protocol over PostgreSQL with DocumentDB
extension. Upstream states that all drivers and applications compatible with MongoDB 5.0+ should
be compatible with FerretDB, and marks CRUD, indexes, `aggregate`, `count` and `distinct`
supported. The published gaps: transactions, `bulkWrite`, every role-management command,
`setParameter`, `killOp` and `profile` are not implemented, and error messages can differ where
the names match. Atlas Search, Atlas Vector Search, Charts and Triggers are services MongoDB runs
beside the database and none exist here; FerretDB's own text and vector search are different
features with different syntax.

Second, there is no browser interface and no sign-in: what connects to a database is a driver, a
shell, or an application the user writes.

Third, this prompt has no placeholder and no domain, no hostname to ask for and no certificate to
issue, because the wire protocol is not HTTP.

FerretDB and its PostgreSQL need 2048 MB of RAM available and 10 GB free on /srv. Both images
publish amd64 and arm64. Measure all three:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. The disk floor is not padding: the service images are about 1 GB together
and step 7's shell image unpacks to 1.5 GB more.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ferretdb /srv/ferretdb/backups
sudo install -d -m 700 /srv/ferretdb/postgres
sudo install -d -m 750 -o 1000 -g 1000 /srv/ferretdb/state
ls -la /srv/ferretdb
```

Assert: `backups` owned by the login user, `postgres` at mode `700` owned by root, `state` owned
by uid `1000`. Leave `postgres` alone: the PostgreSQL image chowns its own data directory on first
start and refuses one already claimed. 1000 is the uid in the FerretDB image's passwd file, and
`state` holds the instance UUID only.

## 3. Secrets

One secret doing two jobs: the PostgreSQL password FerretDB uses for its storage, and the
password every MongoDB client sends, because FerretDB stores no accounts and forwards what it
receives to PostgreSQL for validation. Generate it on the server, print it nowhere, and keep it
out of any log line. Hex, because it rides inside a connection string.

```bash
umask 077
cat > /srv/ferretdb/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/ferretdb/.env
umask 022
ls -l /srv/ferretdb/.env
```

Assert: the file exists with mode `-rw-------`. That value is the whole security boundary of this
database: upstream states authorization is not yet supported, so every valid login has full access
to everything, and a second user made with `db.createUser` buys credential separation only.

## 4. compose.yml

```bash
cat > /srv/ferretdb/compose.yml <<'EOF'
# FerretDB · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.ferretdb.io/installation/ferretdb/docker/
#   documentdb image ... https://docs.ferretdb.io/installation/documentdb/docker/
#   authentication ..... https://docs.ferretdb.io/security/authentication/
#
# FerretDB turns the MongoDB wire protocol into SQL; PostgreSQL beside it holds
# the DocumentDB extension. The two tags are a matched pair: the 2.7.0 release
# notes name 0.107.0-ferretdb-2.7.0 as its match. Move them together.
#
# Digests read from ghcr.io on 2026-08-14; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0@sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7
    container_name: ferretdb-postgres
    restart: unless-stopped
    environment:
      # Upstream requires a `postgres` database to exist before FerretDB
      # connects, so this name is not a preference.
      POSTGRES_DB: postgres
      POSTGRES_USER: ferretdb
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/ferretdb/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ferretdb -d postgres"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the sibling container.

  ferretdb:
    image: ghcr.io/ferretdb/ferretdb:2.7.0@sha256:5706414241eb84f0515512c37b46db0f1b1eac9e5ceb7e4c2523211c184b1985
    container_name: ferretdb
    restart: unless-stopped
    environment:
      # FerretDB keeps no accounts: it forwards what a client sends to
      # PostgreSQL, so this role is also the MongoDB login.
      FERRETDB_POSTGRESQL_URL: "postgres://ferretdb:${POSTGRES_PASSWORD}@postgres:5432/postgres"
      # Upstream's default `undecided` behaves as enabled after an hour. Off
      # here; the cost is losing the new-version notice (step 9).
      FERRETDB_TELEMETRY: disable
    volumes:
      # /state is a declared volume the image writes as uid 1000, holding the
      # instance UUID and nothing of yours.
      - /srv/ferretdb/state:/state
    ports:
      # Loopback only, and no reverse proxy: the wire protocol is not HTTP,
      # so 8191 answers on this box alone.
      - "127.0.0.1:8191:27017"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/ferretdb && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose reads `${POSTGRES_PASSWORD}` from the `.env` step 3
wrote here, which is why it runs after a `cd`.

## 5. Caddy and TLS

No reverse proxy and no certificate, and that is a decision rather than an omission. Write the
record of it beside the compose file and leave the host's Caddy alone:

```bash
cat > /srv/ferretdb/Caddyfile <<'EOF'
# FerretDB · this service gets no Caddy site block, and this file is the record
# of that decision rather than something to append to /etc/caddy/Caddyfile.
#
# Authored by caniselfhostit from
# https://docs.ferretdb.io/security/tls-connections/ and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# The MongoDB wire protocol on TCP 27017 is binary traffic on a long-lived
# socket, not HTTP: `reverse_proxy` has nothing to carry and no hostname to
# certify. Reaching 127.0.0.1:8191 from off this box means an ssh port forward,
# or FERRETDB_LISTEN_TLS with certificates you issue. Never a proxy.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.
EOF
sudo awk '/ferretdb/ {n++} END {print n+0}' /etc/caddy/Caddyfile
```

Assert: that prints `0`, and nothing is reloaded because nothing changed. Above zero means an
earlier attempt appended a block to the host Caddyfile: take it out first, because a site block
pointing at 8191 publishes a database to the internet.

## 6. Firewall

This install opens no port. Print the current state and change none of it:

```bash
sudo ufw status verbose
```

Assert: `Status: active`, and no rule mentioning `8191`, `27017` or `5432`. 8191 is loopback, so a
rule for it would mean nothing; 5432 is never published, so that container has no host port to
firewall; 80 and 443 belong to other services, because nothing here answers HTTP. If a rule for
8191 or 27017 exists, remove it with `sudo ufw delete allow 8191`.

## 7. Start and verify

```bash
cd /srv/ferretdb
docker compose pull
docker compose up -d
for i in $(seq 1 36); do s=$(docker inspect --format '{{.State.Health.Status}}' ferretdb 2>/dev/null); echo "$i ${s:-none}"; [ "$s" = healthy ] && break; sleep 5; done
docker inspect --format '{{.State.Health.Status}}' ferretdb
```

Assert: that prints `healthy`. Upstream builds a `HEALTHCHECK` into the image that behaves as a
readiness probe, and it passes only when a MongoDB protocol connection can be made and DocumentDB
is installed correctly, so that word covers both containers. If the loop never leaves `starting`,
stop, run `docker compose logs --tail 40 ferretdb` and `docker compose logs --tail 20 postgres`,
and name the cause: a PostgreSQL that never reports healthy is step 2, and a FerretDB that exits
after starting is usually step 3, where an empty password invalidates the connection string. There
is no first screen, and a running container is not success. The round trip below is.

STOP: tell the user to read the password with `sudo grep POSTGRES_PASSWORD /srv/ferretdb/.env`
and put it in their password manager.
Do not continue until they confirm they have stored it.
Losing it loses the database: there is no reset link and no admin screen, and the only way back is
an `ALTER USER` inside the PostgreSQL container.

Once they confirm, prove the wire protocol. The shell is `mongosh` out of FerretDB's own
evaluation image, pinned by digest and run with its entrypoint overridden so nothing else it
carries starts. Upstream's own line puts MongoDB's `mongo` image there:

```bash
MSH=ghcr.io/ferretdb/ferretdb-eval:2.7.0@sha256:1bf47a449dd65839aabfc1a535d1370c98326f8a90de20437eda0aeb30bd8dd5
PGPW=$(sudo grep '^POSTGRES_PASSWORD=' /srv/ferretdb/.env | cut -d= -f2-)
docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet "mongodb://ferretdb:${PGPW}@127.0.0.1:27017/appdb" --eval 'db.selfhost_check.insertOne({ok:1}); printjson(db.selfhost_check.findOne())'
unset PGPW
docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet "mongodb://127.0.0.1:27017/appdb" --eval 'db.selfhost_check.insertOne({anon:1})'; echo "exit=$?"
```

Assert both and print what came back. The first prints a document holding `ok: 1` and an `_id`: a
write and a read through the wire protocol, into PostgreSQL and out again. The second must fail,
printing an authentication or authorization error and a non-zero `exit=`, and that is the security
assert here. Be as precise as upstream is: an anonymous client can still open a socket, and what
it cannot do is read or write anything. If it inserts a document instead, stop and check that step
4 kept `FERRETDB_POSTGRESQL_URL` intact, because a FerretDB with no password in its connection
string has no authentication. Drop the test document later with `db.selfhost_check.drop()`.

STOP: hand the user their connection string,
`mongodb://ferretdb:<the value in .env>@127.0.0.1:8191/appdb`, and say where it works: from an
application on this box as written, from a container joining this project's network with
`ferretdb:27017` instead of the loopback address, and from their laptop only inside a port
forwarded with `ssh -N -L 27017:127.0.0.1:8191 vps`.
Do not continue until they confirm which of those three their application will use.

## 8. First backup and restore

One archive, taken cold: a data directory copied while PostgreSQL is writing is not a backup, and
a file copy of a stopped cluster is correct at any size.

```bash
cd /srv/ferretdb
docker compose stop
sudo tar -czf /srv/ferretdb/backups/ferretdb-$(date +%F).tar.gz -C /srv/ferretdb postgres state .env compose.yml Caddyfile
docker compose start
ls -lh /srv/ferretdb/backups/
```

Assert: the archive exists and is non-empty. Print its size, tens of megabytes fresh and growing. Downtime is about ten seconds. Treat it as credential
material: it holds `.env` and every document. Nothing from /etc/caddy is in it, because step 5
wrote nothing there.

A backup on the same disk as the data is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/ferretdb
scp vps:/srv/ferretdb/backups/*.tar.gz ~/backups/ferretdb/
```

To restore: `cd /srv/ferretdb`, `docker compose down`, `sudo rm -rf /srv/ferretdb/postgres`,
`sudo tar -xzf /srv/ferretdb/backups/<archive> -C /srv/ferretdb`, then `docker compose up -d`. The
untar puts `.env` back before anything starts, which matters: the archived cluster holds a password
hash already, and a `.env` carrying a different value fails authentication in the log rather than
saying anything about passwords. Restore into the image pair that archive's compose.yml pins.

## 9. Updating later

The two images move together. FerretDB releases are at
https://github.com/FerretDB/FerretDB/releases, each naming the DocumentDB version it works best
with, and the matching tag is at https://github.com/FerretDB/documentdb/releases. Upstream's order
is not optional: PostgreSQL image, then the extension, then FerretDB. Back up, then edit both
image lines in /srv/ferretdb/compose.yml to the new tags and digests:

```bash
cd /srv/ferretdb
docker compose pull postgres
docker compose up -d postgres
docker compose exec -T postgres psql -U ferretdb -d postgres -c 'ALTER EXTENSION documentdb UPDATE;'
docker compose pull ferretdb
docker compose up -d ferretdb
docker compose logs --tail 30 ferretdb
```

Telemetry is off, so nothing announces a release; reading that page replaced it. Expect it quiet:
2.7.0 has been newest since November 2025, and main last moved in February 2026. Re-run step 7's
health check and the anonymous-write assert before calling it done.

## 10. What will probably go wrong

I lost an afternoon to an aggregation pipeline that worked against Atlas and came back here with
an error name I had never seen, and I spent most of it certain the install was broken. It was not.
FerretDB implements the commands upstream says it implements and no more, and my pipeline used a
stage nobody had claimed. The lesson is order of operations: before migrating anything, run the
application's own test suite against this instance, or point a staging copy at it for a day.
Upstream's compatibility page is honest, which means it sometimes says no. Learning that on a
Tuesday costs an afternoon; after a cutover it costs a weekend.

## 11. Out of scope

- Do not add a Caddy site block, a Traefik router, or any reverse proxy. A reverse proxy speaks
  HTTP and this port does not, so the only result is a public database.
- Do not set `FERRETDB_LISTEN_TLS`, publish 27018, or enable `FERRETDB_LISTEN_DATA_API_ADDR` or
  the MCP server. Native TLS needs certificates this prompt does not issue; the other two are HTTP
  surfaces left closed.
- Do not set `FERRETDB_AUTH` to false, and do not run the evaluation image as the service. It
  carries its own PostgreSQL and upstream calls it unsuitable for production.
- Do not raise the log level to `debug`. Upstream states debug logs include full query bodies and
  credentials, and `getLog` hands recent entries to any client.
