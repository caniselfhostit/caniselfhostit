This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing WeKan v10.71 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read this before step 1. That hostname becomes `ROOT_URL` inside the container, and WeKan is a
Meteor application, which means the browser opens its live data socket at whatever `ROOT_URL`
says rather than at the address the page came from. Get it wrong and you get a sign-in page that
looks perfect above boards that never finish loading. Step 10 is about nothing else.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
grep -c -w avx /proc/cpuinfo || true
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, a
non-zero AVX count on amd64, and your server's IP on the last line.

If you do not: an AVX count of `0` on an `amd64` box is a stop, not a warning. MongoDB 7 needs
that instruction set and mongod exits during start-up without it, which upstream documents as
the reason old hardware needs a qemu detour. An empty last line means the A record does not
exist yet: add it, wait a minute, and run `dig +short <DOMAIN>` again, because Caddy cannot get
a certificate for a hostname that does not resolve and failed attempts count against a rate
limit you cannot see. Under 2048 MB free RAM is also a stop: MongoDB and a Node application both
want memory, and the OOM killer arrives during your first import.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wekan /srv/wekan/backups
ls -la /srv/wekan
```

You should see: `backups`, owned by you, and nothing else.

If you do not: there is deliberately no `data` directory. MongoDB chowns /data/db to its own uid
and the WeKan image chowns /data to a system user made when the image was built, so both live in
named volumes that Docker owns, and step 8 takes the backups through the containers rather than
off the disk.

## 3. Secrets

This install generates none. WeKan has no admin token, and its only credential is the first
account, which you create in a browser in step 7. MongoDB runs with no password: it publishes no
host port, only the WeKan container can reach it, and turning on access control for a replica
set means a shared key file on a uid-owned mount for a database nothing else can talk to.

One value still has to reach the container, because it carries your hostname. Replace `<DOMAIN>`
on the first line before you paste:

```bash
umask 077
cat > /srv/wekan/.env <<'EOF'
ROOT_URL=https://<DOMAIN>
EOF
chmod 600 /srv/wekan/.env
umask 022
cat /srv/wekan/.env
```

You should see: mode `-rw-------`, your own username twice, and one line reading
`ROOT_URL=https://` and your hostname, with no trailing slash and no quotes, which is the form
upstream documents.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/wekan/.env` and carry
on. A trailing slash or a pair of quotes around the value is the failure step 10 describes, and
it is worth fixing here rather than debugging later.

Do not paste the password you pick for your WeKan account, the contents of any file, or any
command output you have not read, into this chat window. Nothing here is a generated secret, but
the account you make in step 7 is the only credential this install has.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/wekan/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/wekan/compose.yml` and paste again in one go. WeKan serves on 8080 inside its
container and 8104 is bound to 127.0.0.1 on the host, so Caddy is the only route in.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-wekan /etc/caddy/Caddyfile`, reload, and
paste again. Caddy requests the certificate on the first request to your hostname and renews it
on its own, so there is nothing to schedule. It also performs the WebSocket upgrade the live
data socket needs with no extra directive, which is why this block has no websocket stanza.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8104` or `27017`.

If you do not: delete anything for `8104` or `27017` with `sudo ufw delete allow 8104`. 8104 is
bound to 127.0.0.1 by the compose file and 27017 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

MongoDB stays unhealthy until its one-member replica set is initiated, which is what creates the
oplog Meteor tails. That is the fifth line below.

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

You should see, in order: `1` from the mongosh line, the loop reaching `200`,
`<title>Wekan</title>`, then `200`, then `https://` and your hostname with no trailing slash.

If you do not: the first pull takes a while, and WeKan's first boot runs its own schema
migrations, so the loop legitimately spends a few minutes short of `200`. A `502` throughout
means Caddy is reaching nothing: check `docker compose ps`, and if `wekan-db` never reports
healthy run `docker compose logs --tail 20 wekandb`, because the replica-set line is the one
that has to have worked. `<title>Wekan</title>` missing while the status is `200` means
something other than WeKan answered. A `printenv` that disagrees with your hostname sends you
back to step 3, and it is worth fixing now rather than after you have made boards.

The first screen at https://<DOMAIN>/sign-in is a form headed `Sign In`, with username and
password fields and a link to register. Upstream states the first registered user becomes the
administrator and later ones are ordinary users, so register yours before anybody else finds the
hostname:

Open https://<DOMAIN>/sign-up, register your username, email address and password, and sign in.
An `Internal Server Error` on that screen is upstream's documented answer when no mail server is
configured: the account is created anyway, so go to https://<DOMAIN>/sign-in and check.

Now close registration, so the next person who reaches your hostname cannot make an account:

```bash
cd /srv/wekan
printf 'db.settings.updateOne({}, {$set: {disableRegistration: true, modifiedAt: new Date()}});\n' | docker compose exec -T wekandb mongosh --quiet wekan
docker compose restart wekan
sleep 30
printf 'print(db.settings.findOne({}).disableRegistration);\n' | docker compose exec -T wekandb mongosh --quiet wekan
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/sign-in
```

You should see: an acknowledgement line from the update, then `true`, then `200`. Reload
https://<DOMAIN>/sign-in in your browser and the register link is gone.

If you do not: `MongoServerError` from either line means you pasted them before the database was
up, so run `docker compose ps` and try again. `null` instead of `true` means WeKan had not yet
written its settings document when you ran the update, which happens if you closed registration
before creating your account: create the account first, then run the block again. This setting
is enforced on the server rather than in the page, so with it on WeKan refuses an account that
arrives without an invitation code.

## 8. First backup and restore

Three artifacts: boards, attachments and configuration live in three places.

```bash
cd /srv/wekan
docker compose exec -T wekandb mongodump --quiet --archive --gzip --db=wekan > /srv/wekan/backups/wekan-db-$(date +%F).archive.gz
docker compose exec -T wekan tar -C /data -czf - . > /srv/wekan/backups/wekan-files-$(date +%F).tar.gz
sudo tar -czf /srv/wekan/backups/wekan-config-$(date +%F).tar.gz -C /srv/wekan compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/wekan/backups/
```

You should see: three files, all small on a fresh install, none of them zero bytes. Nothing goes
offline: `mongodump` reads a running database consistently.

If you do not: an `.archive.gz` of about 20 bytes is an empty dump, which means `mongodump`
failed and the shell created the file anyway. Run the dump line without `--gzip` and read the
error it prints.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/wekan
scp vps:/srv/wekan/backups/* ~/backups/wekan/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/wekan/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty board:

```bash
cd /srv/wekan
docker compose down
docker compose up -d wekandb
sleep 30
docker compose exec -T wekandb mongosh --quiet --eval 'try { rs.status().ok } catch (e) { rs.initiate({_id: "rs0", members: [{_id: 0, host: "wekandb:27017"}]}).ok }'
docker compose exec -T wekandb mongorestore --archive --gzip --drop < /srv/wekan/backups/wekan-db-$(date +%F).archive.gz
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/sign-in
```

You should see: restore progress lines ending in `done`, then `200`, and your account still
works when you sign in.

If you do not: `Failed: no reachable servers` means the database container had not finished
starting, so wait longer and run the `mongorestore` line again. Understand the stakes before you
skip this: every card, comment, checklist and attachment you will put in this is in that dump
and that files tarball, and a board nobody copied off the box is gone the day the disk is.

## 9. Updating later

New versions are listed at https://github.com/wekan/wekan/releases. WeKan often ships several
releases in one day, so read that page as a list, not a queue. Take all three backups first,
then edit the `image:` line in /srv/wekan/compose.yml to the new tag and its digest.

```bash
cd /srv/wekan
docker compose pull
docker compose up -d
docker compose logs --tail 30 wekan
```

You should see: schema migration lines, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
four checks from step 7 before you call the update done. Leave the MongoDB line alone: a
database major version is a separate migration with its own dump and restore.

## 10. What will probably go wrong

`ROOT_URL`. I left it at the `http://localhost` upstream's compose file ships with, the sign-in
page rendered over https perfectly, and I believed the install had worked. Then every board hung
on a loading spinner and neither container log said why. The page comes from Caddy, but a Meteor
application tells the browser to open its live data socket at whatever `ROOT_URL` claims, and
mine sent the browser back to its own machine. If a board never finishes loading, run
`docker compose exec -T wekan printenv ROOT_URL` first. It has to be `https://` and the
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
