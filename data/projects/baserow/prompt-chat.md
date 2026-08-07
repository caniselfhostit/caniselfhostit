This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Baserow 2.3.3 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` becomes `BASEROW_PUBLIC_URL`, and the Caddy that runs inside
the Baserow container matches the Host header against that value to decide whether a request is
Baserow's. Change the hostname later and the API routes stop answering until you change the
variable too. Pick the name you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: the RAM line is the one to take seriously. The image upstream calls all-in-one
runs a PostgreSQL 15 and a Redis inside the same container as the Django backend, the Nuxt web
frontend and a Caddy of its own, and upstream's own capacity guidance for one of these
containers is 2 vCPU and 4 GB even when the database sits outside it. On a smaller box the OOM
killer arrives partway through the first migration and the failure looks random. An empty last
line means the A record does not exist yet: add it, wait a minute, run `dig +short <DOMAIN>`
again, because Caddy cannot get a certificate for a hostname that does not resolve and failed
attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/baserow /srv/baserow/backups
sudo install -d -m 755 /srv/baserow/data
ls -la /srv/baserow
```

You should see: `backups` owned by you, and `data` owned by root at mode `drwxr-xr-x`.

If you do not: leave `data` owned by root on purpose. The container starts as root, chowns that
directory to uid 9999 and only then drops privileges, and the PostgreSQL inside it refuses to
initialise in a directory somebody else already owns. Everything the instance keeps lands under
there: the database cluster, the Redis dump, your uploaded files and the plugins.

## 3. Secrets

Two secrets: the Django secret key and the JWT signing key. The image will generate a pair of
its own into /baserow/data if none arrive from outside, and values set from outside win, so
these are generated here and land in a file only you can read, which is also a file the backup
carries.

```bash
umask 077
cat > /srv/baserow/.env <<EOF
BASEROW_PUBLIC_URL=https://<DOMAIN>
SECRET_KEY=$(openssl rand -hex 32)
BASEROW_JWT_SIGNING_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/baserow/.env
umask 022
ls -l /srv/baserow/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste. Read the pair back once with
`sudo grep -E 'SECRET_KEY|SIGNING_KEY' /srv/baserow/.env` and put both in your password manager
tonight: the first signs session cookies, the second signs every API token, and a restore that
arrives without them logs everybody out of an instance that no longer recognises its own tokens.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/baserow/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten both
keys, which is harmless before the first start and a mass sign-out afterwards.

Do not paste that file, either key, or any command output containing them into this chat window.
The chat path is the one place these values can leave your machine, and nothing in this install
needs you to show them to anybody.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/baserow/compose.yml <<'EOF'
# Baserow · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://baserow.io/docs/installation%2Finstall-with-docker
#   variable reference . https://baserow.io/docs/installation%2Fconfiguration
#   capacity guidance .. https://baserow.io/docs/installation%2Finstall-on-aws
#   supported versions . https://baserow.io/docs/installation%2Fsupported
#
# One service, and it is five processes wearing one hat. Upstream's all-in-one
# image runs a PostgreSQL 15 and a Redis inside this same container next to the
# Django backend, the Nuxt web frontend and a Caddy of its own, and keeps every
# byte of that under /baserow/data. That is why no database service appears
# below, and why the RAM floor is 4 GB rather than the few hundred megabytes a
# web application on its own would want.
#
# BASEROW_CADDY_ADDRESSES is pinned to :80 so the container's Caddy serves plain
# http and never asks Let's Encrypt for anything. The host Caddy already holds
# the hostname and terminates TLS, so only the container's port 80 is published.
# Tag and digest were read from Docker Hub on 2026-08-07; the image publishes
# amd64 and arm64. The image carries its own HEALTHCHECK, so this file adds
# none.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  baserow:
    image: baserow/baserow:2.3.3@sha256:41adb3493379403946a493f30873f743bb65b19b5f387d630ec75f41e25d5b5b
    container_name: baserow
    restart: unless-stopped
    env_file: /srv/baserow/.env
    environment:
      # :80 keeps the inner Caddy on plain http and off the ACME path.
      BASEROW_CADDY_ADDRESSES: ":80"
      # The host Caddy terminates TLS and sets X-Forwarded-Proto itself, which
      # is the condition upstream names for turning this on. Without it the
      # paginated API hands out http:// links for an https-only service.
      BASEROW_ENABLE_SECURE_PROXY_SSL_HEADER: "yes"
      # One celery worker running both the fast and the slow queue. Upstream
      # names this pair as the way to lower the image's memory use, and the
      # price is that a large export can delay a realtime row update.
      BASEROW_AMOUNT_OF_WORKERS: "1"
      BASEROW_RUN_MINIMAL: "yes"
    volumes:
      - /srv/baserow/data:/baserow/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8175.
      - "127.0.0.1:8175:80"
EOF
cd /srv/baserow && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/baserow/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/baserow/compose.yml` and paste again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-baserow
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Baserow · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://baserow.io/docs/installation%2Finstall-with-docker,
# https://baserow.io/docs/installation%2Fconfiguration and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also BASEROW_PUBLIC_URL in .env. The container's own Caddy decides whether a
# request is for Baserow by comparing the Host header against that value, so
# the two have to stay the same string or the API routes stop answering.

<DOMAIN> {
	# The web frontend is a large JavaScript bundle and the API answers JSON.
	# The container's Caddy compresses neither, so this is the only place it
	# happens. Uploaded files are served from the same hostname and Caddy
	# leaves already-compressed images alone.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# Realtime collaboration holds a websocket open on /ws/, and reverse_proxy
	# carries that upgrade with no extra directive. Caddy also sets
	# X-Forwarded-Proto here, which is what lets the container be told it is
	# behind https.
	#
	# 8175 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8175
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-baserow /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you replaced in the site line but not in
the comment above it, which is harmless, or one you replaced nowhere, which is not.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8175`, `5432` or `6379`.

If you do not: delete anything for `8175` with `sudo ufw delete allow 8175`. 8175 is bound to
127.0.0.1 by the compose file, and the PostgreSQL and Redis live inside the container and are
never published at all, so neither has a host port a firewall rule could apply to. 80/tcp is
there to redirect to HTTPS and answer the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem:
Prompt Zero left this firewall enabled, so something has turned it off since, and
`sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The first boot is slow, and this is the step where patience is the skill. The pull is over a
gigabyte, then PostgreSQL initialises a cluster, Django runs every migration from scratch and
the built-in templates import in the background. Upstream's deployment guide asks for a
900-second grace period on a first start, and the loop below allows exactly that.

```bash
cd /srv/baserow
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/_health/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/_health/
curl -sS https://<DOMAIN>/api/settings/ | grep -o '"show_admin_signup_page":[a-z]*'
```

You should see, in order: the loop climbing through `502` or `000` and ending on `200`, then the
two characters `OK` on their own line, then `"show_admin_signup_page":true`.

If you do not: read the log rather than the browser, with `docker compose logs -f baserow`. A
`502` inside the first fifteen minutes is the migrations still running. A `502` past fifteen
minutes points at step 4, a certificate error at step 5, and a container restarting in a loop
usually means the RAM in step 1 was measured on a box that had already given the memory away.
`"show_admin_signup_page":false` on a brand-new install would mean an account already exists,
which on a hostname that has been public for a while means somebody else has claimed it: destroy
the install with `docker compose down` and `sudo rm -rf /srv/baserow/data`, recreate the
directory as in step 2, and start again.

Now open https://<DOMAIN> in a browser. The first screen is the sign-up form: Baserow sends the
login page straight to it while no account exists, and it carries the notice
`Welcome to Baserow!` above the line `Please fill the form below to create the admin user.`
Fill it in. That account is given staff rights, which is what makes it the administrator, and
there is no mail server here, so there is no reset link: put the password in your password
manager as you type it.

Then, still signed in, open https://<DOMAIN>/admin/settings and turn off
`Allow creating new accounts`. Until you do, any visitor to your hostname can make an account.
Confirm both from the server:

```bash
curl -sS https://<DOMAIN>/api/settings/ | grep -o '"show_admin_signup_page":[a-z]*'
curl -sS https://<DOMAIN>/api/settings/ | grep -o '"allow_new_signups":[a-z]*'
```

You should see: `"show_admin_signup_page":false` and `"allow_new_signups":false`.

If you do not: a `true` on the second line means the toggle did not save, so reload
https://<DOMAIN>/admin/settings and check it again. Do not stop here with it open. A running
container is not success, and an instance still offering accounts to strangers is not success
either.

## 8. First backup and restore

One archive, taken with the container stopped. A PostgreSQL cluster and a Redis are writing
inside that directory, and a tar of a live database is a file that looks like a backup.

```bash
cd /srv/baserow
docker compose stop
sudo tar -czf /srv/baserow/backups/baserow-$(date +%F).tar.gz -C /srv/baserow compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/baserow/backups/
```

You should see: one file, a few hundred megabytes on a fresh install with the templates
imported. The stop and start cost about a minute.

If you do not: an archive of a few kilobytes means the `data` argument matched nothing, so check
you are in /srv/baserow and that step 2 created the directory. `tar: Removing leading /` is a
notice, not an error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/baserow
scp vps:/srv/baserow/backups/*.tar.gz ~/backups/baserow/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/baserow/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty database:

```bash
cd /srv/baserow
docker compose down
sudo rm -rf /srv/baserow/data
sudo tar -xzf /srv/baserow/backups/baserow-$(date +%F).tar.gz -C /srv/baserow
docker compose up -d
sleep 60
curl -sS https://<DOMAIN>/api/settings/ | grep -o '"allow_new_signups":[a-z]*'
```

You should see: `"allow_new_signups":false`, which means the setting you saved a few minutes ago
came back out of the archive, and so did the account you created.

If you do not: untar with sudo, always. The archive carries the uid 9999 that PostgreSQL owns
its cluster as, and an extract that flattens those owners gives a container that starts and a
database that does not. Two things worth knowing about that archive before you rely on it. It
holds a raw copy of the PostgreSQL data directory, so it restores into this same image and this
same major version and not into a PostgreSQL you install somewhere else. And it holds .env,
which is the only copy of the two keys from step 3.

## 9. Updating later

New versions are listed at https://github.com/baserow/baserow/releases. Take the backup from
step 8 first, then edit the `image:` line in /srv/baserow/compose.yml to the new tag and its
digest.

```bash
cd /srv/baserow
docker compose pull
docker compose up -d
docker compose logs --tail 40 baserow
```

You should see: migration output, then the line `Baserow is now available at`, and no repeating
restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, because a container that answers `OK`
can still be part-way through a migration that stopped.

## 10. What will probably go wrong

The wait. I brought this up on a 4 GB box, watched the browser return `502` for eleven minutes,
decided the reverse proxy was wrong and started taking the Caddy block apart. Nothing was wrong.
A first boot initialises a PostgreSQL cluster, runs every Django migration in order and then
imports the built-in templates, and none of that answers a request. The way to tell waiting from
broken is the loop in step 7: while it prints `502` or `000` under fifteen minutes it is still
coming up, and past fifteen minutes something is actually wrong. Read the log rather than the
browser, with `docker compose logs -f baserow`.

## 11. Out of scope

- Do not set `BASEROW_CADDY_ADDRESSES` to `:443` or to an https URL. That makes the container
  ask Let's Encrypt for its own certificate on a hostname the host Caddy already holds.
- Do not configure SMTP. Baserow runs without it; what it costs is invitation mail and
  password-reset mail, and that is a decision you make later, not a step here.
- Do not point `DATABASE_URL` or `REDIS_URL` at anything outside the container. The embedded
  pair is the shape of this install, and moving them is a migration rather than a setting.
- Do not add a licence key or install any premium or enterprise feature. This install is the
  free edition, which is the MIT-licensed part of the repository.
