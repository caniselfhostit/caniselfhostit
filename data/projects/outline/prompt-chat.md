This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Outline 1.9.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Two things to settle before step 1. `<DOMAIN>` becomes `URL`, and Outline builds every sign-in
link it mails, every share link and every passkey origin out of it, so changing it later breaks
all three for people already holding them. And Outline has no password login at all: the first
workspace is claimed on a form the server offers only while no workspace exists, and after that
the way back in is a link mailed to you. Step 3 will ask for the host, port, username and password
of an SMTP relay and the address outgoing mail should come from. Have them in front of you.

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
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a name that does not resolve,
and failed attempts count against a rate limit you cannot see. Under 2048 MB is the one to take
seriously: three services share this box, and the one the kernel kills when memory runs out is
usually PostgreSQL, which looks like a database bug and is not.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/outline /srv/outline/backups
sudo install -d -m 700 /srv/outline/postgres /srv/outline/redis
sudo install -d -m 750 -o 1001 -g 1001 /srv/outline/data
ls -la /srv/outline
```

You should see: four directories. `backups` owned by you, `postgres` and `redis` at `drwx------`
owned by root, and `data` owned by `1001`.

If you do not: the odd owner on `data` is deliberate. The Outline image runs as the non-root user
1001 and declares /var/lib/outline/data as a volume, so if that directory belongs to anyone else
the app starts, serves pages, and fails every attachment upload with nothing obvious in the log.
PostgreSQL and Redis chown their own directories on first start, which is why those two are left
to root.

## 3. Secrets

Three secrets, generated on the server: the key that encrypts stored data, the utility secret,
and the PostgreSQL password. Hex for all three, because upstream requires `SECRET_KEY` to be
exactly 64 hexadecimal characters.

Do not paste the contents of this file, or any command output containing one of these values,
back into this chat window. Nothing on this path needs you to, and a secret pasted into a chat
box is a secret held by a third party.

```bash
umask 077
cat > /srv/outline/.env <<EOF
URL=https://<DOMAIN>
SECRET_KEY=$(openssl rand -hex 32)
UTILS_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
SMTP_HOST=CHANGE_ME
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USERNAME=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
SMTP_FROM_EMAIL=CHANGE_ME
EOF
chmod 600 /srv/outline/.env
umask 022
ls -l /srv/outline/.env
```

You should see: `-rw------- 1 you you` and the path.

If you do not: any group or world bit means `umask 077` did not take. Run
`chmod 600 /srv/outline/.env` and check again before going further.

Now fill in the mail settings. Open the file with `nano /srv/outline/.env`, replace each
`CHANGE_ME` with the value from your provider, and if your relay wants port 465 rather than 587,
change `SMTP_PORT` to 465 and `SMTP_SECURE` to true. Save with Ctrl-O, Enter, Ctrl-X. Then:

```bash
awk '/CHANGE_ME/ {n++} END {print n+0}' /srv/outline/.env
```

You should see: `0`. That command counts lines, it never prints a value.

If you do not: a number above zero means an unedited line is still there, and Outline validates
its environment at start-up and exits when it reads a mailbox address it cannot parse. Fix the
file before step 7 or the container will not boot.

One line in that file matters more than the rest. `SECRET_KEY` encrypts stored data, and upstream
states that changing it later leaves users unable to log in. It has to survive every restore.

## 4. compose.yml

```bash
cat > /srv/outline/compose.yml <<'EOF'
# Outline · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation and source, not copied from a repository:
#   docker hosting ..... https://docs.getoutline.com/s/hosting/doc/docker-7pfeLP5a8t
#   variables and smtp . https://github.com/outline/outline/blob/v1.9.2/.env.sample
#   image .............. https://github.com/outline/outline/blob/v1.9.2/Dockerfile
#
# Three services: Outline, the PostgreSQL holding every document and revision,
# and the Redis carrying the collaborative editor, the job queue and the rate
# limiter. Upstream calls URL, DATABASE_URL, REDIS_URL and SECRET_KEY the
# minimum. Four settings below are not defaults and each breaks something if
# left out. FILE_STORAGE defaults to s3, so uploads fail until it says local.
# PGSSLMODE must say disable: Outline turns on SSL to Postgres in production
# and this Postgres speaks plain TCP. WEB_CONCURRENCY pins one web process,
# upstream's rule being memory divided by 512. ENABLE_UPDATES is false, its
# default posting a hashed install id and the user, team, collection and
# document counts to updates.getoutline.com daily.
#
# The image runs as uid 1001 and declares /var/lib/outline/data a VOLUME.
# Digests read on 2026-08-14; all three images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.6-alpine@sha256:432b3b824c0769275ec9b0947736ef8b376d6997bcaa9de29818f613819c2feb
    container_name: outline-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: outline
      POSTGRES_USER: outline
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/outline/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U outline -d outline"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: outline-redis
    restart: unless-stopped
    # appendonly writes every change to disk, and noeviction makes Redis refuse
    # writes rather than silently drop a queued job when memory runs out.
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - /srv/outline/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 6379 never leaves the compose network.

  outline:
    image: outlinewiki/outline:1.9.2@sha256:32d76719c378931dd65d93945930ca380d8376a0337d98a991fcc12b266f33cf
    container_name: outline
    restart: unless-stopped
    env_file: /srv/outline/.env
    environment:
      DATABASE_URL: postgres://outline:${DB_PASSWORD}@postgres:5432/outline
      PGSSLMODE: disable
      REDIS_URL: redis://redis:6379
      FILE_STORAGE: local
      WEB_CONCURRENCY: "1"
      ENABLE_UPDATES: "false"
    volumes:
      # Attachments, avatars and imports, in the path the image calls a VOLUME.
      - /srv/outline/data:/var/lib/outline/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8185.
      - "127.0.0.1:8185:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
cd /srv/outline && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK`.

If you do not: `docker compose config` prints the line it choked on. The usual cause is a heredoc
that ended early because you pasted in two pieces, so open the file and check the last line is
`condition: service_healthy`. Outline runs its own migrations on the way up, so there is nothing
extra to schedule.

## 5. Caddy and TLS

Copy the Caddyfile before you touch it. A syntax error here takes down every other site on the
box, not only this one. In the block below, replace every `<DOMAIN>` with your real hostname
before you paste it, the site label included.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-outline
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Outline · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.getoutline.com/s/hosting/doc/docker-7pfeLP5a8t and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also URL in .env, and Outline builds
# every mailed sign-in link and share link out of it, so the two must agree.

<DOMAIN> {
	encode zstd gzip

	# No X-Frame-Options or CSP here: Outline sets both itself, per route.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8185 is the loopback port compose publishes, never open in the firewall.
	# The editor rides WebSockets on it, which Caddy upgrades unasked, and
	# Caddy's X-Forwarded-Proto is what lets Outline's FORCE_HTTPS settle.
	reverse_proxy 127.0.0.1:8185
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from the reload.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-outline /etc/caddy/Caddyfile`, reload, and read what
validate objected to. A literal `<DOMAIN>` left in the site label is the common one. Caddy
requests the certificate on the first request to the hostname and renews it with nothing for you
to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 80/tcp, 443/tcp and 443/udp. Nothing for 8185,
nothing for 5432, nothing for 6379.

If you do not: a rule for 8185 from an earlier attempt is worth removing with
`sudo ufw delete allow 8185`. That port is bound to 127.0.0.1 in compose, so opening it in the
firewall does nothing useful and states the opposite of what is true. 80 answers the ACME
challenge and redirects, 443/tcp carries everything, 443/udp is HTTP/3.

## 7. Start and verify

Read this before you run it. While no workspace exists, the server offers a form headed
`Create workspace` to anybody who loads the page, and whoever fills it in first becomes its
admin. The window opens the moment the container answers and closes the moment you claim it, so
plan to do the browser step immediately, not after lunch.

```bash
cd /srv/outline
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/_health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/_health; echo
curl -sS -H 'content-type: application/json' -d '{}' https://<DOMAIN>/api/auth.config; echo
```

You should see: the loop counting up and ending on `200`, then `OK`, then
`{"data":{"providers":[]},"status":200,"ok":true}`. The first start runs the migrations, so
several `502` lines before the `200` are normal.

If you do not: run `docker compose logs --tail 40 outline`. A container that exits with
`Environment configuration is invalid` is step 3, usually a `CHANGE_ME` still in .env. A line
saying the database does not support SSL means `PGSSLMODE` never reached the container, so check
step 4. A `502` that never becomes `200` after ten minutes, with a healthy container, is Caddy
pointing somewhere other than 8185. A running container is not success.

Now open https://<DOMAIN> in a browser. You get a page headed `Create workspace` with three
fields: workspace name, admin name, admin email. Fill them in and continue. You land inside the
wiki, signed in, as the admin of a workspace that did not exist a second ago.

Come back to the terminal and prove the door is shut:

```bash
curl -sS -H 'content-type: application/json' -d '{}' https://<DOMAIN>/api/auth.config; echo
curl -sS -o /dev/null -w '%{http_code}\n' -H 'content-type: application/json' -d '{}' https://<DOMAIN>/api/documents.list
curl -sS -H 'content-type: application/json' -d '{"teamName":"closed","userName":"closed","userEmail":"closed@example.com"}' https://<DOMAIN>/api/installation.create; echo
```

You should see: your workspace name in the first response, alongside a provider whose `"id"` is
`"email"`; then `401`; then a body containing `Installation already has existing teams`.

If you do not: a first response whose `providers` list is still empty means the workspace form was
never submitted, and the install is unclaimed by anyone. A first response with your
workspace name but no `"email"` provider means the SMTP settings in .env are not loaded, so there
is no way to sign in once this browser session ends: fix step 3 and run
`docker compose up -d --force-recreate outline`. Anything other than
`Installation already has existing teams` on the last call, stop and work out why before you put a
document in this wiki. That refusal is the closure, and it is the whole security story of this
install.

Last, test the mail path, because it is the only way back in. Sign out. Enter your email on the
sign-in page. A link arrives; open it; you should be back inside. If nothing arrives, run
`docker compose logs --tail 40 outline` and read the SMTP error: the usual answers are a relay
that wants port 465 with `SMTP_SECURE=true`, or a from-address the provider has never verified.
While you are in there, add a passkey under Settings, Security. It is a second way in that does
not depend on mail at all.

## 8. First backup and restore

Two artifacts. The dump holds every document, revision, comment and account. The archive holds
the attachments and the three files that rebuild the service around them.

```bash
cd /srv/outline
docker compose exec -T postgres pg_dump -U outline -d outline | gzip > /srv/outline/backups/outline-db-$(date +%F).sql.gz
sudo tar -czf /srv/outline/backups/outline-files-$(date +%F).tar.gz -C /srv/outline compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/outline/backups/
```

You should see: two files, both with a size in KB or MB rather than zero.

If you do not: a `.sql.gz` of a few dozen bytes is an empty dump, usually because `pg_dump` could
not authenticate. Re-run it and read its stderr rather than trusting the file. Nothing is stopped
during this, because `pg_dump` snapshots a running database consistently.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/outline
scp vps:/srv/outline/backups/* ~/backups/outline/
```

To restore, on the server: `cd /srv/outline`, `docker compose down`,
`sudo rm -rf /srv/outline/postgres /srv/outline/data`, recreate both directories exactly as in
step 2, untar the file archive with `sudo tar -xzf` into /srv/outline so that `.env` and the 1001
owner on `data` are in place before anything starts,
`docker compose up -d postgres`, wait until `docker compose ps` shows it healthy, then
`gunzip -c backups/outline-db-<date>.sql.gz | docker compose exec -T postgres psql -U outline -d outline`,
and finish with `docker compose up -d`. The two artifacts travel together: `SECRET_KEY` in `.env`
is what decrypts the encrypted columns in that dump, so a database restored beside a freshly
generated key is a wiki nobody can sign in to.

## 9. Updating later

New versions are listed at https://github.com/outline/outline/releases. The release tag `v1.9.2`
and the image tag `1.9.2` are the same number. This install pins the newest stable line rather
than the `nightly` tag the registry also carries, which is built from the day's commits and is
not a version you can go back to. Take both backup artifacts first, then edit the `image:` line in
/srv/outline/compose.yml to the new tag and its digest, and run:

```bash
cd /srv/outline
docker compose pull
docker compose up -d
docker compose logs --tail 40 outline
```

Outline migrates its own schema on the way up. Watch that log until it settles, then repeat the
`/_health` and `auth.config` checks from step 7 before you call the update done.

## 10. What will probably go wrong

Mail. I had a relay that accepted the connection and then refused the message, and because
Outline answers the sign-in form with the same screen either way, deliberately, so nobody can use
it to learn which addresses have accounts, nothing on the page told me. The install looked
finished, and it was one browser session from being a wiki I could not get into, since there is
no password and no reset link that does not itself arrive by mail. That is why step 7 has you
sign out and sign back in before the install is done. The usual causes are a relay wanting port
465 with `SMTP_SECURE=true`, or a sender address the provider never verified.

## 11. Out of scope

- Do not configure Google, Slack, Microsoft, Discord or generic OIDC sign-in. Each is an app
  registered with somebody else, and this install needs none of them.
- Do not set `FILE_STORAGE=s3` or any `AWS_` variable. Attachments live in /srv/outline/data,
  which keeps the backup at two files and no bucket policy.
- Do not run the `outlinewiki/outline-enterprise` image, which is the paid edition.
- Do not enable the Notion, GitHub, Linear or Figma integrations. Each is a separate developer
  application with its own client secret.
