This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing FerretDB 2.7.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise. There is no hostname to fill in anywhere in this file, and no
`<DOMAIN>` to replace: this install publishes nothing to the internet.

Read this before step 1, because it is what you are agreeing to. FerretDB speaks the MongoDB
wire protocol and stores documents in PostgreSQL with the DocumentDB extension. Upstream
states that all drivers and applications compatible with MongoDB 5.0+ should be compatible
with FerretDB, and marks CRUD, indexes, `aggregate`, `count` and `distinct` supported. The
published gaps are real: transactions (`commitTransaction`, `abortTransaction`), `bulkWrite`,
every role-management command, `setParameter`, `killOp` and `profile` are not implemented, and
error messages can differ from MongoDB's even where the error names match. Atlas Search, Atlas
Vector Search, Charts and Triggers are separate services MongoDB runs beside the database, and
none of them exist here. FerretDB has its own text indexes and its own pgvector-backed vector
search, which are different features with different syntax. Run your application's test suite
against this before you migrate anything real to it.

Two more things. There is no browser interface and no sign-in screen: this is a database, and
what connects to it is a driver, a shell, or code you write. And this database will answer on
127.0.0.1:8191 only, which means an application on this same box, a container on this compose
project's network, or a port you forward from your own laptop. Nothing else.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
```

You should see: at least `2048` MB available, at least `10` G free, and `amd64` or `arm64`.

If you do not: stop rather than installing and hoping. The disk floor is not padding. The two
service images are about 1 GB together, the MongoDB shell image step 7 uses unpacks to roughly
1.5 GB more, and an empty PostgreSQL cluster is near 50 MB before you put a document in it. On
architecture, both images publish amd64 and arm64, so anything else means this is not a machine
these images run on.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ferretdb /srv/ferretdb/backups
sudo install -d -m 700 /srv/ferretdb/postgres
sudo install -d -m 750 -o 1000 -g 1000 /srv/ferretdb/state
ls -la /srv/ferretdb
```

You should see: `backups` owned by you, `postgres` at mode `drwx------` owned by root, and
`state` owned by uid `1000`.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. The `state` directory is uid 1000 because that is the uid baked into the
FerretDB image's passwd file; if your login user happens to be uid 1000 you will see your own
name there, which is correct. That directory holds the instance UUID and telemetry bookkeeping,
never your documents.

## 3. Secrets

One secret, and it does two jobs. It is the PostgreSQL password FerretDB uses to reach its
storage, and it is also the password every MongoDB client will send, because FerretDB stores no
accounts of its own and forwards what it receives to PostgreSQL for validation. Generate it here,
on the server, and hex rather than base64 because it travels inside a connection string.

```bash
umask 077
cat > /srv/ferretdb/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/ferretdb/.env
umask 022
ls -l /srv/ferretdb/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Read the value once
with `sudo grep POSTGRES_PASSWORD /srv/ferretdb/.env` and put it in your password manager now.

Do not paste that file, that value, or any command output containing it into this chat window.
The other tab never sees it; this one will hand it to a third party unless you keep it out.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines into different shells. Run `chmod 600 /srv/ferretdb/.env` and carry on. If the
file already existed from an earlier attempt, this block has now overwritten the password, which
is fine before the database exists and a problem afterwards: PostgreSQL keeps the password it was
created with, so a changed value on an existing data directory produces an authentication failure
in the FerretDB log rather than anything that mentions passwords.

Understand what that one value is. Upstream states authorization is not yet supported, so every
valid login has full access to everything. There is no read-only account to hand a reporting
script, and a second user made later with `db.createUser` buys you credential separation and
nothing more.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal, so run `rm /srv/ferretdb/compose.yml` and paste again in one go. A warning that
`POSTGRES_PASSWORD` is not set means you are not in /srv/ferretdb: Compose reads that value from
the `.env` file sitting next to compose.yml and nowhere else, so the `cd` on the last line is
load-bearing. Note what the two image tags are doing there. They are a matched pair, not two
independent pins: FerretDB 2.7.0's release notes name DocumentDB 0.107.0-ferretdb-2.7.0 as the
version it works best with, and upstream skipped FerretDB 2.6.0 so the two numbers would line up.

## 5. Caddy and TLS

Nothing goes into Caddy for this service, and that is a decision rather than an omission.
FerretDB answers the MongoDB wire protocol on TCP 27017, which is binary traffic on a long-lived
socket rather than HTTP, so `reverse_proxy` has nothing to carry and there is no hostname for
Caddy to certify. Write the record of that decision next to the compose file, then leave the
Caddy that Prompt Zero installed exactly as it is.

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

You should see: `0`, and no reload, because nothing changed.

If you do not: a number above zero means an earlier attempt appended a site block for this
service to /etc/caddy/Caddyfile. Take it out and reload before you go any further. A site block
pointing at 8191 would put a database on the public internet with no login form anywhere in front
of it, and every scanner on the internet finds an open database faster than you will notice.

## 6. Firewall

This install opens no port at all. Look at the current state and change none of it.

```bash
sudo ufw status verbose
```

You should see: `Status: active`, and no rule mentioning `8191`, `27017` or `5432`.

If you do not: delete anything for 8191 or 27017 with `sudo ufw delete allow 8191`, and say to
yourself what it had been exposing while it was there. 8191 is bound to 127.0.0.1 by the compose
file, so a firewall rule for it would be meaningless anyway, and 5432 is never published at all,
so the database container has no host port a rule could apply to. Whatever 80 and 443 look like
belongs to the other services on this box; nothing in this install answers HTTP, so leave them
alone. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back first.

One more thing worth knowing, because upstream says it out loud. A connection made from inside
the PostgreSQL container over its own loopback address can be trusted with no password even
though one is set. FerretDB reaches PostgreSQL across the container network, where the password
is required. That is why 5432 is never published, and why a shell inside that container counts as
holding the credential.

## 7. Start and verify

```bash
cd /srv/ferretdb
docker compose pull
docker compose up -d
for i in $(seq 1 36); do s=$(docker inspect --format '{{.State.Health.Status}}' ferretdb 2>/dev/null); echo "$i ${s:-none}"; [ "$s" = healthy ] && break; sleep 5; done
docker inspect --format '{{.State.Health.Status}}' ferretdb
```

You should see: the loop counting up through `starting` and ending on `healthy`, then `healthy`
printed on its own. Upstream builds a `HEALTHCHECK` into the image that behaves as a readiness
probe, and it passes only when a MongoDB protocol connection can be made and DocumentDB is
installed correctly, so that one word covers both containers at once.

If you do not: run `docker compose logs --tail 20 postgres` first, because a PostgreSQL that
never reports healthy is step 2 done wrong, then `docker compose logs --tail 40 ferretdb`. A
FerretDB that starts and immediately exits is usually step 3: an empty password makes the
connection string invalid, and the log says so in terms of the URL rather than in terms of the
password. There is no first screen and no URL to open in a browser, and a running container is
not success. The round trip below is.

Now prove the wire protocol works. The shell is `mongosh` out of FerretDB's own evaluation image,
pinned by digest and run once with its entrypoint overridden, so none of the services that image
carries ever start. Upstream's own instruction has MongoDB's `mongo` image in that position; this
uses FerretDB's, which ships the same shell and is version-matched to what you installed.

```bash
MSH=ghcr.io/ferretdb/ferretdb-eval:2.7.0@sha256:1bf47a449dd65839aabfc1a535d1370c98326f8a90de20437eda0aeb30bd8dd5
PGPW=$(sudo grep '^POSTGRES_PASSWORD=' /srv/ferretdb/.env | cut -d= -f2-)
docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet "mongodb://ferretdb:${PGPW}@127.0.0.1:27017/appdb" --eval 'db.selfhost_check.insertOne({ok:1}); printjson(db.selfhost_check.findOne())'
unset PGPW
docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet "mongodb://127.0.0.1:27017/appdb" --eval 'db.selfhost_check.insertOne({anon:1})'; echo "exit=$?"
```

You should see, in order: a long image pull, then a printed document holding `ok: 1` and an
`_id`, then an authentication or authorization error followed by a non-zero `exit=`. That second
failure is the security check in this step, and it is the one worth understanding. Upstream is
precise about its shape: an anonymous client can still open a socket to FerretDB, and what it
cannot do is read or write anything. So "connection refused" is the wrong phrase for the right
outcome, and seeing the error is good news.

If you do not: an anonymous insert that succeeds means authentication is not being enforced, so
stop there and check that step 4's `FERRETDB_POSTGRESQL_URL` still carries the password, because
a FerretDB with no password in its connection string has no authentication at all. If the first
command fails instead, `Authentication failed` points back at step 3 and a mismatch between
`.env` and the cluster on disk, while `no such container` means the FerretDB container is not
running under that name. Drop the test document whenever you like with
`db.selfhost_check.drop()` through the same shell.

Your connection string is `mongodb://ferretdb:<the value in .env>@127.0.0.1:8191/appdb`, and it
is worth being clear about where it works. From an application on this same box, exactly as
written. From a container in a different compose project, only if that container joins this
project's network, and then the host becomes `ferretdb:27017` instead of the loopback address.
From your own laptop, only inside a port you forward yourself, which you run on the laptop rather
than on the server: `ssh -N -L 27017:127.0.0.1:8191 vps`, and then point mongosh or Compass at
`mongodb://ferretdb:<the value in .env>@127.0.0.1:27017/appdb`. Closing that terminal closes the
door. There is no fourth way in, and adding one is what step 11 is about.

## 8. First backup and restore

One archive, taken cold. The containers stop for it, because a PostgreSQL data directory copied
while the server is writing is not a backup, and a file copy of a stopped cluster is correct at
any size.

```bash
cd /srv/ferretdb
docker compose stop
sudo tar -czf /srv/ferretdb/backups/ferretdb-$(date +%F).tar.gz -C /srv/ferretdb postgres state .env compose.yml Caddyfile
docker compose start
ls -lh /srv/ferretdb/backups/
```

You should see: one file, tens of megabytes on a fresh cluster. The stop and start cost about ten
seconds.

If you do not: a file of a few hundred bytes means tar found nothing, which usually means you ran
it from somewhere other than /srv/ferretdb. Treat that archive as secret material once it exists:
`.env` is inside it, and so is every document you will ever write. Nothing from /etc/caddy is in
it, deliberately, because step 5 wrote nothing there. And note the trade this makes: because it
copies the whole data directory, the archive grows with the database rather than staying small.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/ferretdb
scp vps:/srv/ferretdb/backups/*.tar.gz ~/backups/ferretdb/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/ferretdb/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a test document:

```bash
cd /srv/ferretdb
docker compose down
sudo rm -rf /srv/ferretdb/postgres
sudo tar -xzf /srv/ferretdb/backups/ferretdb-$(date +%F).tar.gz -C /srv/ferretdb
docker compose up -d
sleep 40
docker inspect --format '{{.State.Health.Status}}' ferretdb
```

You should see: `healthy` again, and the document from step 7 still there if you re-run the first
`mongosh` command.

If you do not: the ordering matters more than it looks. The untar puts `.env` back before any
container starts, and it has to, because the cluster inside the archive already holds a password
hash and a `.env` carrying a different value produces an authentication failure in the FerretDB
log rather than any message about passwords. Restore into the image pair the archive's own
compose.yml pins, never a newer one: this is a raw copy of a PostgreSQL data directory, and
PostgreSQL will refuse a data directory written by a different major version.

## 9. Updating later

The two images move together, and the order is upstream's rather than a preference. FerretDB
releases are at https://github.com/FerretDB/FerretDB/releases and each release names the
DocumentDB version it works best with; the matching DocumentDB tag is at
https://github.com/FerretDB/documentdb/releases. Update the PostgreSQL image first, then the
extension inside the database, then FerretDB. Take the step 8 backup first, then edit both image
lines in /srv/ferretdb/compose.yml to the new tags and their digests.

```bash
cd /srv/ferretdb
docker compose pull postgres
docker compose up -d postgres
docker compose exec -T postgres psql -U ferretdb -d postgres -c 'ALTER EXTENSION documentdb UPDATE;'
docker compose pull ferretdb
docker compose up -d ferretdb
docker compose logs --tail 30 ferretdb
```

You should see: `ALTER EXTENSION` from psql, then FerretDB starting cleanly with no restart loop.

If you do not: put the old tags and digests back and run the same commands. Telemetry is turned
off in the compose file, so nothing on this box will ever tell you a new version exists; reading
that releases page yourself is the job that replaced it. Expect it to be quiet: 2.7.0 has been the
newest release since November 2025 and the main branch last moved in February 2026, so silence
there is the current normal rather than an update you missed. Re-run step 7's health check and the
anonymous-insert check before you call an update done.

## 10. What will probably go wrong

I lost an afternoon to an aggregation pipeline that worked against Atlas and came back here with
an error name I had never seen, and I spent most of that afternoon certain the install was
broken. It was not. FerretDB implements the commands upstream says it implements and no more, and
my pipeline used a stage nobody had ever claimed. The lesson is the order of operations: before
you migrate anything, run your application's own test suite against this instance, or point a
staging copy at it for a day. Upstream's compatibility page is honest, which means it will
sometimes tell you the answer is no. Learning that on a Tuesday costs an afternoon. Learning it
after a cutover costs a weekend.

## 11. Out of scope

- Do not add a Caddy site block, a Traefik router, or any reverse proxy for this service. A
  reverse proxy speaks HTTP and this port does not, so the only result is a published database.
- Do not set `FERRETDB_LISTEN_TLS`, publish 27018, or enable `FERRETDB_LISTEN_DATA_API_ADDR` or
  the MCP server. Native TLS is the right way to reach this from another machine and it needs
  certificates this install does not issue; the other two are HTTP surfaces left closed.
- Do not set `FERRETDB_AUTH` to false, and do not run the evaluation image as the service. It
  carries its own PostgreSQL and upstream states it is unsuitable for production.
- Do not raise the log level to `debug`. Upstream states debug logs include full query bodies and
  authentication credentials, and `getLog` hands recent entries to any connected client.
