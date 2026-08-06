You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install WeKan v10.71 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and the same hostname becomes `ROOT_URL` inside
the container, which step 10 is about.

WeKan plus MongoDB needs 2048 MB of RAM available and 10 GB free on /srv. Both images publish
amd64 and arm64. MongoDB 7 also needs the AVX instruction set on x86, which is why upstream
documents a qemu detour for old hardware. Measure all five:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
grep -c -w avx /proc/cpuinfo || true
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If the architecture is `amd64` and the AVX count is `0`, stop as well:
mongod exits during start-up on that CPU and no environment variable fixes it. If `dig +short`
prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wekan /srv/wekan/backups
ls -la /srv/wekan
```

Assert: `ls -la` shows `backups` owned by the login user. There is no `data` directory here on
purpose: MongoDB chowns /data/db to its own uid and the WeKan image chowns /data to a system
user made at image build time, so both live in named volumes that step 8 backs up.

## 3. Secrets

This install generates no secrets, so there is nothing here to keep out of your summary. WeKan
has no admin token, and its only credential is the first account, made in a browser in step 7.
MongoDB runs with no password: it publishes no host port, only the WeKan container reaches it,
and access control on a replica set would mean a shared key file on a uid-owned mount.

One value still has to arrive from outside these files, because it carries the hostname:

```bash
umask 077
cat > /srv/wekan/.env <<'EOF'
ROOT_URL=https://<DOMAIN>
EOF
chmod 600 /srv/wekan/.env
umask 022
cat /srv/wekan/.env
```

Assert: mode `-rw-------`, and one line reading `ROOT_URL=https://` followed by the real
hostname, with no trailing slash and no quotes, which is the form upstream documents.

## 4. compose.yml

```bash
cat > /srv/wekan/compose.yml <<'EOF'
# WeKan · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   mongodb compose .... https://github.com/wekan/wekan/blob/v10.71/docker-compose-mongodb-v7.yml
#   root url and proxy . https://github.com/wekan/wekan/blob/v10.71/docs/Webserver/Settings.md
#   oplog reactivity ... https://github.com/wekan/wekan/blob/v10.71/docs/Databases/MongoDB/Oplog-Configuration.md
#   image and port ..... https://github.com/wekan/wekan/blob/v10.71/Dockerfile
#
# Two services: WeKan and the MongoDB 7 that holds every board. Both data
# directories are named volumes, because MongoDB chowns /data/db to its own
# uid and the WeKan image chowns /data to a system user made at image build
# time. ROOT_URL arrives from /srv/wekan/.env because it carries the hostname,
# and a Meteor application opens its live data socket at whatever ROOT_URL
# says. Digests read on 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  wekandb:
    image: mongo:7.0.39@sha256:35a5926f71f8b6cb19206bee928c5a85f241a8be99f20c81abe35ae78a73415d
    container_name: wekan-db
    restart: unless-stopped
    # A one-member replica set, which is what makes the oplog exist. Meteor
    # tails it instead of re-reading whole collections on a timer: upstream
    # measures 50 ms rather than 2000 ms before another person's card move
    # lands on screen. Step 7 initiates the set once.
    command: ["mongod", "--replSet", "rs0", "--bind_ip_all", "--quiet"]
    volumes:
      - wekan-db:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "try { quit(db.hello().isWritablePrimary ? 0 : 1) } catch (e) { quit(1) }"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 30s
    # No `ports:` at all: 27017 is reachable only from the other container.

  wekan:
    image: wekanteam/wekan:v10.71@sha256:5ccfd900c9b68fd9ebd9eb194d286119fdee000ba1e907df583ce942bad54fdc
    container_name: wekan-app
    restart: unless-stopped
    env_file: /srv/wekan/.env
    environment:
      # The image can also start a FerretDB it carries inside itself; naming
      # the backend takes that decision away from the entrypoint.
      WEKAN_DB: mongodb
      MONGO_URL: mongodb://wekandb:27017/wekan
      MONGO_OPLOG_URL: mongodb://wekandb:27017/local?replicaSet=rs0
      METEOR_REACTIVITY_ORDER: changeStreams,oplog,polling
      # SockJS rather than uws, upstream's own default, and it puts a plain
      # http endpoint at /sockjs/info that step 7 checks.
      DDP_TRANSPORT: sockjs
      # Attachments and avatars are files under this path, not database rows.
      WRITABLE_PATH: /data
      WITH_API: "true"
    volumes:
      - wekan-files:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8104.
      - "127.0.0.1:8104:8080"
    depends_on:
      wekandb:
        condition: service_healthy

volumes:
  wekan-db:
  wekan-files:
EOF
cd /srv/wekan && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. WeKan serves on 8080 inside its container and 8104 is bound to
127.0.0.1 on the host, so Caddy is the only route in.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-wekan
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# WeKan · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/wekan/wekan/blob/v10.71/docs/Webserver/Caddy.md and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also ROOT_URL in .env and the two have to say exactly the same thing: WeKan
# is a Meteor application, so the browser opens its live data socket at
# whatever ROOT_URL claims, and a mismatch gives a sign-in screen that works
# above boards that never finish loading.

<DOMAIN> {
	# Nothing here is meant to be embedded in another site, and board and
	# card names travel inside these URLs, so the referrer is trimmed.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8104 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. The live data socket
	# rides the same route: Caddy performs the WebSocket upgrade with no extra
	# directive, which is why there is no websocket stanza here.
	reverse_proxy 127.0.0.1:8104
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-wekan, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it alone, and performs the WebSocket upgrade the
live data socket needs with no extra directive.

## 6. Firewall

Two ports open, both Caddy's, and idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8104 stays closed because it is bound to 127.0.0.1, and 27017 because compose
never publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8104 or 27017.

## 7. Start and verify

MongoDB stays unhealthy until its one-member replica set is initiated, which is what creates
the oplog Meteor tails.

```bash
cd /srv/wekan
docker compose pull
docker compose up -d wekandb
for i in $(seq 1 20); do docker compose exec -T wekandb mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1 && break; sleep 5; done
docker compose exec -T wekandb mongosh --quiet --eval 'try { rs.status().ok } catch (e) { rs.initiate({_id: "rs0", members: [{_id: 0, host: "wekandb:27017"}]}).ok }'
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/sign-in); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/sign-in | grep -o '<title>Wekan</title>'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/sockjs/info
docker compose exec -T wekan printenv ROOT_URL
```

Assert all four, and print what you received for each. The mongosh line prints `1`. The loop
ends printing `200`. The grep prints `<title>Wekan</title>`, which WeKan writes into every page
it serves, so it proves the application answered. `/sockjs/info` prints `200`, the live data
socket's own endpoint reaching the container. `printenv` prints `https://` and the hostname,
with no trailing slash. If any of the four misses, stop, run
`docker compose logs --tail 40 wekan` and `docker compose logs --tail 20 wekandb`, and name the
likely cause: a database that never reports healthy points at the replica-set line above, a
`502` at step 5, a `printenv` that disagrees with the hostname at step 3. A running container is
not success.

The first screen at https://<DOMAIN>/sign-in is a form headed `Sign In`, with username and
password fields and a link to register. Upstream states the first registered user becomes the
administrator, which is why the next step is a hard stop.

STOP: tell the user to open https://<DOMAIN>/sign-up now, register their username, email address
and password, and confirm once they are signed in. Do not continue until they confirm. Tell them
an `Internal Server Error` there is upstream's documented answer when no mail server is set: the
account is made anyway, so sign in and check.

Registration is open to anyone who reaches the hostname. Close it now:

```bash
cd /srv/wekan
printf 'db.settings.updateOne({}, {$set: {disableRegistration: true, modifiedAt: new Date()}});\n' | docker compose exec -T wekandb mongosh --quiet wekan
docker compose restart wekan
sleep 30
printf 'print(db.settings.findOne({}).disableRegistration);\n' | docker compose exec -T wekandb mongosh --quiet wekan
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/sign-in
```

Assert: the second mongosh line prints `true` and the curl prints `200`. That setting is
enforced on the server rather than in the page: with it on, WeKan refuses an account that
arrives without an invitation code. Then have the user reload the sign-in page and confirm the
register link is gone. Both asserts and that confirmation land before you report success.

## 8. First backup and restore

Three artifacts: boards, attachments and configuration live in three places.

```bash
cd /srv/wekan
docker compose exec -T wekandb mongodump --quiet --archive --gzip --db=wekan > /srv/wekan/backups/wekan-db-$(date +%F).archive.gz
docker compose exec -T wekan tar -C /data -czf - . > /srv/wekan/backups/wekan-files-$(date +%F).tar.gz
sudo tar -czf /srv/wekan/backups/wekan-config-$(date +%F).tar.gz -C /srv/wekan compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/wekan/backups/
```

Assert: all three exist and none is empty. Print all three sizes. Nothing goes offline:
`mongodump` reads a running database consistently. A backup on the same disk as the data is not
a backup, so run this one from the user's machine:

```bash
mkdir -p ~/backups/wekan
scp vps:/srv/wekan/backups/* ~/backups/wekan/
```

To restore: `docker compose up -d wekandb`, wait for it to answer ping, re-run step 7's
replica-set line (on a fresh volume the container reports healthy only after it), feed the
`.archive.gz` into `docker compose exec -T wekandb mongorestore --archive --gzip --drop`, untar
the config archive into /srv/wekan, `docker compose up -d`, then feed the files tarball into
`docker compose exec -T wekan tar -C /data -xzf -`. Tell the user the stakes: every card,
comment and attachment is in that dump and that tarball, and a board nobody copied off the box
dies with the disk.

## 9. Updating later

New versions are listed at https://github.com/wekan/wekan/releases. WeKan often ships several
releases in one day, so read that page as a list, not a queue. Take all three backups first,
then edit the image line in /srv/wekan/compose.yml to the new tag and digest:

```bash
cd /srv/wekan
docker compose pull
docker compose up -d
docker compose logs --tail 30 wekan
```

WeKan runs its own schema migrations on the way up, so watch that log until it settles, then
re-run step 7's four asserts before calling the update done. Leave the MongoDB line alone: a
database major version is a separate migration with its own dump and restore.

## 10. What will probably go wrong

`ROOT_URL`. I left it at the `http://localhost` upstream's compose file ships with, the sign-in
page rendered over https perfectly, and I believed the install had worked. Then every board hung
on a loading spinner and neither container log said why. The page comes from Caddy,
but a Meteor application tells the browser to open its live data socket at whatever `ROOT_URL`
claims, and mine sent the browser back to its own machine. If a board never finishes loading,
run `docker compose exec -T wekan printenv ROOT_URL` first. It has to be `https://` and the
hostname, no trailing slash, no port.

## 11. Out of scope

- Do not configure `MAIL_URL` or `MAIL_FROM`. Upstream states in writing that a working email
  server is not required, and outbound mail from a fresh VPS is a fight for a different day.
- Do not enable OAuth2, OIDC, LDAP, SAML or CAS. Each is an account somewhere else and a second
  failure mode, and this install already has a working sign-in.
- Do not switch the database to FerretDB. The image carries one, and that is a different install
  with a different backup story.
- Do not set the `S3` variable and do not publish 27017. Attachments belong in the volume this
  prompt backs up, the database on the network where nothing else reaches it.
