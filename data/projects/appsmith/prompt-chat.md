This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Appsmith v2.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, replace `<DOMAIN>` with the hostname whose A record already points at the
box, and replace `<ADMIN_EMAIL>` with the address you intend to sign in as.

Read this before step 1. Appsmith is a heavy container: one image runs the application,
MongoDB, Redis and PostgreSQL together, and upstream asks for 8 GB of RAM on the host. A 2 GB
droplet will not run it, and finding that out at step 7 costs you an hour. Check the box you
have before you start.

`<ADMIN_EMAIL>` matters more here than in most installs. This install closes signup before the
first boot and names that one address as the exception, so it is the only address that can
create an account afterwards. Choose it now, write it in lowercase, and use exactly the same
characters when the welcome form asks for it.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `8192` MB available, at least `20` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that
does not resolve, and failed attempts count against a rate limit you cannot see. A RAM number
under 8192 is the one to take seriously rather than push through: three database engines and a
JVM in one container is what the floor is describing, and the OOM killer arrives partway
through the first boot, which reads as a random failure rather than as a decision you made at
checkout.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/appsmith /srv/appsmith/backups
sudo install -d -m 755 /srv/appsmith/stacks
ls -la /srv/appsmith
```

You should see: `backups` owned by you, and `stacks` owned by root.

If you do not: leave `stacks` owned by root on purpose. The container starts as root and hands
its embedded PostgreSQL a data directory it chowns to its own uid; a directory you have already
chowned to yourself gets in the way of that and of the restore in step 8. Everything the
instance keeps, from the MongoDB files to the git checkouts to the docker.env it writes for
itself, lands under that one directory.

## 3. Secrets

Two secrets: the encryption password and the encryption salt. Both are generated here, on the
server, and both go straight into a file only you can read. They are what encrypt every
database password, API key and token you later hand to a datasource, which is why they are
worth generating yourself rather than letting the container pick a shorter pair for you.

```bash
umask 077
cat > /srv/appsmith/.env <<EOF
APPSMITH_ADMIN_EMAILS=<ADMIN_EMAIL>
APPSMITH_SIGNUP_DISABLED=true
APPSMITH_BASE_URL=https://<DOMAIN>
APPSMITH_ENCRYPTION_PASSWORD=$(openssl rand -hex 32)
APPSMITH_ENCRYPTION_SALT=$(openssl rand -hex 32)
EOF
chmod 600 /srv/appsmith/.env
umask 022
ls -l /srv/appsmith/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>`
and `<ADMIN_EMAIL>` with your real values before you paste. Read the two keys once with
`sudo grep -E 'ENCRYPTION_PASSWORD|ENCRYPTION_SALT' /srv/appsmith/.env` and put them in your
password manager tonight: a data directory restored without them comes back with every app
intact and every datasource unable to decrypt its own credentials.

Do not paste that file, either key, or any output containing them into this chat window. The
agent path never sees those values; this path hands them to a third party unless you make a
point of not doing it.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/appsmith/.env` and
carry on. If the file already existed from an earlier attempt, this block has now replaced both
keys, which is harmless before the first boot and a real problem afterwards, because saved
datasource credentials were encrypted with the old pair.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/appsmith/compose.yml <<'EOF'
# Appsmith · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.appsmith.com/getting-started/setup/installation-guides/docker
#   variable reference . https://docs.appsmith.com/getting-started/setup/environment-variables
#   capacity planning .. https://docs.appsmith.com/getting-started/setup/infrastructure-sizing
#   backup and restore . https://docs.appsmith.com/getting-started/setup/instance-management/appsmithctl
#
# One service, and it is a heavy one. Upstream ships an all-in-one image that
# runs MongoDB, Redis and PostgreSQL inside this same container under
# supervisord, which is why no database service appears below and why the RAM
# floor is 8 GB rather than the few hundred megabytes a web app alone would
# want. Everything the instance keeps, including the docker.env it generates
# for itself on first boot, lives under /appsmith-stacks.
#
# APPSMITH_CUSTOM_DOMAIN is deliberately never set here: setting it makes the
# container ask Let's Encrypt for a certificate of its own, and the host's
# Caddy already terminates TLS. The container's 443 is therefore never
# published and only its plain-http 80 is. Tag and digest were read from the
# registry on 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  appsmith:
    image: appsmith/appsmith-ce:v2.2@sha256:dc17b968c88eebf42b85c2e22b97efb55f2339b2d685e48f804c5f87bdd9d4e5
    container_name: appsmith
    restart: unless-stopped
    env_file: /srv/appsmith/.env
    environment:
      # Upstream ships anonymous usage collection turned on. This turns it off.
      APPSMITH_DISABLE_TELEMETRY: "true"
      # The docker.env the container writes for itself lets any site on the
      # internet load these apps in an iframe. This narrows the
      # Content-Security-Policy back to this hostname and nothing else.
      APPSMITH_ALLOWED_FRAME_ANCESTORS: "'self'"
    volumes:
      - /srv/appsmith/stacks:/appsmith-stacks
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8143.
      - "127.0.0.1:8143:80"
EOF
cd /srv/appsmith && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/appsmith/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/appsmith/compose.yml` and paste again in one go. Nothing here publishes 443,
because the container only holds a certificate when `APPSMITH_CUSTOM_DOMAIN` is set, and
setting it would put a second certificate authority client on a box where Caddy already owns
the hostname.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-appsmith
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Appsmith · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.appsmith.com/getting-started/setup/installation-guides/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APPSMITH_BASE_URL in .env, which is the value Appsmith compares the
# Origin header of a password-reset request against, so the two have to agree.

<DOMAIN> {
	# The container runs a Caddy of its own and already sends
	# Content-Security-Policy and X-Content-Type-Options on every response, so
	# this block does not restate them and cannot contradict them. HSTS is
	# here because nothing inside the container knows it is being served over
	# https. There is no `encode` either: the inner Caddy compresses already,
	# and compressing a second time costs CPU for no bytes.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8143 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. The editor holds a
	# WebSocket open to /rts, and reverse_proxy carries that upgrade with no
	# extra configuration.
	reverse_proxy 127.0.0.1:8143
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-appsmith /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the
other, which leaves a site block Caddy will happily try to get a certificate for.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8143`, `27017`, `6379` or `5432`.

If you do not: delete anything for `8143` with `sudo ufw delete allow 8143`. The MongoDB, Redis
and PostgreSQL live inside the container and listen on the container's own loopback, so they
have no host port a firewall rule could apply to at all. 80/tcp redirects to HTTPS and answers
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first boot is slow. The image pull is about 1.5 GB, then three database engines initialise
and the server runs its migrations before it answers anything. Upstream says this can take up
to five minutes; on a small box it takes longer. The loop below waits fifteen minutes.

```bash
cd /srv/appsmith
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/health
curl -sS https://<DOMAIN>/api/v1/tenants/current | grep -o '"isSignupDisabled":[a-z]*'
curl -sS https://<DOMAIN>/ | grep -c 'Appsmith is starting.'
```

You should see, in order: the loop climbing through `502` and reaching `200`, a JSON object
containing `"data":"All systems are up"`, then `"isSignupDisabled":true`, then `0`.

If you do not: the `"isSignupDisabled":true` is the one worth understanding. It means signup was
shut before any account existed, so nobody could have walked through a window while you were
reading this. If it comes back `false`, stop and do not create an account: that value is written
into the database on the first boot only, and no later edit of `.env` changes it. Start over
while there is nothing to lose, with `docker compose down`, `sudo rm -rf /srv/appsmith/stacks`,
`sudo install -d -m 755 /srv/appsmith/stacks`, a check that `.env` really contains
`APPSMITH_SIGNUP_DISABLED=true`, and `docker compose up -d`. A last line of `1` rather than `0`
means the container is still serving its own holding page and is not finished booting, so give
it longer. A loop that never leaves `502` after fifteen minutes is real: run
`docker compose logs --tail 60 appsmith` and look for the container restarting, which is almost
always memory.

The first screen at https://<DOMAIN> is the welcome form, headed `Almost there` over
`Let's setup your account first`, with fields for a first name, last name, `Email` and a
password typed twice.

Open it now and fill it in, using exactly `<ADMIN_EMAIL>` as the email address. Any other
address gets an error beginning `Signup is restricted on this instance of Appsmith`, because
that is what step 3 configured. Put the password in your password manager while you are typing it:
there is no mail server on this install, so there is no reset link, and a forgotten password
here means editing the database by hand.

## 8. First backup and restore

One archive, taken with the container stopped. Three database engines are writing inside that
directory and a tar of a live MongoDB is not a backup, it is a file that looks like one.

```bash
cd /srv/appsmith
docker compose stop
sudo tar -czf /srv/appsmith/backups/appsmith-$(date +%F).tar.gz -C /srv/appsmith compose.yml .env stacks -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/appsmith/backups/
```

You should see: one file, a few hundred megabytes on a fresh install, because three empty
database engines are still three database engines. The stop and start cost a few minutes of
downtime while the container brings all of them back up.

If you do not: a `tar: Removing leading /` warning is normal and not an error. `Permission
denied` means you dropped the `sudo`, which you need because `stacks` belongs to root.
Upstream also ships `appsmithctl backup`, which prompts for an encryption password at the
terminal and refuses to restore without it; the archive above answers to no prompt, which is
what makes it runnable from cron later.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/appsmith
scp vps:/srv/appsmith/backups/*.tar.gz ~/backups/appsmith/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/appsmith/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty instance:

```bash
cd /srv/appsmith
docker compose down
sudo rm -rf /srv/appsmith/stacks
sudo tar -xzf /srv/appsmith/backups/appsmith-$(date +%F).tar.gz -C /srv/appsmith
docker compose up -d
sleep 300
curl -sS https://<DOMAIN>/api/v1/health
```

You should see: `"data":"All systems are up"` again, and your account still able to sign in.

If you do not: untar with `sudo`, always. The archive carries the uid the embedded PostgreSQL
owns its data directory as, and an extract that flattens those owners gives you a container
that starts and a database that does not. Five minutes is the shortest wait worth giving it.

## 9. Updating later

New versions are listed at https://github.com/appsmithorg/appsmith/releases. Take the backup
above first, then edit the `image:` line in /srv/appsmith/compose.yml to the new tag and its
digest.

```bash
cd /srv/appsmith
docker compose pull
docker compose up -d
docker compose logs --tail 40 appsmith
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one of your own apps as
well, because a server that answers `All systems are up` can still be failing on a migration
that stopped halfway.

## 10. What will probably go wrong

The wait. I brought this up on an 8 GB box, watched a page that said `Appsmith is starting.`
for nine minutes, decided the proxy was misconfigured, and started taking the Caddy block
apart. Nothing was wrong. That page is served by the container itself while three database
engines initialise behind it, and it is replaced the moment the server's health check passes.
The way to tell waiting from broken is the loop in step 7: if it is still printing `502` or
`000` after fifteen minutes, then something is actually wrong, and until then the honest answer
is that it is still coming up.

## 11. Out of scope

- Do not set `APPSMITH_CUSTOM_DOMAIN`. It makes the container request its own Let's Encrypt
  certificate on port 443, which fights the Caddy that already holds the hostname.
- Do not configure SMTP. Appsmith runs without it; what it costs is invitation email and
  password-reset email, and that is a trade you make later, not a step here.
- Do not point `APPSMITH_DB_URL` or `APPSMITH_REDIS_URL` at an external database. The embedded
  ones are the shape of this install and moving them is a migration, not a setting.
- Do not install the `appsmith-ee` image or enter a license key. This installs the community
  edition, which is the Apache-2.0 one.
