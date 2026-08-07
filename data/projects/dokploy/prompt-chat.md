This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Dokploy v0.29.14 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. Dokploy drives this server's Docker daemon through a mounted socket
and puts the machine into Swarm mode to do it. Prompt Zero called docker-group membership
root-equivalent; this hands the same reach to a web dashboard, so whoever holds the panel
password holds the server. That is the trade, and it is the product.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail / | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `30` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve. The 30 GB is not padding. Application builds happen on this box, and a build that runs
out of disk fails in a way that looks like a broken panel rather than a full disk.

## 2. Layout and Swarm mode

Two trees. /srv/dokploy is yours: compose file, secrets, database directory, archives.
/etc/dokploy belongs to the panel, and that path cannot move, because the panel writes it inside
the container and then hands the same string to the Docker daemon out here.

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

You should see: `swarm=active`, then `network=dokploy-network overlay attachable=true`, then
`backups` owned by you and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose, because the PostgreSQL image chowns
its own data directory on first start and one you have already chowned makes it refuse to
initialise. `Error response from daemon: This node is already part of a swarm` means the first
line found an active swarm and skipped the init, which is the intended path on a re-run. The
advertise address is 127.0.0.1 because this is a single node that nothing will ever join, and
the cluster port has no business on a public interface.

## 3. Secrets

Two secrets, both generated here on the server: the PostgreSQL password and the key the panel
signs every session with. Hex, because one travels inside a connection string.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/dokploy/.env` and carry
on. If the file already existed from an earlier attempt, this block has overwritten both values,
which is fine before the database exists and a problem afterwards: PostgreSQL keeps the password
it was created with, so a changed `DB_PASSWORD` against an existing directory produces an
authentication failure in the panel's log rather than anything that mentions passwords.

Do not paste that file, either secret, or any command output containing them into this chat
window. Upstream falls back to a published hard-coded signing key when `AUTH_SECRET` is unset,
warning instead of refusing to start, so this file is what makes your session cookie unforgeable,
and a chat window is a third party.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/dokploy/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal;
run `rm /srv/dokploy/compose.yml` and paste again in one go. Note what is not in this file:
upstream's installer starts a third container, its own Traefik, on ports 80 and 443. Caddy holds
those on a Prompt Zero box, so no proxy is started here, and step 10 says what that costs you.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-dokploy /etc/caddy/Caddyfile`, reload,
and paste again. The panel's deployment logs and its web terminal are WebSockets on the same
8144, and `reverse_proxy` upgrades them with no extra configuration, so there is no second route
to add here.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8144`, `5432`, `2377`, `7946` or `4789`.

If you do not: delete anything for those five with `sudo ufw delete allow 8144` and the same for
the rest. 8144 is bound to 127.0.0.1 by the compose file, 5432 is never published at all, and
2377, 7946 and 4789 are Swarm's cluster ports, which matter only when a second machine joins
this swarm. Nothing will. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back before
you go further.

## 7. Start and verify

The panel waits for PostgreSQL, runs its own migrations, then serves. A cold first start takes
a couple of minutes, so the loop below is patient on purpose.

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

You should see, in order: the loop reaching `200`, then `{"ok":true}`, then
`https://<DOMAIN>/register`, then a number of at least `1`, then two containers `Up`.

If you do not: a loop that never reaches `200` wants
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy is
step 3 with an empty `DB_PASSWORD`, and `docker compose logs --tail 40 dokploy` second. A `502`
from Caddy is step 5. `network dokploy-network declared as external, but could not be found` is
step 2, and re-running that block fixes it. A running container is not success: the grep is the
assert that matters, because it proves the page an unconfigured instance serves reached you
through Caddy.

The first screen at https://<DOMAIN> is the heading `Setup the server` above the line
`Enter your email and password to setup the server`. Open it in a browser and create your
account now. It is the only moment that account can be made, no mail server here can reset it,
so put the password in your password manager before you submit the form.

```bash
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/register
docker ps -a --filter name=dokploy-traefik --format '{{.Names}} {{.Status}}'
```

You should see: `https://<DOMAIN>/` from the first command, and nothing at all from the second.

If you do not: a `/register` that still serves itself means the account was not created, so go
back and create it. A `dokploy-traefik` line means a proxy container exists that wants ports 80
and 443, which Caddy is holding; `docker rm -f dokploy-traefik` removes it, and step 11 says what
not to press to get it back.

Last, open Settings, then Web Server, and set the panel's domain to your hostname with HTTPS
enabled, so the panel knows its own public address. That writes a routing file and starts
nothing.

## 8. First backup and restore

Two artifacts. The database holds every project, application, server and credential. The archive
holds what rebuilds the service around it, /etc/dokploy included, because the panel's keys and
routing files are there.

```bash
cd /srv/dokploy
docker compose exec -T postgres pg_dump -U dokploy -d dokploy | gzip > /srv/dokploy/backups/dokploy-db-$(date +%F).sql.gz
sudo tar -czf /srv/dokploy/backups/dokploy-config-$(date +%F).tar.gz -C /srv/dokploy compose.yml .env -C /etc dokploy -C /etc/caddy Caddyfile
ls -lh /srv/dokploy/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/dokploy
scp vps:/srv/dokploy/backups/* ~/backups/dokploy/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/dokploy/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one account:

```bash
cd /srv/dokploy
docker compose down
sudo rm -rf /srv/dokploy/postgres
sudo install -d -m 700 /srv/dokploy/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/dokploy/backups/dokploy-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U dokploy -d dokploy
docker compose up -d
sleep 30
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/register
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `https://<DOMAIN>/`, which means
your account survived a database that was deleted and rebuilt.

If you do not: `role "dokploy" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. If the last line prints
`https://<DOMAIN>/register` instead, the restore did not land and your account is gone; take the
dump apart before you trust this install with anything. Understand the stakes: those rows hold
the credentials for every repository and registry you connect, and the containers this panel
deployed keep running while the panel is gone, which makes a lost database feel survivable right
up to the first time you need to change something.

## 9. Updating later

Versions are listed at https://github.com/Dokploy/dokploy/releases. Take both backup artifacts
first, then edit the `image:` line in /srv/dokploy/compose.yml to the new tag and its digest.

```bash
cd /srv/dokploy
docker compose pull
docker compose up -d
docker compose logs --tail 40 dokploy
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
step 7's health check before you call the update done. Do not use the update button inside the
panel: it drives a Swarm service named `dokploy`, and this install runs a compose container, so
the pinned image line is the only thing that moves a version here.

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
  Swarm services and starts that Traefik; this guide has done the parts worth keeping.
- Do not configure SMTP or any notification transport, and do not connect a GitHub App or a
  container registry. Each is a credential of its own and none is needed to deploy the first
  application.
- Do not add a second server to the panel. That means a key and a passwordless sudo line on
  another machine, a decision you make deliberately or not at all.
