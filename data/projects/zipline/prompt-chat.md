This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Zipline 4.6.5 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` is the front of every share link this server hands out. A
screenshot you paste into a ticket today carries that hostname for as long as the link is worth
anything, so pick the name you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. If the RAM number is
under 2048, the thing that will kill you is not the web server, it is the thumbnail workers: the
image ships ffmpeg and renders video thumbnails on four threads, and the OOM killer arrives
during the first video rather than during the install.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/zipline /srv/zipline/uploads /srv/zipline/backups
sudo install -d -m 700 /srv/zipline/postgres
ls -la /srv/zipline
```

You should see: `uploads` and `backups` owned by you, and `postgres` at mode `drwx------` owned
by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `uploads` is yours, but the Zipline container runs as root, so the files
it writes in there will belong to root. That is why step 8 uses `sudo tar`.

## 3. Secrets

Two secrets: the PostgreSQL password and `CORE_SECRET`, which signs session cookies. Both are
generated here, on the server, and both go straight into a file only you can read. Hex rather
than base64 for both: one travels inside a connection string, and upstream refuses to start on a
secret shorter than 32 characters, which 32 hex bytes clears.

```bash
umask 077
cat > /srv/zipline/.env <<EOF
CORE_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/zipline/.env
umask 022
ls -l /srv/zipline/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/zipline/.env` and carry on.
If the file already existed from an earlier attempt, this block has now overwritten both secrets,
which is fine before the database exists and a problem afterwards: PostgreSQL keeps the password
it was created with, so a changed `DB_PASSWORD` on an existing volume shows up as an
authentication failure in the Zipline log rather than as anything about passwords.

Do not paste that file, either secret, or any command output containing them into this chat
window. You never need to read either value: the only credential you will type is the password
you choose in step 7, in a browser. Changing `CORE_SECRET` later logs every session out,
including your own, so leave it alone once this works.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/zipline/compose.yml <<'EOF'
# Zipline · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://zipline.diced.sh/docs/get-started/docker
#   variable reference . https://zipline.diced.sh/docs/config
#   core variables ..... https://zipline.diced.sh/docs/config/core
#   hardening guide .... https://zipline.diced.sh/docs/guides/hardening
#   reverse proxy ...... https://zipline.diced.sh/docs/guides/reverse-proxy
#
# Two services: Zipline and the PostgreSQL that holds accounts, tokens, short
# links and one row per uploaded file. The files themselves sit on disk under
# /srv/zipline/uploads, so a restore needs both halves or you get an index of
# things that are not there. Upstream's own compose file runs postgres 16, so
# this one stays on that major and pins a patch of it. Digests were read from
# the registries on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: zipline-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: zipline
      POSTGRES_USER: zipline
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/zipline/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zipline -d zipline"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  zipline:
    image: ghcr.io/diced/zipline:4.6.5@sha256:bfd5b0f7b5b8b3ed058a81667c78a14a7f997115d8433bec273620ec81be51d4
    container_name: zipline
    restart: unless-stopped
    env_file: /srv/zipline/.env
    environment:
      DATABASE_URL: postgres://zipline:${DB_PASSWORD}@postgres:5432/zipline
      # Caddy terminates TLS and speaks plain http here. Upstream asks for both
      # of these behind a proxy: without the first, every request looks like it
      # came from 127.0.0.1; without the second, the links handed back start
      # with http:// on a site only reachable over https.
      CORE_TRUST_PROXY: "true"
      CORE_RETURN_HTTPS_URLS: "true"
      # Registration is off upstream by default and this pins it off, so the
      # only account ever made is the first one, through the setup wizard.
      FEATURES_USER_REGISTRATION: "false"
      # Read the type off the file instead of believing the uploader, and serve
      # the two that execute in a browser as a download rather than inline.
      FILES_ASSUME_MIMETYPES: "true"
      FILES_DISABLED_TYPES: text/html,application/javascript
      FILES_DISABLED_TYPES_DEFAULT: application/octet-stream
    volumes:
      - /srv/zipline/uploads:/zipline/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8156.
      - "127.0.0.1:8156:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/zipline && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/zipline/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/zipline/compose.yml` and paste again in one go. Two services, one published port.
The uploaded files live on the host under /srv/zipline/uploads and everything else about them,
the owner, the short code, the view count, is a row in PostgreSQL, which is why step 8 takes two
artifacts rather than one. One thing to know before you go looking for these in the web
interface: the six settings under `DATABASE_URL` are pinned in this file rather than left to the
dashboard, and every start re-applies them, so changing one of those six in the web settings
will not survive a restart. Change them here and run `docker compose up -d`.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-zipline
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Zipline · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://zipline.diced.sh/docs/guides/reverse-proxy,
# https://caddyserver.com/docs/caddyfile/directives/request_body and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# the front of every share link this server hands out, so it is the value here
# worth choosing once and keeping.

<DOMAIN> {
	# Uploads are mostly already-compressed image and video formats, so there
	# is nothing to gain by compressing them again. These four headers are the
	# part worth having: a file host serves other people's bytes to strangers.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# Zipline's own default file size limit is 100 MB and it cuts anything
	# larger into 25 MB chunks, so 128 MB of request body covers both with room
	# to spare. Caddy answers 413 above this. Raise Zipline's limit and this
	# number together or the proxy will refuse what the app would have taken.
	request_body {
		max_size 128MB
	}

	# 8156 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8156
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-zipline /etc/caddy/Caddyfile`, reload,
and paste again. An error mentioning `request_body` means your Caddy predates that directive;
check `caddy version` before changing anything else. Caddy terminates TLS and speaks plain http
to the container, which is why `CORE_TRUST_PROXY` and `CORE_RETURN_HTTPS_URLS` are both true in
the compose file: without them Zipline treats every request as coming from 127.0.0.1 and hands
back `http://` links for a site that only answers on https.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8156` or `5432`.

If you do not: delete anything for `8156` or `5432` with `sudo ufw delete allow 8156`. 8156 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has no
host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer the
ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

Zipline runs its own database migrations on the way up, so the first start is the slow one.

```bash
cd /srv/zipline
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/healthcheck
curl -sS https://<DOMAIN>/api/setup
```

You should see, in order: the loop reaching `200`, then `{"pass":true}`, then
`{"firstSetup":true}`.

If you do not: `{"pass":true}` is the server and the database both answering, so a loop that
never reaches `200` is usually the database. Run `docker compose logs --tail 20 postgres` first,
then `docker compose logs --tail 40 zipline`. A `502` from Caddy where a `200` was expected
means the container is still working through migrations; wait and run the loop again. A
`{"firstSetup":false}` where you expected `true` means this instance already has an account, and
you should stop and find out whose before you go near the browser.

Now the part only you can do. Open https://<DOMAIN>/auth/setup in a browser. The heading reads
`Welcome to Zipline!`, above a stepper with a `Username` and a `Password` field. Create the first
account there. Then, still logged in, open Settings from the user menu at the top right, scroll
to `Generate Uploaders`, and download the `ShareX` config on Windows or the `Flameshot` script on
Linux and macOS. That download is the point of this whole install: it is what makes the
screenshot tool you already use put files on this server instead of somebody else's.

When both are done, come back to the terminal and prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/setup
curl -sS https://<DOMAIN>/api/server/public | grep -oE '"(userRegistration|firstSetup)":[a-z]+'
```

You should see: `403`, then `"userRegistration":false` and `"firstSetup":false`.

If you do not: a `200` on the first command means the wizard is still open and anyone who finds
the hostname can claim a superadmin account on your server. Stop and work out why the account
you made did not take. A `"userRegistration":true` means the compose file was edited or an older
one is still on disk; put the one from step 4 back and run `docker compose up -d`. Do not treat a
green `docker compose ps` as the finish line: a running container is not success.

## 8. First backup and restore

Two artifacts, and neither is worth anything alone. The database holds the accounts, the tokens,
the short links and one row per file. The archive holds the files themselves plus the three
configuration files that rebuild the service around them.

```bash
cd /srv/zipline
docker compose exec -T postgres pg_dump -U zipline -d zipline | gzip > /srv/zipline/backups/zipline-db-$(date +%F).sql.gz
sudo tar -czf /srv/zipline/backups/zipline-files-$(date +%F).tar.gz -C /srv/zipline compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/zipline/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error. Note
what the second archive will become: today it is kilobytes, a year from now it is every file you
have ever uploaded, so the nightly job you write later wants `rsync` on the uploads directory
rather than a tarball that doubles every month.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/zipline
scp vps:/srv/zipline/backups/* ~/backups/zipline/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/zipline/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a test upload:

```bash
cd /srv/zipline
docker compose down
sudo rm -rf /srv/zipline/postgres /srv/zipline/uploads
sudo install -d -m 700 /srv/zipline/postgres
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/zipline/uploads
sudo tar -xzf /srv/zipline/backups/zipline-files-$(date +%F).tar.gz -C /srv/zipline uploads
docker compose up -d postgres
sleep 30
gunzip -c /srv/zipline/backups/zipline-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U zipline -d zipline
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/healthcheck
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command, and
your account still logs in with the password you chose.

If you do not: `role "zipline" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand the stakes before you
skip this: every link you have pasted into a ticket or a chat points at this box, and a database
restored without its uploads directory answers all of them with a missing file.

## 9. Updating later

New versions are listed at https://github.com/diced/zipline/releases. Take both backup artifacts
first, then edit the `image:` line in /srv/zipline/compose.yml to the new tag and its digest.

```bash
cd /srv/zipline
docker compose pull
docker compose up -d
docker compose logs --tail 30 zipline
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one real file link as well,
because a service that answers `{"pass":true}` can still be failing to serve files if a migration
stopped halfway.

## 10. What will probably go wrong

You will open https://<DOMAIN> in a browser, see a screen reading `404` and `Page not found`, and
conclude Caddy is pointed at nothing. I did, and I spent ten minutes re-reading the site block.
It was fine: Zipline has no home page, the root path falls through to its own not-found screen,
and the only thing at the bare hostname is a `Go home` button back to the login page. The address
that tells the truth on a fresh install is https://<DOMAIN>/auth/setup. Check that, not the root.

## 11. Out of scope

- Do not configure SMTP. Zipline sends no mail at all, so there is nothing for it to do.
- Do not register an OAuth application with Discord, GitHub, Google or an OIDC provider. A
  password login with registration closed is the whole account model this install commits to.
- Do not switch the datasource to S3. Local storage under /srv/zipline/uploads is the choice
  here, and it is the one step 8 knows how to back up.
- Do not raise `FILES_MAX_FILE_SIZE` without raising `max_size` in the Caddy block by the same
  amount. Raise one and the other returns `413` on the uploads the app would have accepted.
