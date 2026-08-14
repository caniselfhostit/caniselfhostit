This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Budibase 3.41.3 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, replace `<DOMAIN>` with the hostname whose A record already points at the
box, and replace `<ADMIN_EMAIL>` with the address you intend to sign in as.

Read this before step 1. Budibase's all-in-one image is a crowded container: CouchDB, the
Clouseau search indexer, a Structured Query Server, Redis, MinIO, an internal PostgreSQL and a
LiteLLM proxy all run alongside the Budibase server and worker, under pm2, behind an nginx
inside the container. Upstream asks for 2 cores and 6 GB of RAM. A 2 GB droplet will not run it,
and finding that out at step 7 costs you an hour.

`<ADMIN_EMAIL>` matters more here than in most installs. Step 3 puts it and a generated password
into a file, and the server creates that administrator account during its very first boot, so
there is never a moment when the `Create an admin user` screen is sitting open for whoever finds
your hostname first. Choose the address now, in lowercase, and use exactly those characters when
you sign in.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `6144` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. A RAM number under 6144
is the one to take seriously rather than push through. The pull alone is over a gigabyte, and
when the memory runs out the OOM killer arrives partway through the first boot, which reads as a
random failure rather than as a decision you made at checkout.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/budibase /srv/budibase/backups
sudo install -d -m 755 /srv/budibase/data
ls -la /srv/budibase
```

You should see: `backups` owned by you, and `data` owned by root at mode `755`.

If you do not: leave `data` owned by root and leave the mode at 755 on purpose. The container
starts as root and then chowns `data/couch` to its CouchDB uid and `data/litellm` to its
PostgreSQL uid, and those processes have to be able to traverse the parent directory. A tighter
mode, or a `chown` to yourself, stops the database from starting with an error that does not
mention permissions. Everything the instance keeps lands in that one directory, including a
`.env` of generated secrets the container writes for itself on the first boot.

## 3. Secrets

Four secrets, all generated here, on the server, and all going straight into a file only you can
read. Three of the four close a door rather than open one, which is worth understanding before
you paste.

```bash
umask 077
cat > /srv/budibase/.env <<EOF
BB_ADMIN_USER_EMAIL=<ADMIN_EMAIL>
PLATFORM_URL=https://<DOMAIN>
BB_ADMIN_USER_PASSWORD=$(openssl rand -hex 24)
COUCHDB_PASSWORD=$(openssl rand -hex 32)
INTERNAL_API_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/budibase/.env
umask 022
ls -l /srv/budibase/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` and
`<ADMIN_EMAIL>` with your real values before you paste. `BB_ADMIN_USER_PASSWORD` is your initial
administrator password, and the server creates the account from it at start-up.
`COUCHDB_PASSWORD` replaces a credential the base image bakes in as the literal word `admin`,
which the container's start-up script leaves alone precisely because it is not empty.
`INTERNAL_API_KEY` rides in the `x-budibase-api-key` header the server and worker call each
other with. `JWT_SECRET` signs every session cookie and, because `API_ENCRYPTION_KEY` is not set
on this shape, it is also the key the platform encrypts stored API keys with. Read your password
once with `sudo grep BB_ADMIN_USER_PASSWORD /srv/budibase/.env` and put it in your password
manager tonight.

Do not paste that file, any of those four values, or any command output containing them into
this chat window. The agent path never sees them; this path hands them to a third party unless
you make a point of not doing it.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/budibase/.env` and
carry on. Do not delete this file later, either. `docker compose` will not start without it, and
step 8 archives it, because data restored beside a fresh `JWT_SECRET` signs every session out
and cannot decrypt the API keys the old one encrypted.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/budibase/compose.yml <<'EOF'
# Budibase · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ... https://docs.budibase.com/docs/docker
#   start-up script .. https://github.com/Budibase/budibase/blob/3.41.3/hosting/single/runner.sh
#
# One service, and it is a crowded one. Upstream's all-in-one image runs
# CouchDB, the Clouseau search indexer, a Structured Query Server, Redis,
# MinIO, an internal PostgreSQL and a LiteLLM proxy alongside the Budibase
# server and worker, all under pm2 behind an nginx inside the container. That
# is why no database service appears below, why the RAM floor is 6 GB, and
# why everything the instance keeps, including the .env of generated secrets
# it writes on first boot, lives under the one /data mount.
#
# CUSTOM_DOMAIN is deliberately never set: it makes the container run certbot
# for a certificate of its own, and the host's Caddy already terminates TLS.
# The container's 443 is never published, only its plain-http 80. The image
# ships its own HEALTHCHECK, so none is declared here. Tag and digest read
# from the registry on 2026-08-12; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  budibase:
    image: budibase/budibase:3.41.3@sha256:f05b90c2b8afc951feb99931bb4646d2c94af37d9c576ef3c4e01d4fdc296dc1
    container_name: budibase
    restart: unless-stopped
    env_file: /srv/budibase/.env
    environment:
      # Upstream ships product analytics on for self-hosted instances. The
      # string "0" is the off switch: backend-core coerces "0" and "false"
      # to a disabled value before anything reads it.
      ENABLE_ANALYTICS: "0"
    volumes:
      - /srv/budibase/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8187.
      - "127.0.0.1:8187:80"
EOF
cd /srv/budibase && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/budibase/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/budibase/compose.yml` and paste again in one go. Nothing here publishes 443,
because the container only requests a certificate when `CUSTOM_DOMAIN` is set, and setting it
would put a second certificate authority client on a box where Caddy already owns the hostname.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-budibase
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Budibase · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.budibase.com/docs/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also PLATFORM_URL in .env, the address
# Budibase builds app and invitation links against, so the two have to agree.

<DOMAIN> {
	# The nginx inside the container proxies /db/ straight into the CouchDB
	# that holds every table, row and app here. Upstream documents that path
	# as an operator's route to Fauxton, CouchDB's own admin client:
	# https://docs.budibase.com/docs/accessing-couchdb . That is a tool for
	# whoever runs this box, not a page for the internet, so this refuses it.
	@couchdb path /db/*
	respond @couchdb 403

	# HSTS is the one the container cannot send for itself, because nothing
	# inside it knows it is served over https. No `encode`: the inner nginx
	# already gzips. No X-Frame-Options either, because the application sets
	# frame-ancestors itself from the workspace embed allowlist.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8187 is the loopback port compose publishes on this host. It is not
	# open in the firewall. The builder holds a WebSocket open to /socket/,
	# and reverse_proxy carries that upgrade with no extra configuration.
	reverse_proxy 127.0.0.1:8187
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-budibase /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the
other, which leaves a site block Caddy will happily try to get a certificate for. The `/db/`
rule is worth knowing about: the container's own nginx will proxy that path straight into
CouchDB, and this block refuses it before it gets there.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8187`, `5984`, `6379`, `9000` or `5432`.

If you do not: delete anything for `8187` with `sudo ufw delete allow 8187`. CouchDB, Redis,
MinIO, PostgreSQL and LiteLLM all live inside the container and listen on the container's own
loopback, so they have no host port a firewall rule could apply to at all. 80/tcp redirects to
HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which
Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first boot is slow and it is meant to be. The pull is over a gigabyte, then CouchDB creates
its system databases, PostgreSQL runs `initdb`, LiteLLM applies its migrations, and the server
and worker start last. The loop below waits fifteen minutes.

```bash
cd /srv/budibase
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/system/status
curl -sS https://<DOMAIN>/api/global/configs/checklist | grep -o '"adminUser":{"checked":[a-z]*'
docker compose exec -T budibase curl -sS -o /dev/null -w '%{http_code}\n' -u admin:admin http://127.0.0.1:5984/_all_dbs
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/db/_all_dbs
docker compose exec -T budibase sh -c 'chmod 600 /data/.env && stat -c %a /data/.env'
```

You should see, in order: the loop climbing through `502` and reaching `200`, a JSON object
containing `"version":"3.41.3"`, then `"adminUser":{"checked":true`, then `401`, then `403`,
then `600`.

If you do not: `"adminUser":{"checked":true` is the one worth understanding. It means the
administrator account existed before the port ever answered a stranger, so nobody could have
walked into the setup form while you were reading this. If it comes back `false`, stop, do not
open the site, and do not create an account by hand: something kept the two `BB_ADMIN_USER_`
lines from reaching the container. Start over while there is nothing to lose, with
`docker compose down`, `sudo rm -rf /srv/budibase/data`,
`sudo install -d -m 755 /srv/budibase/data`, a check that `.env` really carries both lines, and
`docker compose up -d`. The `401` is the second security answer: it means the CouchDB credential
the base image bakes in no longer works. The `403` is the third: Caddy is refusing the path that
would otherwise reach that database from the internet. A `"version"` that is not `3.41.3` means
you are running a different build than the one this page describes. A loop that never leaves
`502` after fifteen minutes is real: run `docker compose logs --tail 80 budibase` and look for
the container restarting, which is almost always memory.

The first screen at https://<DOMAIN> is the sign-in form, headed `Log in to Budibase`. It is not
the `Create an admin user` screen, and that difference is the whole point of step 3.

Open it now, sign in with `<ADMIN_EMAIL>` and the password you read out of `.env`, and change
that password in your account settings while you are there. There is no mail server on this
install, so there is no reset link and no invitation email: the password you set now is the only
way back in, and it belongs in your password manager before you close the tab.

## 8. First backup and restore

One archive, taken with the container stopped. Several storage engines are writing inside that
directory and a tar of a live CouchDB is not a backup, it is a file that resembles one.

```bash
cd /srv/budibase
docker compose stop
sudo tar -czf /srv/budibase/backups/budibase-$(date +%F).tar.gz -C /srv/budibase compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/budibase/backups/
```

You should see: one file, a few hundred megabytes on a fresh install, because several empty
storage engines are still several storage engines. The stop and start cost a few minutes of
downtime while the container brings all of them back up.

If you do not: a `tar: Removing leading /` warning is normal and not an error. `Permission
denied` means you dropped the `sudo`, which you need because `data` belongs to root. Upstream
sells in-product workspace backups as a licensed feature, so this archive is the backup on a
community install rather than a convenience on top of one.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/budibase
scp vps:/srv/budibase/backups/*.tar.gz ~/backups/budibase/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/budibase/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty instance:

```bash
cd /srv/budibase
docker compose down
sudo rm -rf /srv/budibase/data
sudo tar -xzf /srv/budibase/backups/budibase-$(date +%F).tar.gz -C /srv/budibase
docker compose up -d
sleep 600
curl -sS https://<DOMAIN>/api/system/status
```

You should see: `"version":"3.41.3"` again, and your account still able to sign in.

If you do not: untar with `sudo`, always. The archive carries the uids CouchDB and PostgreSQL
own their directories as, and an extract that flattens those owners gives you a container that
starts and databases that do not. `.env` is inside that archive on purpose, so it is back in
place before the first start: compose will not start without it, and a data directory restored
beside a fresh `JWT_SECRET` signs every session out and cannot decrypt the API keys the old one
encrypted. Ten minutes is the shortest wait worth giving it.

## 9. Updating later

New versions are listed at https://github.com/Budibase/budibase/releases. 3.41.3 was the newest
stable release on the day this was pinned. Take the backup above first, then edit the `image:`
line in /srv/budibase/compose.yml to the new tag and its digest.

```bash
cd /srv/budibase
docker compose pull
docker compose up -d
docker compose logs --tail 60 budibase
```

You should see: migration output, then the server and worker starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
whole check block from step 7 before you call the update done, and open one of your own apps as
well, because a server that answers with a version string can still be failing on a migration
that stopped halfway. Budibase releases often, sometimes several times a week, so pick a cadence
rather than chasing every tag.

## 10. What will probably go wrong

The first boot log. I tailed the container, read a block of capital letters saying `did not
exist; generated fresh secrets for` followed by a list of variable names and a warning about
data being lost on restart, and took it all down assuming the volume was wrong. It was not. The
start-up script prints that whenever `/data/.env` is absent, which on a correct install happens
exactly once, a moment before it writes the file. To tell it from the real failure, restart the
container and look again: if it reappears, `/data` is genuinely not persisting and step 2 is
where to look. If it does not, that log line is history.

## 11. Out of scope

- Do not set `CUSTOM_DOMAIN`. It makes the container run certbot for its own certificate on
  port 443, which fights the Caddy that already holds the hostname.
- Do not configure SMTP. Budibase runs without it; what it costs is invitation and
  password-reset email, a trade you make later rather than a step here.
- Do not point `COUCH_DB_URL`, `REDIS_URL` or `DATABASE_URL` outside the container. The embedded
  engines are the shape of this install and moving them is a migration.
- Do not delete /srv/budibase/.env and do not enter a Budibase licence key. This installs the
  community edition on its free self-hosted licence.
