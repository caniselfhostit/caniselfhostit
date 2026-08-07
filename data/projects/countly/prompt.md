You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Countly Lite 25.03.51 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say this when you ask: every SDK they add later posts its events to `<DOMAIN>`, so it ends up in
the source of every app and page they measure, and moving it means shipping all of them again.
Its A record must already point at this server.

Countly Lite needs 4096 MB of RAM available and 20 GB free on /srv: the image starts a Node
collection API and a Node dashboard with a 2048 MB heap ceiling each, and MongoDB is a third
process beside them. Upstream publishes the image for amd64 only. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope. If the architecture is `arm64`, print it and stop: there is no arm64 tag to
fall back to. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/countly /srv/countly/backups
sudo install -d -m 700 /srv/countly/mongo
ls -la /srv/countly
```

Assert: `ls -la` shows `backups` owned by the login user and `mongo` at mode `700` owned by
root. The MongoDB image chowns its own data directory on first start, so leave that one alone.
Countly gets no directory: file storage defaults to GridFS, so uploads are database documents.

## 3. Secrets

Two secrets, both read by the dashboard. `WEB_SESSION_SECRET` replaces the value upstream ships
in its sample config, which is published in the repository and signs the session cookie.
`PASSWORDSECRET` is mixed into every password before it is hashed, so it has to exist before the
first account does. Generate both on the server, print neither, and keep both out of your summary
and out of any log line.

```bash
umask 077
cat > /srv/countly/.env <<EOF
COUNTLY_CONFIG_FRONTEND_WEB_SESSION_SECRET=$(openssl rand -hex 32)
COUNTLY_CONFIG_FRONTEND_PASSWORDSECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/countly/.env
umask 022
ls -l /srv/countly/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user it is the half of the backup that
is not the database: a MongoDB dump restored without it returns every account and no working
password.

## 4. compose.yml

```bash
cat > /srv/countly/compose.yml <<'EOF'
# Countly Lite · the deterministic fallback. Authored by caniselfhostit from the
# upstream sources, not copied from a repository:
#   single-image build . https://github.com/Countly/countly-server/blob/25.03.51/Dockerfile-core
#   api config keys .... https://github.com/Countly/countly-server/blob/25.03.51/api/config.sample.js
#
# countly-core is upstream's single-image build: an nginx, the collection API on
# 3001 and the dashboard on 6001 all run inside it under runit.
#
# MongoDB runs with no user and no password, as upstream's compose does, which
# is acceptable only because it publishes no port. fileStorage defaults to
# gridfs, so uploads are documents in the database and the countly service needs
# no volume: all of the state is in MongoDB. Digests read on 2026-08-07;
# countly-core is amd64 only, which is why step 1 stops on arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mongodb:
    image: mongo:8.0.28@sha256:98605bfa1bb2a15dd82109e1d78ad31527a9a744909fab4606076fa71a0ae515
    container_name: countly-db
    restart: unless-stopped
    command: ["mongod", "--bind_ip_all", "--quiet"]
    volumes:
      - /srv/countly/mongo:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "quit(db.adminCommand('ping').ok ? 0 : 1)"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 20s
    # No `ports:` at all: 27017 is reachable only from the other container.

  countly:
    image: countly/countly-core:25.03.51@sha256:e3d94902a3c4c609fdda3895ea4326693c5f30289cf2f6a84e35b9773a182c03
    container_name: countly
    restart: unless-stopped
    env_file: /srv/countly/.env
    environment:
      # The empty middle component means "the API and the dashboard both".
      COUNTLY_CONFIG__MONGODB_HOST: mongodb
      COUNTLY_CONFIG__FILESTORAGE: gridfs
      # Upstream forks one worker per core; each is a Node heap of its own.
      COUNTLY_CONFIG_API_API_WORKERS: "2"
      # Caddy terminates TLS and the dashboard cannot see that from in here.
      # Told, it stamps X-Forwarded-Proto https before its own session
      # middleware runs, which is what marks the cookie Secure.
      COUNTLY_CONFIG_FRONTEND_WEB_SECURE_COOKIES: "true"
      COUNTLY_CONFIG_FRONTEND_COOKIE_SECURE: "true"
      # Upstream ships an Intercom widget on and usage reporting to
      # stats.count.ly on. Both off.
      COUNTLY_CONFIG_FRONTEND_WEB_USE_INTERCOM: "false"
      COUNTLY_CONFIG_FRONTEND_WEB_TRACK: none
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8174.
      - "127.0.0.1:8174:80"
    depends_on:
      mongodb:
        condition: service_healthy
EOF
cd /srv/countly && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one bind mount.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-countly
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Countly Lite · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/Countly/countly-server/blob/25.03.51/bin/config/nginx.server.conf
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. Every SDK you add later posts its events to that name.

<DOMAIN> {
	encode zstd gzip

	header {
		# Every page you measure loads /sdk/web/countly.min.js from this host,
		# so a downgrade on one of them is a downgrade on all of them.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# No X-Frame-Options on purpose: the rating and survey widgets are served
	# from this host to be drawn in a frame on your own site. 8174 is the
	# loopback port compose publishes here, and the nginx inside the image is
	# what splits /i and /o off to the collection API.
	reverse_proxy 127.0.0.1:8174
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-countly, reload, and report what it objected to. Caddy requests the
certificate on first request and renews it on its own. Nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp is
HTTP/3. 8174 stays closed because compose binds it to 127.0.0.1, and 27017 because compose
never publishes it: a MongoDB with no host port gives a firewall rule nothing to apply to,
which is why it can run without a password. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8174 or 27017.

## 7. Start and verify

The image runs a first-boot script that writes its plugin list and loads a city database into
MongoDB before serving anything, so the first `up` takes minutes.

```bash
cd /srv/countly
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/ping; echo
curl -sS https://<DOMAIN>/o/ping; echo
curl -sS https://<DOMAIN>/setup | grep -c 'data-localize="setup.ready"'
```

Assert all four and print what you got: the loop ends on `200`, the dashboard prints the bare
word `Success`, the collection API prints `{"result":"Success"}`, the last command prints `1`.
Those two ping endpoints are the pair upstream's own health-check script calls, and each answers
only after its process has reached MongoDB; the `1` means the registration screen is being
served, which happens only while nobody owns this install. If any of the four misses, stop, run
`docker compose logs --tail 40 countly` and `docker compose logs --tail 20 mongodb`, and name the
likely earlier step: a database that never reports healthy is step 2, a Caddy `502` over a
running container means nothing answers on 8174 yet. A running container is not success.

The first screen at https://<DOMAIN>/setup shows the heading `Your Countly server is ready!`
over a `Full Name` field and a `Create Account` button.

STOP: tell the user to open https://<DOMAIN>/setup, create their administrator account, then
finish the short wizard after it by adding their first application, and wait. Do not continue
until they confirm both. Two things to tell them first: nothing else will ever create that
account and no mail server here can reset it, so the password goes in their password manager as
they type it, and the wizard's question about enabling Countly's own analytics on this server
reports to stats.count.ly, which compose.yml already answers no to.

Once they confirm, prove the install is claimed and that it accepts events:

```bash
cd /srv/countly
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
key=$(docker compose exec -T mongodb mongosh --quiet countly --eval 'const a=db.apps.findOne({}); print(a ? (a.key || (a.keys && a.keys[0] && a.keys[0].key) || "") : "")' | tr -d '\r\n')
bogus=$(openssl rand -hex 16)
curl -sS "https://<DOMAIN>/i?app_key=${bogus}&device_id=selfhost-check&begin_session=1"; echo
curl -sS "https://<DOMAIN>/i?app_key=${key}&device_id=selfhost-check&begin_session=1"; echo
printf '<script src="https://<DOMAIN>/sdk/web/countly.min.js"></script>\n<script>\n  Countly.init({ app_key: "%s", url: "https://<DOMAIN>" });\n  Countly.track_sessions();\n  Countly.track_pageview();\n</script>\n' "$key"
```

Assert all four. `/setup` prints `302`, upstream redirecting to the login page because the
members collection is no longer empty, and that is the security assert here: a `200` means the
install is still claimable by whoever finds it, so stop and do not report success. The invented
key prints `{"result":"App does not exist"}`; the real one prints `{"result":"Success"}`, the
product working end to end, an event carried over https through Caddy and the image's nginx into
MongoDB. The last command prints the snippet the user pastes into their site with their own app
key in it, so hand it to them as text: that key is readable in the source of every page it
measures, so it is not one of the secrets, and the values in /srv/countly/.env stay unprinted.
Tell the user the dashboard stays empty until the snippet is on a page or a mobile SDK is in
their app, and that this is not a fault.

## 8. First backup and restore

Two artifacts. MongoDB holds every account, application, session, event and uploaded file, and
`mongodump` with no database named takes all of it, which matters because file storage sits in a
second database beside the first. The config archive rebuilds the service around it.

```bash
cd /srv/countly
docker compose exec -T mongodb mongodump --quiet --archive --gzip > /srv/countly/backups/countly-db-$(date +%F).archive.gz
sudo tar -czf /srv/countly/backups/countly-config-$(date +%F).tar.gz -C /srv/countly compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/countly/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing stops: `mongodump` reads a
running database. A backup on the same disk is not a backup, so run this from the user's
machine:

```bash
mkdir -p ~/backups/countly
scp vps:/srv/countly/backups/* ~/backups/countly/
```

To restore: `docker compose down`, `sudo rm -rf /srv/countly/mongo`, recreate it as in step 2,
untar the config archive into /srv/countly so .env is back before anything starts,
`docker compose up -d mongodb`, wait about 30 seconds for healthy, pipe `gunzip -c` on the
archive into `docker compose exec -T mongodb mongorestore --archive --gzip --drop`, then
`docker compose up -d`. Order matters: the password secret in .env is mixed into every stored
password, so a database restored beside the wrong .env returns their accounts and no way into
any of them.

## 9. Updating later

New versions are listed at https://github.com/Countly/countly-server/releases. Take both backups
first, then edit the image line in /srv/countly/compose.yml to the new tag and digest:

```bash
cd /srv/countly
docker compose pull
docker compose up -d
docker compose logs --tail 30 countly
```

Countly migrates its collections on the way up. Watch that log until it settles, then re-run
step 7's ping checks before calling the update done.

## 10. What will probably go wrong

The first `docker compose up -d` returns in a second and then https://<DOMAIN> answers a Caddy
`502` for several minutes. I read the compose file twice looking for a mistake that was not there
before running `docker compose logs -f countly` and finding the container loading a city database
into MongoDB, which it does once, on first boot, before nginx answers anything. Give the loop in
step 7 its full forty attempts, and if you open the log, watch it: restarting the container
starts that load over.

## 11. Out of scope

- Do not add `drill`, `funnels`, `cohorts`, `flows`, `retention_segments`, `surveys` or
  `ab-testing` to a `COUNTLY_PLUGINS` variable. Those directories are not in the repository this
  image is built from, and naming one leaves the container restarting.
- Do not configure SMTP. Collection and the dashboard work without it, and what it switches on is
  email reports on data that does not exist yet.
- Do not run upstream's one-line shell installer. It puts Countly and MongoDB on the host outside
  Docker, and both are already in pinned containers here.
- Do not turn on MongoDB authentication afterwards. Adding a user without changing the connection
  string leaves the container in a restart loop that reads like a broken image.
