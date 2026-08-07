This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Countly Lite 25.03.51 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` is the address every SDK you install afterwards posts its
events to, so it ends up in the source of every app and page you measure. Moving it later means
shipping all of them again. Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64`, and your server's
IP on the last line.

If you do not: `arm64` on the third line is the end of this install, not a detour. Upstream
publishes the Countly image for amd64 only and there is no arm tag to fall back to. Under
4096 MB is also a stop: the image runs two Node processes with a 2048 MB heap ceiling each and
MongoDB is a third beside them, so a 2 GB box gets through the first boot and then dies during
the first real traffic. An empty last line means the A record does not exist yet. Add it, wait a
minute, and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name
that does not resolve and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/countly /srv/countly/backups
sudo install -d -m 700 /srv/countly/mongo
ls -la /srv/countly
```

You should see: `backups` owned by you, and `mongo` at mode `drwx------` owned by root.

If you do not: leave `mongo` owned by root on purpose. The MongoDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. There is no directory for Countly itself, which is correct: upstream defaults
file storage to GridFS, so uploads and app icons are documents in the database and the
application container writes nothing worth keeping to disk.

## 3. Secrets

Two secrets, both read by the dashboard process. `WEB_SESSION_SECRET` replaces the value
upstream ships in its sample config, which is published in the repository and signs your session
cookie. `PASSWORDSECRET` is mixed into every password before it is hashed, and it has to exist
before your first account does, because changing it later invalidates every password already
stored.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/countly/.env` and carry
on. If the file already existed from an earlier attempt, this block has now replaced both values,
which is harmless before you have an account and a problem afterwards: a changed
`PASSWORDSECRET` locks you out of every account already created, and the error you get is a
plain wrong-password message rather than anything about the file.

Do not paste that file, either value, or any output containing them into this chat window. This
file is the half of your backup that is not the database: a MongoDB dump restored without it
returns every account and no password that works on any of them.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/countly/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/countly/compose.yml` and paste again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-countly /etc/caddy/Caddyfile`, reload,
and paste again. Caddy requests the certificate on the first request and renews it on its own,
so there is nothing here to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8174` or `27017`.

If you do not: delete anything for `8174` or `27017` with `sudo ufw delete allow 8174`. 8174 is
bound to 127.0.0.1 by the compose file and 27017 is never published at all, so the database has
no host port a firewall rule could apply to, and that is exactly why it can run without a
password. 80/tcp is there to redirect to HTTPS and to answer the ACME challenge, 443/tcp is the
only way in, and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a
different problem: Prompt Zero left this firewall enabled, so something has turned it off since,
and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The image runs a first-boot script that writes its plugin list and loads a city database into
MongoDB before it serves anything, so the first `up` takes minutes rather than seconds.

```bash
cd /srv/countly
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/ping; echo
curl -sS https://<DOMAIN>/o/ping; echo
curl -sS https://<DOMAIN>/setup | grep -c 'data-localize="setup.ready"'
```

You should see, in order: the loop reaching `200`, the bare word `Success` from the dashboard,
`{"result":"Success"}` from the collection API, and `1` from the last command. Those two ping
endpoints are the pair upstream's own health-check script calls, and each answers only after its
process has reached MongoDB.

If you do not: the loop is generous on purpose, so let it run out before you touch anything. If
it never reaches `200`, run `docker compose logs --tail 20 mongodb` first, because a database
that never reports healthy is step 2 done wrong, and `docker compose logs --tail 40 countly`
second. A Caddy `502` over a container that shows as running means nothing is answering on 8174
yet. A `0` from the last command instead of a `1` means the setup screen is not being served,
which on a fresh install means the dashboard process has not finished starting.

The first screen at https://<DOMAIN>/setup shows the heading `Your Countly server is ready!` over
a `Full Name` field and a `Create Account` button.

Now open https://<DOMAIN>/setup in a browser, create your administrator account, and finish the
short wizard after it by adding your first application. Two things before you start. Nothing else
will ever create that first account, and there is no mail server here to reset it with, so put
the password in your password manager as you type it. The wizard also asks whether to enable
Countly's own analytics on this server, which reports to stats.count.ly; the compose file above
already answers no, so answering no there is the consistent choice.

Then come back and run this:

```bash
cd /srv/countly
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
key=$(docker compose exec -T mongodb mongosh --quiet countly --eval 'const a=db.apps.findOne({}); print(a ? (a.key || (a.keys && a.keys[0] && a.keys[0].key) || "") : "")' | tr -d '\r\n')
bogus=$(openssl rand -hex 16)
curl -sS "https://<DOMAIN>/i?app_key=${bogus}&device_id=selfhost-check&begin_session=1"; echo
curl -sS "https://<DOMAIN>/i?app_key=${key}&device_id=selfhost-check&begin_session=1"; echo
printf '<script src="https://<DOMAIN>/sdk/web/countly.min.js"></script>\n<script>\n  Countly.init({ app_key: "%s", url: "https://<DOMAIN>" });\n  Countly.track_sessions();\n  Countly.track_pageview();\n</script>\n' "$key"
```

You should see: `302`, then `{"result":"App does not exist"}`, then `{"result":"Success"}`, then
a snippet with your own app key already in it.

If you do not: the `302` is the one that decides whether this install is safe to leave running.
It means Countly redirected the setup page to the login page because the members collection is no
longer empty. A `200` there means nobody owns the install yet and anyone who finds the hostname
can claim it, so stop and finish the account. An empty `key` means the wizard did not create an
application, so go back and add one. That final `{"result":"Success"}` is the whole product
working end to end: an event went in over https, through Caddy, through the image's nginx, into
the collection API and into MongoDB. The app key it printed is not a secret, it is readable in
the source of every page it measures, which is the opposite of the two values in
/srv/countly/.env. Paste that snippet into your site. Until it is on a page, or one of the mobile
SDKs is in your app, the dashboard stays empty, and that is not a fault.

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

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`mongodump` reads a running database.

If you do not: an archive of about 20 bytes is an empty dump, which means `mongodump` failed and
the shell created the file anyway. Run the dump line without the redirect to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/countly
scp vps:/srv/countly/backups/* ~/backups/countly/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/countly/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one test event:

```bash
cd /srv/countly
docker compose down
sudo rm -rf /srv/countly/mongo
sudo install -d -m 700 /srv/countly/mongo
docker compose up -d mongodb
sleep 30
gunzip -c /srv/countly/backups/countly-db-$(date +%F).archive.gz | docker compose exec -T mongodb mongorestore --archive --gzip --drop
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/ping; echo
```

You should see: restore lines naming the `countly` database, then `Success` from the last
command, which means the dashboard came back against a database that was deleted and rebuilt.
Sign in and check that your account still works.

If you do not: a login that fails after a restore is almost always .env. The password secret in
that file is mixed into every stored password, so a database restored beside the wrong .env
returns all your accounts and no way into any of them. Untar the config archive into
/srv/countly before you start the containers, not after.

## 9. Updating later

New versions are listed at https://github.com/Countly/countly-server/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/countly/compose.yml to the new tag and its
digest.

```bash
cd /srv/countly
docker compose pull
docker compose up -d
docker compose logs --tail 30 countly
```

You should see: the services starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
two ping checks from step 7 before you call the update done, and send one more test event as
well, because a server that answers `Success` on health can still be refusing writes if a
collection migration stopped halfway.

## 10. What will probably go wrong

The first `docker compose up -d` returns in a second and then https://<DOMAIN> answers a Caddy
`502` for several minutes. I read the compose file twice looking for a mistake that was not there
before running `docker compose logs -f countly` and finding the container loading a city database
into MongoDB, which it does once, on first boot, before nginx answers anything. Give the loop in
step 7 its full forty attempts, and if you open the log, watch it: restarting the container
starts that load over.

## 11. Out of scope

- Do not add `drill`, `funnels`, `cohorts`, `flows`, `retention_segments`, `surveys` or
  `ab-testing` to a `COUNTLY_PLUGINS` variable. Those directories are not in the open repository
  this image is built from, and naming one leaves the container restarting.
- Do not configure SMTP. Collection and the dashboard work without it, and what it switches on is
  email reports on data that does not exist yet.
- Do not run upstream's one-line shell installer. It puts Countly and MongoDB on the host outside
  Docker, and both are already in pinned containers here.
- Do not turn on MongoDB authentication afterwards. The database publishes no port, and adding a
  user without changing the connection string leaves the container in a restart loop that reads
  like a broken image.
