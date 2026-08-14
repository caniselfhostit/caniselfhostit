You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install FerretDB 2.7.0 with the PostgreSQL it stores documents in, under ~/selfhost/ferretdb,
answering the MongoDB wire protocol on 127.0.0.1:8191.

## 1. Preflight

Say two things to the user before step 2 runs. They decide whether this is the install they
wanted.

Where it lives. This database answers on 127.0.0.1:8191 and nowhere else, so the application
built on it runs here too and the phone they wanted to test from cannot reach it.

Compatibility. Upstream states that drivers and applications compatible with MongoDB 5.0+ should
be compatible with FerretDB, and marks CRUD, indexes, `aggregate`, `count` and `distinct`
supported. Not implemented: transactions, `bulkWrite`, role management, `setParameter`, `killOp`,
`profile`. Atlas Search, Atlas Vector Search, Charts and Triggers do not exist here.

Detect the OS and measure:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. This install needs 2048 MB of RAM available
and 10 GB free on the home disk, and both images publish amd64 and arm64. On macOS and Windows
that memory figure is the host's, and Docker Desktop takes its share out of it. Under either
floor, print both numbers and stop.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they
  confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/ferretdb/backups
ls -la ~/selfhost/ferretdb
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder on purpose: step 5
keeps the cluster and FerretDB's state in volumes Docker manages, because the PostgreSQL image
chowns its data directory to its own uid at first start and a home-directory bind mount cannot
allow that on Windows.

## 4. Secrets

One secret doing two jobs: the PostgreSQL password FerretDB uses to reach its storage, and the
password every MongoDB client sends, because FerretDB stores no accounts and forwards what it
receives to PostgreSQL. Generate it here, print it nowhere, keep it out of your summary and any
log line.

```bash
umask 077
cat > ~/selfhost/ferretdb/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/ferretdb/.env
umask 022
ls -l ~/selfhost/ferretdb/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so this runs the same on all three; on
Windows the mode bits are advisory and the real boundary is the user's own account. That value is
the whole security boundary, because upstream states authorization is not yet supported.

## 5. compose.yml

```bash
cat > ~/selfhost/ferretdb/compose.yml <<'EOF'
# FerretDB · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.ferretdb.io/installation/ferretdb/docker/
#   documentdb image ... https://docs.ferretdb.io/installation/documentdb/docker/
#   authentication ..... https://docs.ferretdb.io/security/authentication/
#
# FerretDB turns the MongoDB wire protocol into SQL; PostgreSQL beside it holds
# the DocumentDB extension. Both stores are named volumes rather than folders,
# because the PostgreSQL image chowns its data directory to its own uid at first
# start and a home-directory bind mount cannot allow that on Windows. The two
# tags are a matched pair: the 2.7.0 release notes name 0.107.0-ferretdb-2.7.0
# as its match. Move them together.
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
      - pgdata:/var/lib/postgresql/data
      # Step 8 tars the cluster from a throwaway container borrowing these
      # mounts, so the archive lands here on your own disk.
      - ./backups:/backup
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
      - state:/state
    ports:
      # Loopback only: no other device on the wifi can reach 8191, and nor
      # can the phone you wanted to test an app from.
      - "127.0.0.1:8191:27017"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  pgdata:
  state:
EOF
cd ~/selfhost/ferretdb && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose reads `${POSTGRES_PASSWORD}` from the `.env` step 4
wrote here, which is why it runs after a `cd`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, each a decision: no hostname to
resolve, nothing to certify, and the wire protocol is not HTTP so no proxy could carry it. 8191 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/ferretdb/compose.yml
```

Assert: that prints `1`. PostgreSQL publishes no host port, so 5432 cannot appear, and the debug
handler on 8088 stays inside the compose network.

## 7. Start and verify

```bash
cd ~/selfhost/ferretdb
docker compose pull
docker compose up -d
for i in $(seq 1 36); do s=$(docker inspect --format '{{.State.Health.Status}}' ferretdb 2>/dev/null); echo "$i ${s:-none}"; [ "$s" = healthy ] && break; sleep 5; done
docker inspect --format '{{.State.Health.Status}}' ferretdb
```

Assert: that prints `healthy`. Upstream builds a `HEALTHCHECK` into the image that behaves as a
readiness probe, passing only when a MongoDB protocol connection can be made and DocumentDB is
installed correctly, so one word covers both containers. If the loop never leaves `starting`,
stop, run `docker compose logs --tail 40 ferretdb`, and name the cause: a FerretDB that exits
after starting is usually step 4, where an empty password invalidates the connection string. If
`port is already allocated` came back, find what holds 8191 (`lsof -nP -iTCP:8191 -sTCP:LISTEN`)
and stop until it is free. A running container is not success.

STOP: tell the user to read the password with `grep POSTGRES_PASSWORD ~/selfhost/ferretdb/.env`
and put it in their password manager.
Do not continue until they confirm they have stored it.
Losing it loses the database: there is no reset link and no admin screen, and the only way back
is an `ALTER USER` in the PostgreSQL container.

Once they confirm, prove the wire protocol. The shell is `mongosh` out of FerretDB's own
evaluation image, pinned by digest and run with its entrypoint overridden so nothing else it
carries starts. That pull is near 600 MB:

```bash
MSH=ghcr.io/ferretdb/ferretdb-eval:2.7.0@sha256:1bf47a449dd65839aabfc1a535d1370c98326f8a90de20437eda0aeb30bd8dd5
PGPW=$(grep '^POSTGRES_PASSWORD=' ~/selfhost/ferretdb/.env | cut -d= -f2-)
docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet "mongodb://ferretdb:${PGPW}@127.0.0.1:27017/appdb" --eval 'db.selfhost_check.insertOne({ok:1}); printjson(db.selfhost_check.findOne())'
unset PGPW
docker run --rm --network container:ferretdb --entrypoint mongosh "$MSH" --quiet "mongodb://127.0.0.1:27017/appdb" --eval 'db.selfhost_check.insertOne({anon:1})'; echo "exit=$?"
```

Assert both and print what came back. The first prints a document holding `ok: 1` and an `_id`: a
write and a read through the wire protocol, into PostgreSQL and out again. The second must fail,
with an authentication or authorization error and a non-zero `exit=`, and that is the security
assert here. Upstream is precise here: an anonymous client can still open a socket, and
what it cannot do is read or write. If it inserts a document, check that step 5 kept
`FERRETDB_POSTGRESQL_URL` intact.

STOP: hand the user their connection string,
`mongodb://ferretdb:<the value in .env>@127.0.0.1:8191/appdb`. It works from an application on
this computer, and from another container only if it joins this compose project's network, where
the host becomes `ferretdb:27017`.
Do not continue until they confirm which of those two their application will use.

## 8. First backup and restore

Two archives, taken with the containers stopped, because a tar of a live PostgreSQL is not a
backup. The cluster tar runs in a throwaway container borrowing the stopped mounts,
so PostgreSQL's own uid survives:

```bash
cd ~/selfhost/ferretdb
docker compose stop
docker run --rm --volumes-from ferretdb-postgres --entrypoint sh ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0@sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7 -c "tar -czf /backup/ferretdb-cluster-$(date +%F).tar.gz -C /var/lib/postgresql/data ."
tar -C ~/selfhost/ferretdb -czf ~/selfhost/ferretdb/backups/ferretdb-config-$(date +%F).tar.gz .env compose.yml
docker compose start
ls -lh ~/selfhost/ferretdb/backups/
```

Assert: both archives exist and are non-empty. Print both sizes; the cluster archive is tens of
megabytes on a fresh install and grows with the database. Stop and start cost about ten seconds.
The state volume is not archived: it holds the instance UUID only.

Both files sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB stick,
and copy both there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not `D:\Backups`.
Assert: the user confirms both are there. If they have nowhere, say so plainly.

To restore, in this order. `cd ~/selfhost/ferretdb`, untar the config archive there first so
`.env` is back before any container starts, because PostgreSQL takes that password the moment it
initialises. Then `docker compose down -v`, the one place `-v` belongs because it drops the old
cluster on purpose, then `docker compose create` to make empty volumes. Then the `docker run`
line above with `tar -xzf` and the archive's filename in place of `tar -czf` and the date. Then
`docker compose up -d` and re-run step 7. The cluster archive restores into this image version
only.

## 9. Updating later

The two images move together. FerretDB releases are at
https://github.com/FerretDB/FerretDB/releases, each naming the DocumentDB it works best with, and
the matching tag is at https://github.com/FerretDB/documentdb/releases. Upstream's order is not
optional: PostgreSQL image, then the extension, then FerretDB. Back up, then edit both image
lines in compose.yml to the new tags and digests.

```bash
cd ~/selfhost/ferretdb
docker compose pull postgres
docker compose up -d postgres
docker compose exec -T postgres psql -U ferretdb -d postgres -c 'ALTER EXTENSION documentdb UPDATE;'
docker compose pull ferretdb
docker compose up -d ferretdb
docker compose logs --tail 30 ferretdb
```

Telemetry is off in step 5, so nothing announces a release. Expect that page quiet too:
2.7.0 has been newest since November 2025 and main last moved in February 2026.
Re-run step 7 before calling it done.

## 10. What will probably go wrong

I rebooted, ran my application, and got a connection refused that read like a corrupted database.
It was not: Docker Desktop had not started with the session, so nothing was listening on 8191.
`restart: unless-stopped` acts only once the Docker daemon is up. Turn on Docker Desktop's
start-at-login setting, and after a reboot run `cd ~/selfhost/ferretdb && docker compose up -d`
before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8191 to 0.0.0.0 so a phone on the wifi can reach it. That puts a database on
  every network this machine joins, with one password between it and everyone.
- Do not enable `FERRETDB_LISTEN_DATA_API_ADDR` or the MCP server, and do not run the evaluation
  image as a service: it carries its own PostgreSQL and upstream calls it unsuitable there.
- Do not raise the log level to `debug`: those logs carry query bodies and credentials.
