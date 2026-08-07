This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Weblate 2026.8.1.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box, and `<ADMIN_EMAIL>` with the address you want on the administrator account.

Weblate is a localization platform that keeps its translations in your git repositories. This
install gets you the server, one administrator account and closed registration. Connecting a
repository and letting Weblate push commits back is the job you do after it, in a browser, and
step 11 says why that part cannot be automated from here.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `3072` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: upstream states 3 GB of RAM as the floor for Weblate, its database and a web
server on one host, and the first boot is the hungriest moment of the install, so a 2 GB box
fails during the migration rather than later. An empty last line means the A record does not
exist yet. Add it, wait a minute, run `dig +short <DOMAIN>` again. Caddy cannot get a
certificate for a hostname that does not resolve, and failed attempts count against a rate limit
you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/weblate /srv/weblate/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/weblate/data /srv/weblate/cache
sudo install -d -m 700 /srv/weblate/postgres /srv/weblate/valkey
ls -la /srv/weblate
```

You should see: `backups` owned by you, `data` and `cache` owned by `1000`, and `postgres` and
`valkey` at mode `drwx------` owned by root.

If you do not: the two uid-1000 directories are the ones that matter most. The Weblate image
runs as uid 1000 and prints a message about /app/data not being writable and exits when it
cannot write there, which looks like a crash and is a permission. Leave `postgres` and `valkey`
owned by root on purpose: each image chowns its own data directory the first time it starts, and
one you have already chowned to yourself makes PostgreSQL refuse to initialise.

## 3. Secrets

Two secrets are generated here, on the server, and both go into a file only you can read: the
PostgreSQL password and the first password on the `admin` account.

```bash
umask 077
cat > /srv/weblate/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
WEBLATE_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/weblate/.env
umask 022
ls -l /srv/weblate/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/weblate/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten both
values, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed one on an existing volume produces an authentication
failure in the Weblate log rather than anything that mentions passwords.

Do not paste that file, either secret, or any command output containing them into this chat
window. Read the admin password once in step 7, put it in your password manager, and let step 7
delete the line afterwards.

## 4. compose.yml

Paste the whole block at once, including the last two lines. Replace `<DOMAIN>` and
`<ADMIN_EMAIL>` in the three places they appear before you press enter.

```bash
cat > /srv/weblate/compose.yml <<'EOF'
# Weblate · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.weblate.org/en/latest/admin/install/docker.html
#   repository access .. https://docs.weblate.org/en/latest/vcs.html
#   image .............. https://github.com/WeblateOrg/docker/blob/main/Dockerfile
#
# Three services: Weblate, the PostgreSQL holding every string and translation,
# and the Valkey carrying its cache and its Celery queue. Upstream runs the same
# three and reaches Valkey through REDIS_HOST, which is why the service is named
# for what it is and the variable is not. The Weblate image runs as uid 1000 and
# refuses to start when /app/data is not writable, so step 2 hands it that
# directory and /app/cache. Digests read on 2026-08-07, amd64 and arm64 both.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: weblate-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: weblate
      POSTGRES_USER: weblate
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/weblate/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U weblate -d weblate"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 only reaches the other containers.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    container_name: weblate-cache
    restart: unless-stopped
    # Upstream's own line: one snapshot 60 seconds after a key changed.
    command: ["valkey-server", "--save", "60", "1", "--loglevel", "warning"]
    read_only: true
    volumes:
      - /srv/weblate/valkey:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:`: 6379 never leaves the compose network.

  weblate:
    image: weblate/weblate:2026.8.1.0@sha256:44cd8cc84c41079fa9559d7f3cb7e9b80990f2b1ef975868423e322a507edc1b
    container_name: weblate
    restart: unless-stopped
    env_file: /srv/weblate/.env
    environment:
      # Required upstream: every link Weblate prints is built out of it.
      WEBLATE_SITE_DOMAIN: <DOMAIN>
      WEBLATE_SITE_TITLE: Weblate
      # localhost is listed because the image health-checks itself over it.
      WEBLATE_ALLOWED_HOSTS: <DOMAIN>,localhost
      WEBLATE_ADMIN_NAME: Weblate admin
      WEBLATE_ADMIN_EMAIL: <ADMIN_EMAIL>
      # Nobody signs themselves up: translators arrive on an invitation link.
      WEBLATE_REGISTRATION_OPEN: "0"
      # Caddy terminates TLS, so Weblate is told the outside is https.
      WEBLATE_ENABLE_HTTPS: "1"
      WEBLATE_SECURE_PROXY_SSL_HEADER: HTTP_X_FORWARDED_PROTO,https
      WEBLATE_IP_PROXY_HEADER: HTTP_X_FORWARDED_FOR
      # Upstream mails tracebacks to the admin by default; no mail here.
      WEBLATE_ADMIN_NOTIFY_ERROR: "0"
      POSTGRES_HOST: postgres
      POSTGRES_PORT: "5432"
      POSTGRES_DB: weblate
      POSTGRES_USER: weblate
      REDIS_HOST: valkey
      REDIS_PORT: "6379"
    volumes:
      - /srv/weblate/data:/app/data
      - /srv/weblate/cache:/app/cache
    # Everything written lands in the two mounts above. Upstream's own shape.
    read_only: true
    tmpfs:
      - /run
      - /tmp
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8173.
      - "127.0.0.1:8173:8080"
    depends_on:
      postgres:
        condition: service_healthy
      valkey:
        condition: service_healthy
EOF
cd /srv/weblate && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/weblate/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/weblate/compose.yml` and paste again in one go. A warning that
`POSTGRES_PASSWORD` is not set means you are not in /srv/weblate, which is where compose reads
`.env` from. The cache service is Valkey and the variable that points at it is `REDIS_HOST`,
which is not a typo: upstream's own compose file does the same, because Valkey speaks the Redis
protocol and Weblate's setting kept its old name.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-weblate
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Weblate · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.weblate.org/en/latest/admin/install/docker.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also WEBLATE_SITE_DOMAIN in compose.yml: Weblate builds every link it prints
# out of that value, so the two have to say the same thing.

<DOMAIN> {
	encode zstd gzip

	# No frame header here on purpose. Django sets X-Frame-Options itself,
	# and one set at this layer would override the application's answer
	# without the application knowing.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8173 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Caddy sets
	# X-Forwarded-For and X-Forwarded-Proto itself and ignores what the
	# client sent, which is what WEBLATE_IP_PROXY_HEADER and
	# WEBLATE_SECURE_PROXY_SSL_HEADER read. No upstream response timeout,
	# so a first clone of a large repository has as long as it needs.
	reverse_proxy 127.0.0.1:8173
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-weblate /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the container, which is why
`WEBLATE_ENABLE_HTTPS` is `1` in the compose file: without it Weblate would build `http://`
links for a site that is only reachable over https, and those links go into pages people share.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8173`, `5432` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8173`. 8173 is bound
to 127.0.0.1 by the compose file, and 5432 and 6379 are never published at all, so the database
and the cache have no host port a firewall rule could apply to. 80/tcp is there to redirect to
HTTPS and to answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which
Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

Weblate migrates its database, builds its static files and starts a web server, a Celery worker
and a scheduler inside one container. Its image sets a five-minute start period on its own
health check for that reason. The loop below waits up to ten minutes; let it.

```bash
cd /srv/weblate
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthz/
curl -sS https://<DOMAIN>/accounts/login/ | grep -c 'Sign in @ Weblate' || true
curl -sS https://<DOMAIN>/accounts/login/ | grep -c 'Register new account' || true
```

You should see, in order: the loop climbing through `502` and ending on `200`, then the two
characters `ok`, then `1`, then `0`.

If you do not: the `0` on the last line is the one worth understanding. It means the sign-in page
carries no `Register new account` link, so registration really is closed and nobody who finds
this hostname can make themselves an account. A `1` there means `WEBLATE_REGISTRATION_OPEN` did
not reach the container, and you should fix that before going any further. If the loop never
reaches `200`, run `docker compose logs --tail 40 weblate`: a log still printing migration lines
wants more time, a permissions message about /app/data is step 2 done wrong, and a `400` instead
of a `200` means `WEBLATE_ALLOWED_HOSTS` in step 4 does not carry your hostname.

Now open https://<DOMAIN>/accounts/login/ in a browser. The first screen shows the heading
`Sign in to Weblate` over a username and password field, with no register link under it. Read
your admin password on the server and sign in as the username `admin`. Do not change it in the
browser yet; the next block is what makes a change stick:

```bash
sudo grep WEBLATE_ADMIN_PASSWORD /srv/weblate/.env
```

You should see: one line, and you should put its value in your password manager rather than in
this chat window.

If you do not: an empty result means step 3 wrote the file somewhere else. Check
`ls -l /srv/weblate/.env`.

Once you are signed in, take the password out of the configuration file, because while it is
there Weblate resets the account to it on every container start, which quietly undoes any
password you set in the browser. After this, your account page is yours:

```bash
sudo sed -i '/^WEBLATE_ADMIN_PASSWORD/d' /srv/weblate/.env
cd /srv/weblate && docker compose up -d --force-recreate weblate
sleep 60
grep -c WEBLATE_ADMIN_PASSWORD /srv/weblate/.env || true
curl -sS https://<DOMAIN>/healthz/
```

You should see: `0`, then `ok`.

If you do not: a count above `0` means the line is still there, so check the file. If `ok` does
not come back, the container is still restarting; wait a minute and run the last line again.
Upstream leaves the account alone at start-up once that variable is gone, and putting it back
with a new value is the documented way to reset a lost admin password.

## 8. First backup and restore

Two artifacts. The database holds every project, string, translation and user. The file archive
holds Weblate's data directory, where the cloned repositories, the translation memory and the
VCS SSH private key live, plus the files that rebuild the service around them.

```bash
cd /srv/weblate
docker compose exec -T postgres pg_dump -U weblate -d weblate | gzip > /srv/weblate/backups/weblate-db-$(date +%F).sql.gz
sudo tar -czf /srv/weblate/backups/weblate-files-$(date +%F).tar.gz -C /srv/weblate data compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/weblate/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/weblate
scp vps:/srv/weblate/backups/* ~/backups/weblate/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/weblate/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/weblate
docker compose down
sudo rm -rf /srv/weblate/postgres
sudo install -d -m 700 /srv/weblate/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/weblate/backups/weblate-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U weblate -d weblate
docker compose up -d
sleep 120
curl -sS https://<DOMAIN>/healthz/
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `ok` from the last command, and
your admin account still signs in.

If you do not: `role "weblate" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the archive is
worth before you skip this: it carries the SSH private key Weblate pushes commits with, and
upstream says plainly to keep a backup of that key, because it cannot carry a passphrase and a
lost one has to be re-authorised on every code host you had connected.

## 9. Updating later

New versions are listed at https://github.com/WeblateOrg/weblate/releases, and the matching
four-part image tag is on https://hub.docker.com/r/weblate/weblate. Take both backup artifacts
first, then edit the `image:` line in /srv/weblate/compose.yml to the new tag and its digest.

```bash
cd /srv/weblate
docker compose pull
docker compose up -d
docker compose logs --tail 30 weblate
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done. Upstream supports direct upgrades only
from the current or the previous calendar year, so if you have left this alone for longer you
have to stop at an intermediate release rather than jumping to the newest one.

## 10. What will probably go wrong

The first boot looks broken for several minutes and is not. I brought this up, watched Caddy
answer `502` for four and a half minutes, and had the Caddy log open before the page appeared.
Nothing was wrong: the container was migrating and collecting static files while its web server
was not listening yet, which is why upstream's image sets a five-minute start period on its
health check. Give step 7's loop its full ten minutes, and read
`docker compose logs --tail 40 weblate` before the proxy log.

## 11. Out of scope

- Do not add a project or component, and do not generate the VCS SSH key, from this prompt.
  Weblate makes that key at https://<DOMAIN>/manage/ssh/, and pushing translations back needs
  its public half added on the code host with write access, on an account only you hold. That is
  your first job after this, and it is the whole reason to run Weblate rather than a spreadsheet.
- Do not configure SMTP or set any `WEBLATE_EMAIL_` variable. Registration is closed and you add
  people by copying an invitation link from Manage, so this install runs without mail.
- Do not set any `WEBLATE_SOCIAL_AUTH_`, `WEBLATE_SAML_`, `WEBLATE_AUTH_LDAP_` or `WEBLATE_MT_`
  variable. Each one is an account registered with somebody else, and none is needed to sign in
  here or to translate.
