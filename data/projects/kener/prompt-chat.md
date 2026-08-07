This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Kener 4.1.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read these two before step 1, because together they decide whether you want this at all. A
monitor cannot tell you that the machine it runs on is down, so this belongs on a box other
than the ones it watches, and you should keep one free external check pointed at this hostname
from a service you do not run. And what you are building is a public status page: the dashboard
answers everybody by design, and every monitor name and description you add later is published
to whoever loads it. The sign-in and manage screens behind it are not public, and step 7 closes
the one window where that distinction does not yet hold.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Pick that hostname
carefully for a second reason too: it becomes `ORIGIN` in step 3, the address Kener compares
every form post against, so changing it later means editing .env and restarting.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kener /srv/kener/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/kener/database
sudo install -d -m 750 /srv/kener/redis
ls -la /srv/kener
```

You should see: `backups` owned by you, `database` owned by `1000`, and `redis` owned by
`root`.

If you do not: those three owners are deliberate and none of them is you by accident. The Kener
image runs as its own `node` user, uid 1000, so a `database` directory owned by your login user
is one the container cannot write, and the first boot fails with a permission error about
`kener.sqlite.db`. The redis image chowns its own data directory the first time it starts, so
leaving `redis` to root is correct. Keep `/srv/kener/database` on the server's local disk: it
is a SQLite file, and a network mount corrupts one quietly, weeks later.

## 3. Secrets

One secret here, `KENER_SECRET_KEY`. Upstream documents it as the key that signs your session
tokens and encrypts stored credentials, and documents `openssl rand -base64 32` as the way to
make one. It is generated on the server and written straight into a file only you can read.
`ORIGIN` sits in the same file and is not a secret: it is the public URL SvelteKit compares
against on every form post, and it takes no trailing slash.

```bash
umask 077
cat > /srv/kener/.env <<EOF
ORIGIN=https://<DOMAIN>
TZ=UTC
KENER_SECRET_KEY=$(openssl rand -base64 32)
EOF
chmod 600 /srv/kener/.env
umask 022
ls -l /srv/kener/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/kener/.env` and carry
on. If the file already existed from an earlier attempt, this block has now replaced the key,
which is harmless before anyone has signed in and disruptive afterwards: a new key invalidates
every session and makes anything Kener encrypted under the old one unreadable.

Do not paste that file, the key, or any command output containing it into this chat window.
Read the key once with `sudo grep KENER_SECRET_KEY /srv/kener/.env`, put it in your password
manager, and close the terminal scrollback if you share screenshots.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/kener/compose.yml <<'EOF'
# Kener · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   deployment ......... https://kener.ing/docs/v4/setup/deployment
#   environment ........ https://kener.ing/docs/v4/setup/environment-variables
#   database ........... https://kener.ing/docs/v4/setup/database-setup
#   image build ........ https://github.com/rajnandan1/kener/blob/v4.1.2/Dockerfile
#
# Two services. Redis is not optional in v4: upstream's own compose file calls
# it required for the queues, the cache and the scheduler, and the environment
# reference marks REDIS_URL required, so a Kener with no Redis runs no checks.
# No database container: DATABASE_URL is left unset, so upstream defaults to
# SQLite at ./database/kener.sqlite.db, the mount below. The image runs as the
# node user, uid 1000, which is why step 2 hands database/ to 1000. Digests
# read from the registries on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: kener-redis
    restart: unless-stopped
    volumes:
      # Queue and scheduler state only: monitors, incidents and every result
      # live in the SQLite file below. The image chowns this on first start.
      - /srv/kener/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    # No `ports:` at all: 6379 is reachable only from the other container.

  kener:
    image: ghcr.io/rajnandan1/kener:v4.1.2@sha256:239ab635b900b3fe0a4e22f5599f77525211d1b7a25b8fcf3d173936ddacc1cc
    container_name: kener
    restart: unless-stopped
    env_file: /srv/kener/.env
    environment:
      # Redis is on the compose network only, so this carries no credential.
      REDIS_URL: redis://redis:6379
      NODE_ENV: production
    volumes:
      # kener.sqlite.db: every monitor, incident, page, user and result.
      - /srv/kener/database:/app/database
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8179.
      - "127.0.0.1:8179:3000"
    depends_on:
      redis:
        condition: service_healthy
EOF
cd /srv/kener && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/kener/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/kener/compose.yml` and paste again in one go. There is no Postgres service in this
file and that is correct. `DATABASE_URL` is left unset, upstream then uses SQLite in the mounted
`database` directory, and that one file is the whole of your data.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-kener
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Kener · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://kener.ing/docs/v4/setup/deployment and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That same hostname is
# ORIGIN in .env: Kener hands ORIGIN to SvelteKit for the cross-site check on
# every form post, so if the two disagree the page loads and the sign-in fails.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		# The status page is public and the manage screens behind it are not,
		# and both share a hostname. SAMEORIGIN protects the second, at the cost
		# of the badge embeds Kener offers for other people's sites.
		X-Frame-Options "SAMEORIGIN"
		# Upstream reads the Origin header when the browser sends one and falls
		# back to SameSite=Lax cookies when it does not, so this costs nothing.
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8179 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8179
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-kener /etc/caddy/Caddyfile`, reload,
and paste again. The commonest cause is a `<DOMAIN>` you replaced in the comment but left in
the site line. Caddy requests the certificate on the first request to the hostname and renews
it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8179`, `6379` or `3000`.

If you do not: delete anything for `8179` with `sudo ufw delete allow 8179`. Compose binds it
to 127.0.0.1, so a rule for it would cover traffic that cannot arrive, and 6379 is never
published at all, so Redis has no host port a rule could apply to. Your checks need nothing
opened either: they are outbound requests from the container, and ufw governs what arrives.
`Status: inactive` is a different problem, because Prompt Zero left this firewall on, so
something has turned it off since; `sudo ufw enable` puts it back.

## 7. Start and verify

Kener runs its migrations and its seed on the way up, so the first boot writes the schema and a
starter status page before it answers anything. The loop below is why there is no fixed sleep.

```bash
cd /srv/kener
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' 'https://<DOMAIN>/healthcheck?strict=1'); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthcheck; echo
curl -sSL https://<DOMAIN>/ | grep -c 'Service Status'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/monitors
curl -sSL https://<DOMAIN>/account/signin | grep -c 'Create Admin Account'
```

You should see, in order: the loop reaching `200`, then
`{"status":"ok","db":true,"redis":true}`, then a number greater than `0` because
`Service Status` is the heading the seeded status page renders, then `401`, then another number
greater than `0`.

If you do not: the `?strict=1` on the loop is the part worth understanding. Upstream answers
`200` from `/healthcheck` even when the database or Redis is down, printing `"status":"degraded"`
in the body instead, and only the strict form turns a sick dependency into a `503`. So a bare
`200` proves nothing on its own; the body is the assert. The `401` is good news too: it means
the API refused a call carrying no bearer token. A `404` in place of the first three means Caddy
is reaching something other than Kener, so check `docker compose ps`. If the Kener container
never starts, run `docker compose logs --tail 20 redis` first, because a Redis that never
reports healthy holds the app back through `depends_on`, then
`docker compose logs --tail 40 kener`.

That last number is the one with a deadline on it. With no users in the database yet,
https://<DOMAIN>/account/signin is a `Create Admin Account` form, and it is open to whoever
loads the hostname first. Open it now, fill in a name, an email address and a password, and put
that password in your password manager. Then prove the window is shut:

```bash
curl -sSL https://<DOMAIN>/account/signin | grep -c 'Create Admin Account'
curl -sSL https://<DOMAIN>/account/signin | grep -c 'Sign In'
```

You should see: `0` from the first, and a number greater than `0` from the second.

If you do not: a `Create Admin Account` form that is still there means the account was not
created, not that the check is wrong. Upstream's signup action refuses once one user exists, so
there is no setting to switch and no second account to worry about. A running container was
never the finish line; these two numbers are.

## 8. First backup and restore

One archive: the SQLite database, the environment file, the compose file and the live Caddy
site block. Redis is not in it, because it holds queue and scheduler state that rebuilds
itself, while every monitor, incident, page, user and result is in the SQLite file.

```bash
cd /srv/kener
docker compose stop
sudo tar -czf /srv/kener/backups/kener-$(date +%F).tar.gz -C /srv/kener database .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/kener/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install. The containers go down
for a few seconds on purpose, because a SQLite file copied mid-write is not a backup.

If you do not: an archive of about 100 bytes means `tar` found none of the paths, which happens
if a `-C` argument has a typo. Run `tar -tzf` on it and read what it actually contains; you
want `database/`, `.env`, `compose.yml` and `Caddyfile` in the listing.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/kener
scp vps:/srv/kener/backups/*.tar.gz ~/backups/kener/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/kener/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty status page:

```bash
cd /srv/kener
docker compose down
sudo rm -rf /srv/kener/database
sudo install -d -m 750 -o 1000 -g 1000 /srv/kener/database
sudo tar -C /srv/kener -xzf /srv/kener/backups/kener-$(date +%F).tar.gz database .env compose.yml
docker compose up -d
sleep 30
curl -sSL https://<DOMAIN>/account/signin | grep -c 'Sign In'
```

You should see: a number greater than `0`, from a database directory that was deleted a minute
ago, which means your administrator account came back with it.

If you do not: `tar: database: Not found in archive` means the date in the filename does not
match, so run `ls /srv/kener/backups/` and use the real one. If the page offers to create an
admin account again, the restore put back an empty database and you are looking at a fresh
install. Know what the two halves are worth: `database/kener.sqlite.db` is your monitors, your
incident history and your account, and `.env` is the key that decrypts what Kener stored under
it. Neither is much use without the other.

## 9. Updating later

New versions are listed at https://github.com/rajnandan1/kener/releases. The release tag and
the image tag are the same string, so release `v4.1.3` is image tag `v4.1.3`. Take a backup
first, then edit the `image:` line in /srv/kener/compose.yml to the new tag and its digest.

```bash
cd /srv/kener
docker compose pull
docker compose up -d
docker compose logs --tail 30 kener
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Kener runs its
migrations on the way up, so watch that log until it settles, then re-run step 7's health check
and the `Service Status` grep before you call the update done.

## 10. What will probably go wrong

The sign-in that fails on a page that loads. I had `ORIGIN` set with a trailing slash, and
everything else looked right: the status page rendered, the health check said ok, the
`Create Admin Account` form appeared. Submitting it returned a bare
`Cross-site POST form submissions are forbidden`, and I spent twenty minutes in Caddy's logs
looking for a problem that was one character in .env. Kener hands `ORIGIN` to SvelteKit, which
compares it against the host the browser used on every form post; a trailing slash, an `http://`
where the browser said `https://`, or a `www.` on one side only are all mismatches. If step 7's
account creation will not complete, run `grep ORIGIN /srv/kener/.env` first, fix it, then
`docker compose up -d --force-recreate` before touching anything else.

## 11. Out of scope

- Do not set `DATABASE_URL` and do not add a Postgres or MySQL service. SQLite is the choice
  here, and it is why the whole install is one directory and one file to copy.
- Do not configure SMTP, `RESEND_API_KEY`, or any alerting provider. Every one of them is an
  account or a key somewhere else, and you wire those up in the manage screens.
- Do not set `KENER_BASE_PATH` and do not switch to a `-status` image variant. Those exist for
  serving Kener under a subpath of a hostname that already has a site, and they are a different
  image built at a different base path.
- Do not publish 3000 or 6379 on the host and do not open either in the firewall. Caddy is the
  only way in, and Redis is reachable only from the other container.
