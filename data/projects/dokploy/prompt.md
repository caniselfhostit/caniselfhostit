You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Dokploy v0.29.14 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here.

Say this before anything installs. Dokploy drives this host's Docker daemon through a mounted
socket and puts the machine into Swarm mode to do it. Prompt Zero called docker-group membership
root-equivalent; this hands that reach to a web dashboard, so whoever holds the panel password
holds the server.

Upstream asks for 2048 MB of RAM available and 30 GB free, a floor rather than a budget, because
builds run here too. Both architectures are published.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail / | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk under 30 GB, print both and stop. If
`dig +short` prints nothing, print that and stop too. Do not install and hope.

## 2. Layout and Swarm mode

Two trees. /srv/dokploy is ours: compose file, secrets, database directory, archives.
/etc/dokploy is the panel's, and not ours to move: it writes that path inside the container, then
hands the same string to the Docker daemon out here.

```bash
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" /srv/dokploy /srv/dokploy/backups
sudo install -d -m 700 /srv/dokploy/postgres
sudo install -d -m 750 /etc/dokploy
docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active || docker swarm init --advertise-addr 127.0.0.1
docker network inspect dokploy-network >/dev/null 2>&1 || docker network create --driver overlay --attachable dokploy-network
docker info --format 'swarm={{.Swarm.LocalNodeState}}'
docker network inspect dokploy-network --format 'network={{.Name}} {{.Driver}} attachable={{.Attachable}}'
ls -la /srv/dokploy
```

Assert three: `swarm=active`, a line reading
`network=dokploy-network overlay attachable=true`, and `ls -la` showing `backups` owned by the
login user with `postgres` at mode `700` owned by root. The PostgreSQL image chowns its own data
directory on first start, so leave that alone. /etc/dokploy stays root-owned at 750 rather than
the 777 upstream's installer sets, because the container runs as root and needs no more. The
swarm advertises on 127.0.0.1 on purpose: one node, nothing will join it, and the cluster port
has no business on a public interface.

## 3. Secrets

Two secrets, both generated here: the PostgreSQL password and the key the panel signs every
session with. Print neither, and keep both out of your summary and out of any log line. Hex,
because one travels inside a connection string.

```bash
umask 077
cat > /srv/dokploy/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
AUTH_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/dokploy/.env
umask 022
ls -l /srv/dokploy/.env
```

Assert: the file exists with mode `-rw-------`. Upstream falls back to a published hard-coded
signing key when that value is unset, and warns rather than refusing to start, so this file
stands between a stranger and a forged session cookie. Tell the user it is readable with
`sudo grep AUTH_SECRET /srv/dokploy/.env` and that nothing here printed it.

## 4. compose.yml

```bash
cat > /srv/dokploy/compose.yml <<'EOF'
# Dokploy · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installation ....... https://docs.dokploy.com/docs/core/installation
#   manual install ..... https://docs.dokploy.com/docs/core/manual-installation
#   architecture ....... https://docs.dokploy.com/docs/core/architecture
#   applications ....... https://docs.dokploy.com/docs/core/applications
#
# Two services: the panel, and the PostgreSQL holding every project, server and
# stored credential. Upstream's installer starts a third container, its own
# Traefik, on 80 and 443; this file starts no proxy, because Caddy holds those
# on a Prompt Zero box. The panel answers on 127.0.0.1:8144, and applications
# deployed from it get a host port and a Caddy site block.
#
# /etc/dokploy is bound host path to identical container path on purpose: the
# panel hands those strings to the Docker daemon out here. The socket is
# read-write because driving this host's Docker is the product, and that is
# root on this machine. dokploy-network is the attachable overlay network the
# install step created; Swarm mode is not optional, because everything the
# panel deploys is a Swarm service. Digests read 2026-08-06; both images
# publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  dokploy:
    image: dokploy/dokploy:v0.29.14@sha256:57771f6edc7921f741c004002b9be9b39cfa5cb84ecd4ba325f735219a8cae6b
    container_name: dokploy
    restart: unless-stopped
    environment:
      # Upstream reads DATABASE_URL ahead of its Docker-secret path.
      DATABASE_URL: postgres://dokploy:${DB_PASSWORD}@postgres:5432/dokploy
      BETTER_AUTH_SECRET: ${AUTH_SECRET}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/dokploy:/etc/dokploy
      - dokploy-docker:/root/.docker
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8144.
      - "127.0.0.1:8144:3000"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/api/health || exit 1"]
      interval: 10s
      retries: 30
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: dokploy-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: dokploy
      POSTGRES_USER: dokploy
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/dokploy/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dokploy -d dokploy"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

networks:
  default:
    name: dokploy-network
    external: true

volumes:
  dokploy-docker:
    name: dokploy-docker
EOF
cd /srv/dokploy && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose reads /srv/dokploy/.env for the two `${...}` values
because it sits in the project directory. Both are plain containers on a Swarm overlay network,
which is what `--attachable` in step 2 is for.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy first: a syntax error
here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-dokploy
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Dokploy · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.dokploy.com/docs/core/installation and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Caddy keeps 80 and
# 443 here; upstream's installer would have given them to its own Traefik, and
# this install runs none, so every application deployed from the panel gets a
# host port and a site block of its own, written like this one.

<DOMAIN> {
	# The panel carries a session cookie and an embedded shell, so it is never
	# framed and leaks no path in a referrer. HSTS because whoever reaches this
	# dashboard reaches the Docker daemon standing behind it.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8144 is the loopback port compose publishes on this host. It is not a
	# container port and not open in the firewall. Deployment logs and the web
	# terminal are WebSockets on it too, which reverse_proxy upgrades already.
	reverse_proxy 127.0.0.1:8144
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. On failure restore /etc/caddy/Caddyfile.before-dokploy, reload, and report
what it objected to. Caddy asks for the certificate on the first request and renews it itself.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the way in, 443/udp is HTTP/3. 8144
stays closed because compose binds it to 127.0.0.1, 5432 because compose never publishes it, and
2377, 7946 and 4789 because they are for cluster members and this cluster has one. Assert:
`Status: active`, rules for 80, 443/tcp and 443/udp, none naming 8144, 5432, 2377, 7946 or
4789.

## 7. Start and verify

The panel waits for PostgreSQL, runs its own migrations, then serves. A cold first start takes
a couple of minutes.

```bash
cd /srv/dokploy
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/health; echo
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/register | grep -c 'Setup the server'
docker compose ps
```

Assert all five, printing what you received for each. The loop ends on `200`. `/api/health`
answers `{"ok":true}`. The root lands on `https://<DOMAIN>/register`, where an instance with no
account sends everyone. The grep prints at least `1`: that screen carries the heading
`Setup the server` above `Enter your email and password to setup the server`. `ps` shows two
containers up. On any miss, stop, run `docker compose logs --tail 40 dokploy` and
`docker compose logs --tail 20 postgres`, and name the cause: a database that never reports
healthy is step 3 with an empty `DB_PASSWORD`, a `502` is step 5, and
`network dokploy-network declared as external, but could not be found` is step 2. A running
container is not success.

STOP: tell the user to open https://<DOMAIN> and create their account there. It is the only
moment it can be made and no mail server here can reset it, so have them save the password in a
manager first. Do not continue until they confirm.

```bash
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/register
docker ps -a --filter name=dokploy-traefik --format '{{.Names}} {{.Status}}'
```

Assert both. The first prints `https://<DOMAIN>/`: registration closes once an account exists.
The second prints nothing, because no Traefik was started, and one appearing later is a container
asking for the 80 and 443 Caddy holds.

STOP: tell the user to open Settings, then Web Server, and set the panel's domain to `<DOMAIN>`
with HTTPS on, so it knows its own public address. Do not continue until they confirm. That
setting writes a routing file and starts nothing.

## 8. First backup and restore

Two artifacts. The database holds every project, application, server and credential. The
archive holds what rebuilds the service around it, /etc/dokploy included, because the panel's
keys and routing files are there.

```bash
cd /srv/dokploy
docker compose exec -T postgres pg_dump -U dokploy -d dokploy | gzip > /srv/dokploy/backups/dokploy-db-$(date +%F).sql.gz
sudo tar -czf /srv/dokploy/backups/dokploy-config-$(date +%F).tar.gz -C /srv/dokploy compose.yml .env -C /etc dokploy -C /etc/caddy Caddyfile
ls -lh /srv/dokploy/backups/
```

Assert: both exist and are non-empty, and print both sizes. Nothing stops: `pg_dump` snapshots a
running database consistently. A backup on the same disk is not a backup, so run this from the
user's machine:

```bash
mkdir -p ~/backups/dokploy
scp vps:/srv/dokploy/backups/* ~/backups/dokploy/
```

To restore: `docker compose down`, then untar the config archive twice, once with
`-C /srv/dokploy compose.yml .env` and once with `-C /etc dokploy`, so the secrets land
first. Then `sudo rm -rf /srv/dokploy/postgres`, recreate it as in step 2,
`docker compose up -d postgres`,
wait for healthy, pipe `gunzip -c` on the dump into
`docker compose exec -T postgres psql -U dokploy -d dokploy`, then `docker compose up -d`. The
stakes, plainly: those rows hold the credentials for every repository and registry the user
connects, and the containers this panel deployed keep running while the panel is gone, which
makes a lost database feel survivable until they first need to change something.

## 9. Updating later

Versions are listed at https://github.com/Dokploy/dokploy/releases. Take both backups
first, then edit the image line in /srv/dokploy/compose.yml to the new tag and digest:

```bash
cd /srv/dokploy
docker compose pull
docker compose up -d
docker compose logs --tail 40 dokploy
```

It migrates its own database on the way up, so watch that log settle, then re-run step 7's
health check before calling the update done. Do not use the update button inside the panel: it
drives a Swarm service named `dokploy`, and this runs a compose container, so the pinned image
line above is the only thing that moves a version here.

## 10. What will probably go wrong

You will deploy something, open its Domains tab, type a hostname, and wait for a certificate
that is never coming. I did, for about fifteen minutes. Nothing is broken: that tab writes
routing rules for the Traefik this install deliberately does not run, because Caddy holds 80 and
443 here. The working shape is the other tab, Ports: give the application a published port, then
add a Caddy site block for its hostname pointing at 127.0.0.1 and that port, as in step 5. A
server where the Domains tab works is a server with no Caddy on it.

## 11. Out of scope

- Do not start a Traefik container, and do not use a panel action that offers to, including the
  Traefik and Web Server controls in Settings beyond step 7's domain. Both ports it wants are
  Caddy's.
- Do not run upstream's one-line installer on this box. It makes its own Swarm secrets, creates
  Swarm services and starts that Traefik; this prompt has done the parts worth keeping.
- Do not configure SMTP or any notification transport, and do not connect a GitHub App or a
  container registry. Each is a credential of its own and none is needed to deploy the first
  application.
- Do not add a second server to the panel. That means a key and a passwordless sudo line on
  another machine, a decision the user makes deliberately or not at all.
