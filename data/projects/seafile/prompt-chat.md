This path is slower: you paste every command yourself, and there is nobody watching the output but
you. If you can run Claude Code, use the other tab.

You are installing Seafile Community Edition 13.0.25 on a VPS where Prompt Zero is done: `ssh vps`
works, Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points
at the box, and `<ADMIN_EMAIL>` with the address your one administrator account will be created
under.

Read this before step 1. `<DOMAIN>` becomes `SEAFILE_SERVER_HOSTNAME`, and Seahub rebuilds every
share link and every upload address out of it each time the container starts. Changing it later
means editing .env, the Caddy site block and every link you have already sent. Pick the hostname you
intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line. Those two floors are upstream's stated minimum for the community
edition, and the 10 GB is the install, not your files.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute, run
`dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not resolve,
and failed attempts count against a rate limit you cannot see. If RAM is under 2048 MB, stop and
resize the box rather than continuing: three containers on a 1 GB VPS get through the database
migrations and then meet the OOM killer during the first real upload, which looks like a random
failure and is not.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/seafile /srv/seafile/backups
sudo install -d -m 750 /srv/seafile/data
sudo install -d -m 700 /srv/seafile/mysql
ls -la /srv/seafile
```

You should see: `backups` owned by you, `data` at mode `drwxr-x---` and `mysql` at `drwx------`,
both owned by root.

If you do not: leave `data` and `mysql` owned by root on purpose. The Seafile container runs as root
and fills `data` with `conf`, `seafile-data`, `seahub-data` and `logs` the first time it starts, and
the MariaDB image chowns `mysql` to its own uid. One you have already chowned to yourself makes
MariaDB refuse to initialise. You will need `sudo ls` to look inside either of them afterwards.

## 3. Secrets

Five secrets, all generated here on the server, all straight into a file only you can read. Hex
rather than base64: two of them travel inside database connection strings and one gets typed into a
login form.

```bash
umask 077
cat > /srv/seafile/.env <<EOF
SEAFILE_SERVER_HOSTNAME=<DOMAIN>
INIT_SEAFILE_ADMIN_EMAIL=<ADMIN_EMAIL>
TIME_ZONE=Etc/UTC
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
SEAFILE_MYSQL_DB_PASSWORD=$(openssl rand -hex 32)
JWT_PRIVATE_KEY=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
INIT_SEAFILE_ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/seafile/.env
umask 022
ls -l /srv/seafile/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` and
`<ADMIN_EMAIL>` on the first two lines with your real values before you paste.

Do not paste that file, any of those five values, or any command output containing them into this
chat window. The agent path never sees them; this path will hand them to a third party unless you
keep them out.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/seafile/.env` and carry on. If
the file already existed from an earlier attempt, this block has now overwritten all five, which is
fine before the containers exist and a problem afterwards: MariaDB keeps the passwords it was
created with, so changed values against an existing `mysql` directory produce an access-denied loop
in the seafile log rather than anything about passwords.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/seafile/compose.yml <<'EOF'
# Seafile Community Edition · the deterministic fallback. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://manual.seafile.com/13.0/setup/setup_ce_by_docker/
#   variable reference . https://manual.seafile.com/13.0/config/env/
#   reverse proxy ...... https://manual.seafile.com/13.0/setup/use_other_reverse_proxy/
#
# Three services. Upstream's own deployment starts five, adding a Caddy and the
# SeaDoc editor; this box already runs Caddy, and ENABLE_SEADOC false is
# upstream's documented way to drop the editor. SEAFILE_SERVER_PROTOCOL is https
# because Caddy terminates TLS here: Seahub rebuilds SERVICE_URL and
# FILE_SERVER_ROOT from it at every start, so http would put an http upload
# address on an https page. Only 8140 is published, on loopback. Digests read
# 2026-08-06; all three publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:10.11.18@sha256:de61fed4a40d3842f3ee09944ba52792156cfd9adf489b2cc670fc6ded28df8d
    container_name: seafile-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/seafile/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      start_period: 30s
      timeout: 5s
      retries: 10
    # No `ports:` at all: 3306 only exists on the compose network.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: seafile-redis
    restart: unless-stopped
    # A password, which upstream leaves off; $$ defers expansion to the container.
    command:
      - /bin/sh
      - -c
      - exec redis-server --requirepass "$$REDIS_PASSWORD" --save "" --appendonly no
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    # No `ports:` at all: 6379 never leaves the compose network.

  seafile:
    image: seafileltd/seafile-mc:13.0.25@sha256:90c1aaa08731116750cd7ce16cbc6afe0c26006433002d3c7215a5f4254ec244
    container_name: seafile
    restart: unless-stopped
    volumes:
      - /srv/seafile/data:/shared
    environment:
      SEAFILE_MYSQL_DB_HOST: db
      SEAFILE_MYSQL_DB_USER: seafile
      SEAFILE_MYSQL_DB_PASSWORD: ${SEAFILE_MYSQL_DB_PASSWORD}
      INIT_SEAFILE_MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      SEAFILE_MYSQL_DB_CCNET_DB_NAME: ccnet_db
      SEAFILE_MYSQL_DB_SEAFILE_DB_NAME: seafile_db
      SEAFILE_MYSQL_DB_SEAHUB_DB_NAME: seahub_db
      # Redis, because Seafile 13 stopped shipping memcached in Docker.
      CACHE_PROVIDER: redis
      REDIS_HOST: redis
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      JWT_PRIVATE_KEY: ${JWT_PRIVATE_KEY}
      SEAFILE_SERVER_HOSTNAME: ${SEAFILE_SERVER_HOSTNAME}
      SEAFILE_SERVER_PROTOCOL: https
      TIME_ZONE: ${TIME_ZONE}
      # Read on the first start only, to create the one account there is.
      INIT_SEAFILE_ADMIN_EMAIL: ${INIT_SEAFILE_ADMIN_EMAIL}
      INIT_SEAFILE_ADMIN_PASSWORD: ${INIT_SEAFILE_ADMIN_PASSWORD}
      # Upstream's editor extension, which would need a container of its own.
      ENABLE_SEADOC: "false"
    ports:
      - "127.0.0.1:8140:80"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
EOF
cd /srv/seafile && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and your
terminal. Run `rm /srv/seafile/compose.yml` and paste again in one go. A message naming a variable as
not set means step 3 did not write `.env`, or you are not in `/srv/seafile`: compose reads that file
only from the directory it runs in.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error here
takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-seafile
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Seafile · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://manual.seafile.com/13.0/setup/use_other_reverse_proxy/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. It is also
# SEAFILE_SERVER_HOSTNAME in .env, so the two stay the same string.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# No `encode`: these bytes are stored file blocks on /seafhttp.
	# Upstream's nginx sample drops the body limit, the request buffering
	# and the read timeout here; Caddy already streams and caps nothing
	# unless told to, so do not add `request_body max_size`.
	#
	# 8140 is the loopback port compose publishes, not a container port,
	# and not open in the firewall.
	reverse_proxy 127.0.0.1:8140
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-seafile /etc/caddy/Caddyfile`, reload, and
paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the other.
Caddy requests the certificate on the first request to the hostname and renews it on its own, so
there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8140`, `3306` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8140`. 8140 is bound to
127.0.0.1 by the compose file, and the database and the cache publish no host port at all, so there
is nothing a firewall rule could apply to. The desktop and mobile clients do not need another port
either: their uploads and downloads ride /seafhttp on the same hostname and the same 443. `Status:
inactive` is a different problem, because Prompt Zero left this firewall enabled, so something has
turned it off since; `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

First boot initialises MariaDB, creates the three databases, runs every migration and creates the
one account. On a small server that takes minutes and prints nothing for long stretches, which is
normal.

```bash
cd /srv/seafile
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api2/ping/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api2/ping/
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api2/auth/ping/
docker compose exec -T seafile printenv SEAFILE_VERSION SEAFILE_SERVER_PROTOCOL
curl -sSL https://<DOMAIN>/accounts/login/ | grep -o '<h1 class="login-panel-hd">[^<]*</h1>'
```

You should see, in order: the loop reaching `200`, then `"pong"`, then `401`, then two lines reading
`13.0.25` and `https`, then `<h1 class="login-panel-hd">Log In</h1>`.

If you do not: the `401` is the one worth understanding. It means the API is up and refusing a call
that carries no token, which is exactly right, so seeing it is good news. A `502` in its place means
Caddy is reaching nothing on 8140: check `docker compose ps`. If the loop never reaches `200`, run
`docker compose logs --tail 20 db` first, because a database that never reports healthy is step 2
done wrong, then `docker compose logs --tail 60 seafile`. Seahub's own log is at
/srv/seafile/data/seafile/logs/seahub.log and needs `sudo` to read. A green `docker compose ps` is
not success on its own.

Nobody else can sign up: upstream ships `ENABLE_SIGNUP` off, so the account created from
`INIT_SEAFILE_ADMIN_EMAIL` is the only way in.

Now read your password and use it, once:

```bash
grep INIT_SEAFILE_ADMIN_PASSWORD /srv/seafile/.env
```

You should see: one line. Put the value in your password manager now, and do not paste that line
here. Then open https://<DOMAIN> in a browser, sign in as `<ADMIN_EMAIL>` with that password, create
a library, and upload one file to it.

If you do not: that upload is the check that matters. The web interface loads fine even when the
file server behind /seafhttp is unreachable, so a library page that appears and an upload that
stalls at 0% is the failure mode this step exists to catch. If it stalls, go to step 10 before
changing anything.

## 8. First backup and restore

Two artifacts. The dump holds the three databases plus the database user Seafile connects as; the
archive holds the file blocks, the configuration the container generated, and the files that rebuild
the service around them.

```bash
cd /srv/seafile
docker compose exec -T db sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb-dump -uroot --opt --all-databases' | gzip > /srv/seafile/backups/seafile-db-$(date +%F).sql.gz
sudo tar -czf /srv/seafile/backups/seafile-files-$(date +%F).tar.gz -C /srv/seafile data compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/seafile/backups/
```

You should see: two files, the dump a few hundred kilobytes and the archive a little larger on a
fresh install. Nothing goes offline: `mariadb-dump` locks each table only while it reads it, and the
root password is expanded by the shell inside the container, so it never appears in this machine's
process list.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error. `tar:
Permission denied` means you dropped the `sudo`: the container wrote most of `data` as root.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/seafile
scp vps:/srv/seafile/backups/* ~/backups/seafile/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/seafile/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix only
means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one test file:

```bash
cd /srv/seafile
docker compose down
sudo rm -rf /srv/seafile/data /srv/seafile/mysql
sudo install -d -m 750 /srv/seafile/data
sudo install -d -m 700 /srv/seafile/mysql
sudo tar -xzf /srv/seafile/backups/seafile-files-$(date +%F).tar.gz -C /srv/seafile data
docker compose up -d db
sleep 60
gunzip -c /srv/seafile/backups/seafile-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb -uroot'
docker compose restart db
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/api2/ping/
```

You should see: no output from the import, then `"pong"`. Sign in again and confirm your test file
is still in its library. That is the whole disaster plan, proved.

If you do not: `Access denied for user 'seafile'` means the database came back without its user, so
the dump was taken without `--all-databases`. That flag is not decoration: it carries the `seafile`
MySQL account and its grants, and a restore without them gives you a database Seafile cannot log in
to. Understand what is at stake before you skip this. Seafile splits every file into deduplicated
blocks under `data/seafile/seafile-data` and keeps the filenames and library structure in the
database, so restoring one without the other leaves you blocks with no names or names with no
blocks.

## 9. Updating later

Image tags are listed at https://hub.docker.com/r/seafileltd/seafile-mc/tags. Take both backup
artifacts first, then edit the `image:` line in /srv/seafile/compose.yml to the new tag and its
digest.

```bash
cd /srv/seafile
docker compose pull
docker compose up -d
docker compose logs --tail 40 seafile
```

You should see: schema upgrade output, then the server starting, and no container restarting in a
loop.

If you do not: put the old tag and digest back and run the same three commands. The upgrade can take
several minutes on a large library, so give it time before deciding it hung. Then re-run the
`/api2/ping/` and `printenv` checks from step 7 and confirm the version matches the tag you pinned.
Do not skip a major version; upstream writes its upgrade notes one major at a time.

## 10. What will probably go wrong

An upload that fails silently, looking like a broken file server rather than a configuration
mistake. Seahub does not read the protocol off the request: it builds SERVICE_URL and
FILE_SERVER_ROOT at container start from `SEAFILE_SERVER_PROTOCOL` and `SEAFILE_SERVER_HOSTNAME`, so
if either is wrong the login page loads, the library list loads, and then the browser is handed an
upload address on the wrong scheme or host and refuses it. I lost twenty minutes reading file server
logs that had nothing in them, because nothing ever reached the file server. That is why step 7
prints those two values. If uploads fail later, check them first.

## 11. Out of scope

- Do not add the SeaDoc editor or set `ENABLE_SEADOC` to true. It is a second container on a second
  route, and this install gives you the file server it would plug into.
- Do not configure SMTP. Seafile works without it; the cost is invitation and password-reset mail,
  and you can create accounts by hand in the admin panel instead.
- Do not enable the notification server or the metadata server. Each is another upstream extension
  container, and neither is needed to store and sync files.
- Do not switch the image to seafile-pro-mc. That edition needs a licence file and brings
  Elasticsearch with it, a different install on a bigger box.
