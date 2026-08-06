This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Coolify 4.1.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Read this before step 1. Coolify is not an application that sits in its own directory. It holds a
private key that logs into this host and drives its Docker daemon, so from first start it can
build, run and delete containers on the server you rent. That is the product. It is also the
reason this install puts that key behind your own login user rather than a root login.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail / | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `30` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that does
not resolve and failed attempts count against a rate limit you cannot see. Under 30 GB free is
the one to take seriously here rather than shrug at: this box will be building other people's
applications, and Docker's image layers are where the space goes.

## 2. Layout and host access

The application writes deployment files to /data/coolify by name on the machine it manages, so
that path is not yours to move. Your backup archives go outside it, in /srv/coolify/backups.

```bash
sudo install -d -m 750 -o "$(id -u)" -g 9999 /data/coolify /data/coolify/source
sudo install -d -m 700 -o 9999 -g 9999 /data/coolify/{ssh,ssh/keys,ssh/mux,applications,databases,services,backups,proxy,proxy/dynamic}
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" /srv/coolify /srv/coolify/backups
KEY=/data/coolify/ssh/keys/id.$(id -un)@host.docker.internal
sudo ssh-keygen -t ed25519 -a 100 -N "" -C coolify -q -f "$KEY"
sudo cat "$KEY.pub" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sudo rm -f "$KEY.pub"
sudo chown 9999:9999 "$KEY" && sudo chmod 600 "$KEY"
printf '%s ALL=(ALL) %s ALL\n' "$(id -un)" 'NOPASSWD:' | sudo tee /etc/sudoers.d/coolify >/dev/null
sudo chmod 440 /etc/sudoers.d/coolify
sudo visudo -c -f /etc/sudoers.d/coolify
docker network create --attachable coolify || true
ls -la /data/coolify
```

You should see: `/etc/sudoers.d/coolify: parsed OK`, a network id from `docker network create`,
and a listing where `source` belongs to you and everything else is mode `drwx------` owned by
`9999`, the uid the container runs as.

If you do not: `parsed OK` missing means stop and fix that file before you log out, because a
broken sudoers file can lock you out of sudo entirely; `sudo rm /etc/sudoers.d/coolify` from the
session you still have open is the way back. The key file name is not cosmetic: the application
reads the user name out of it and logs in as that account, so renaming the file changes who it
tries to be. `network with name coolify already exists` is fine, that is what the `|| true` is
for. And understand what the sudoers line does before you paste it: it makes that key root on
this machine. Upstream's own installer achieves the same thing by enabling a root login instead.

## 3. Secrets

Seven values, all generated on the server: the instance id, the application key, the database
password, the Redis password and three realtime credentials.

```bash
umask 077
cat > /data/coolify/source/.env <<EOF
APP_ID=$(openssl rand -hex 16)
APP_NAME=Coolify
AUTOUPDATE=false
APP_KEY=base64:$(openssl rand -base64 32)
DB_USERNAME=coolify
DB_DATABASE=coolify
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
PUSHER_APP_ID=$(openssl rand -hex 32)
PUSHER_APP_KEY=$(openssl rand -hex 32)
PUSHER_APP_SECRET=$(openssl rand -hex 32)
EOF
umask 022
sudo chown "$(id -u)":9999 /data/coolify/source/.env
chmod 640 /data/coolify/source/.env
ls -l /data/coolify/source/.env
```

You should see: mode `-rw-r-----`, your own username, and group `9999`.

If you do not: `-rw-r--r--` means `umask 077` did not take, which happens if you pasted the lines
into different shells; run `chmod 640` again. 640 rather than 600 is deliberate, because the
container reads this file as uid 9999 and nothing else on the box is in that group. If the file
already existed from an earlier attempt, this block has now replaced every secret in it, which is
harmless before the database exists and a problem afterwards: PostgreSQL keeps the password it
was created with, so a changed `DB_PASSWORD` on an existing volume shows up as an authentication
failure in the application log rather than as anything about passwords.

Do not paste that file, any value from it, or any command output containing one into this chat
window. `APP_KEY` is the one that matters most: it encrypts the private keys and registry
credentials the dashboard will store, and a database backup restored without it is unreadable.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /data/coolify/source/compose.yml <<'EOF'
# Coolify · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   manual install ..... https://coolify.io/docs/get-started/installation
#   ports and firewall . https://coolify.io/docs/knowledge-base/server/firewall
#   host connection .... https://coolify.io/docs/knowledge-base/server/openssh
#   proxy choices ...... https://coolify.io/docs/knowledge-base/server/proxies
#
# Four services: the application, its PostgreSQL, its Redis, and the realtime
# server behind the dashboard's live logs and web terminal. Container names, the
# network name and the /data/coolify paths are strings the application looks up
# by hand. Three loopback ports: 8115 dashboard, 6001 realtime, 6002 terminal;
# this server's proxy is Custom (None), so none competes with Caddy for 80 and
# 443. Digests read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  coolify:
    image: ghcr.io/coollabsio/coolify:4.1.2@sha256:3a27ba5f7f98ff7763a0a4d6715ec36e564f9622eea8f492c46f90716ea2525f
    container_name: coolify
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    env_file: /data/coolify/source/.env
    volumes:
      - /data/coolify/source/.env:/var/www/html/.env:ro
      - /data/coolify/ssh:/var/www/html/storage/app/ssh
      - /data/coolify/applications:/var/www/html/storage/app/applications
      - /data/coolify/databases:/var/www/html/storage/app/databases
      - /data/coolify/services:/var/www/html/storage/app/services
      - /data/coolify/backups:/var/www/html/storage/app/backups
    ports:
      # Loopback only, like 6001 and 6002 below. 5432 and 6379 stay inside.
      - "127.0.0.1:8115:8080"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8080/api/health || exit 1"]
      interval: 10s
      retries: 30
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      soketi:
        condition: service_started

  postgres:
    image: postgres:15.18-alpine@sha256:3d0f7584ed7d04e27fa050d6683a74746608faf21f202be78460d679cc56461f
    container_name: coolify-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: coolify
    volumes:
      - coolify-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coolify -d coolify"]
      interval: 10s
      retries: 30

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: coolify-redis
    restart: unless-stopped
    command: ["redis-server", "--save", "20", "1", "--requirepass", "${REDIS_PASSWORD}"]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    volumes:
      - coolify-redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping | grep -q PONG"]
      interval: 10s
      retries: 30

  soketi:
    image: ghcr.io/coollabsio/coolify-realtime:1.0.16@sha256:b5bb9d1c95d9b4ca59773b82d1e1a2bf4ccac5fbed33be19b9b3906574db3629
    container_name: coolify-realtime
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      SOKETI_DEFAULT_APP_ID: ${PUSHER_APP_ID}
      SOKETI_DEFAULT_APP_KEY: ${PUSHER_APP_KEY}
      SOKETI_DEFAULT_APP_SECRET: ${PUSHER_APP_SECRET}
    volumes:
      - /data/coolify/ssh:/var/www/html/storage/app/ssh
    ports:
      - "127.0.0.1:6001:6001"
      - "127.0.0.1:6002:6002"

networks:
  default:
    name: coolify
    external: true

volumes:
  coolify-db:
    name: coolify-db
  coolify-redis:
    name: coolify-redis
EOF
cd /data/coolify/source && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /data/coolify/source/.env not found` means step 3 did not write the
file. `network coolify declared as external, but could not be found` means the
`docker network create` line in step 2 did not run. `services must be a mapping` means the
indentation was lost between the page and your terminal: run `rm /data/coolify/source/compose.yml`
and paste again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-coolify
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Coolify · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://coolify.io/docs/knowledge-base/server/proxies and
# https://caddyserver.com/docs/automatic-https
#
# Three routes, because one hostname fronts three services, and this is the
# table upstream's own proxy writes for an instance with a domain. Drop either
# socket route and the dashboard loads while its live logs and web terminal
# never connect. Append it to /etc/caddy/Caddyfile with <DOMAIN> replaced by
# the hostname pointed at this box.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# Upstream's rules are PathPrefix(`/app`) for live logs and
	# PathPrefix(`/terminal/ws`) for the web terminal. These are those.
	reverse_proxy /app* 127.0.0.1:6001
	reverse_proxy /terminal/ws* 127.0.0.1:6002

	# Everything else is the dashboard. No loopback port is in the firewall.
	reverse_proxy 127.0.0.1:8115
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-coolify /etc/caddy/Caddyfile`, reload, and
paste again. Three routes for one hostname is not a mistake: the dashboard is on 8115, its live
deployment logs come over a socket on 6001, and its web terminal over another on 6002. Upstream's
own proxy splits the same hostname the same way. If you drop either socket line, the dashboard
will load and its logs will spin forever with no error anywhere.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8115`, `6001`, `6002`, `5432` or `6379`.

If you do not: delete anything for those five with `sudo ufw delete allow 8115` and so on. All
three application ports are bound to 127.0.0.1 by the compose file and the two database ports are
never published, so none of them has a host port a firewall rule could apply to. Upstream's
firewall page tells you to open 8000, 6001 and 6002, and then says you can close them once you
reach the dashboard on a custom domain. You are reaching it on a custom domain from the first
request, so they never open here. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off, and `sudo ufw enable` puts it back.

## 7. Start and verify

```bash
cd /data/coolify/source
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/health; echo
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/register | grep -c 'Create your account'
docker compose ps
```

You should see, in order: the loop reaching `200`, the single word `OK`, then
`https://<DOMAIN>/register`, then a count of at least `1`, then four containers listed.

If you do not: the pull alone can take several minutes and the application migrates its own
database on the way up, so let the loop run all forty times before deciding anything is broken.
If it never reaches `200`, run `docker compose logs --tail 20 postgres` first, because a database
that never reports healthy is step 3 with an empty `DB_PASSWORD`, and
`docker compose logs --tail 40 coolify` second. A `502` from Caddy with healthy containers means
step 5 is pointing at the wrong port. A running container is not success.

Now open https://<DOMAIN> in a browser. The first screen carries the heading `Coolify` above the
line `Create your account`, with a `Root User Setup` notice explaining that this account will have
full admin access. Create it. This is the only moment it can be made, and there is no mail server
here to reset the password, so put it in your password manager before you submit the form.

```bash
curl -sSL -o /dev/null -w '%{url_effective}\n' https://<DOMAIN>/register
```

You should see: `https://<DOMAIN>/login`.

If you do not: still seeing `/register` means the account was not created. Registration closes
itself the moment the first user exists, and that is the whole of the signup security model here.

Three things left, all in the dashboard, and the middle one is the important one. In Settings, set
the instance's domain to `https://<DOMAIN>`. In Servers, open `localhost`, go to Proxy and choose
`Custom (None)` until the page reads `Custom (None) Proxy Selected`. Then press Validate on that
same server and confirm it reports reachable. Then:

```bash
docker ps -a --filter name=coolify-proxy --format '{{.Names}} {{.Status}}'
```

You should see: nothing at all, or a single line ending `Exited`.

If you do not: a `coolify-proxy` with an `Up` status means Traefik is still selected for this
server and is competing with Caddy for ports 80 and 443. Go back to the Proxy tab and pick
`Custom (None)`. If Validate reports the server unreachable instead, the key chain from step 2 is
the cause: check that `~/.ssh/authorized_keys` has a line ending in `coolify` and that the file
under /data/coolify/ssh/keys is owned by `9999`.

## 8. First backup and restore

Two artifacts. The database holds every project, server, key and deployment record. The config
archive holds what rebuilds the service around it, the host key included.

```bash
cd /data/coolify/source
docker compose exec -T postgres pg_dump -U coolify -d coolify | gzip > /srv/coolify/backups/coolify-db-$(date +%F).sql.gz
sudo tar -czf /srv/coolify/backups/coolify-config-$(date +%F).tar.gz -C /data/coolify source ssh -C /etc/caddy Caddyfile
ls -lh /srv/coolify/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline, because
`pg_dump` snapshots a running database.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/coolify
scp vps:/srv/coolify/backups/* ~/backups/coolify/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/coolify/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

To restore: `docker compose down`, untar the config archive back into /data/coolify so
source/.env and the host key land before anything starts, `docker compose up -d postgres`, wait
for it to report healthy, then pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U coolify -d coolify`, then `docker compose up -d`. Know
the stakes: those rows are encrypted with `APP_KEY` from that `.env`, so a database restored
without the config archive comes back with credentials nobody can read. The two files travel
together or neither of them is a backup.

## 9. Updating later

Versions are listed at https://github.com/coollabsio/coolify/releases, and the realtime image
that pairs with each is named in `versions.json` at that tag. Take both backup artifacts first,
then edit the two `image:` lines in /data/coolify/source/compose.yml to the new tags and digests.

```bash
cd /data/coolify/source
docker compose pull
docker compose up -d
docker compose logs --tail 40 coolify
```

You should see: migration output, then the application starting, and no repeating restart.

If you do not: put the old tags and digests back and run the same three commands. `AUTOUPDATE` is
`false` in your .env, which is why the dashboard's own update button will not do this behind your
back; that is the point of pinning a digest, and it is also why nobody will apply a security fix
here except you.

## 10. What will probably go wrong

The first boot fails at a proxy nobody asked for. A fresh instance seeds its own server entry with
Traefik selected and tries to start it straight away, and Traefik wants 80 and 443, which Caddy
already holds. I spent ten minutes reading a red `Bind for 0.0.0.0:80 failed: port is already
allocated` before I understood it was the correct outcome and not a broken install: Docker refused
a second proxy those ports. Choosing `Custom (None)` in step 7 ends the attempts.

## 11. Out of scope

- Do not select Traefik or Caddy as this server's proxy, and do not stop the host Caddy to make
  room for one. Applications deployed here get a loopback port and a site block in
  /etc/caddy/Caddyfile, the same way this dashboard did.
- Do not run upstream's one-line installer on this box. It fetches its own compose files, writes
  its own .env and installs a root login, and this install has done that work already.
- Do not configure SMTP, Slack or any other notification transport, and do not add an S3 backup
  destination. Each is a separate credential and none is needed to deploy.
- Do not connect a GitHub App or enable automatic deployments yet. Get one application running
  by hand first, so the next failure has one cause instead of two.
