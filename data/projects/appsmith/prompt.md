You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Appsmith v2.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` is the hostname whose A record already points at this server.
`<ADMIN_EMAIL>` is the address that will own the instance, and it matters more here than in
most installs: this prompt closes signup before the first boot and names that one address as
the exception, so it is the only address that can create an account afterwards. Take it in
lowercase and repeat it back to the user, character for character.

Appsmith needs 8192 MB of RAM available and 20 GB free on /srv. That floor is not padding.
The image is one container that runs the application, MongoDB, Redis and PostgreSQL together
under supervisord, and upstream's own baseline for a self-hosted deployment is 2 vCPU and 8 GB.
The image publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 8192 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope: the OOM killer arrives partway through the first boot and the failure
looks random. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/appsmith /srv/appsmith/backups
sudo install -d -m 755 /srv/appsmith/stacks
ls -la /srv/appsmith
```

Assert: `ls -la` shows `backups` owned by the login user and `stacks` owned by root. Leave
`stacks` to root. The container starts as root and hands its embedded PostgreSQL a data
directory it chowns to its own uid, so an ownership fix applied from outside is undone on the
first boot and gets in the way of the restore in step 8. Everything the instance keeps, from
the MongoDB files to the git checkouts to the docker.env it writes for itself, lands under
that one directory.

## 3. Secrets

Two secrets: the encryption password and the encryption salt. Upstream generates a pair of
13-character values inside the container if none arrive from outside, and values set from
outside win, so generate them here where the user can read them back and keep them. They are
what encrypt every database password, API key and OAuth token the user later hands to a
datasource. Do not print either, do not repeat them in your summary, and do not put them in
any log line.

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

Assert: the file exists with mode `-rw-------`. Tell the user two things. First, those two
values are readable with
`sudo grep -E 'ENCRYPTION_PASSWORD|ENCRYPTION_SALT' /srv/appsmith/.env` and belong in their
password manager tonight, because a data directory restored without them comes back with every
app intact and every datasource unable to decrypt its own credentials. Second,
`APPSMITH_SIGNUP_DISABLED` is read once, during the first boot, and written into the database;
after that the setting lives there and changes in Admin Settings, not in this file.

## 4. compose.yml

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

Assert: that prints `compose OK`. One service, one published port, one bind mount.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-appsmith, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8143 stays closed because it is bound to 127.0.0.1. The MongoDB, Redis and
PostgreSQL inside the container listen on the container's own loopback and are never published
at all, so there is no host port for them to firewall. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8143, 27017, 6379 or 5432.

## 7. Start and verify

The first boot is slow. The image pull is about 1.5 GB, then three database engines initialise
and the server runs its migrations before it answers anything. Upstream says this can take up
to five minutes; on a small box it takes longer.

```bash
cd /srv/appsmith
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/v1/health
curl -sS https://<DOMAIN>/api/v1/tenants/current | grep -o '"isSignupDisabled":[a-z]*'
curl -sS https://<DOMAIN>/ | grep -c 'Appsmith is starting.'
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The
health response contains `"data":"All systems are up"`, which is the string the server returns
once both MongoDB and Redis answer it. The third command prints `"isSignupDisabled":true`, and
that is the security assert in this block: signup is shut before any account exists, rather
than being opened and closed around a window somebody else could walk through. The fourth
prints `0`, meaning the holding page the container serves while it boots is gone and the real
editor is being served. If any of the four misses, stop, run
`docker compose logs --tail 60 appsmith`, and name the likely cause: a `502` past fifteen
minutes points at step 4, a certificate error at step 5, and a container that keeps restarting
usually means the RAM floor in step 1 was measured on a box that had already given the memory
to something else. A running container is not success.

If `"isSignupDisabled"` came back `false`, do not carry on and do not create an account. The
value is written into the database on the first boot only. Reset instead, while there is
nothing to lose: `docker compose down`, `sudo rm -rf /srv/appsmith/stacks`,
`sudo install -d -m 755 /srv/appsmith/stacks`, confirm step 3's `.env` still has
`APPSMITH_SIGNUP_DISABLED=true` in it, then `docker compose up -d` and run this block again.

The first screen at https://<DOMAIN> is the welcome form, headed `Almost there` over
`Let's setup your account first`, with fields for a first name, last name, `Email` and a
password typed twice.

STOP: tell the user to open https://<DOMAIN>, fill that form in using exactly `<ADMIN_EMAIL>`
as the email address, and wait. Do not continue until they confirm. That address is the one
exception to the signup lock, so any other gets an error beginning `Signup is restricted on
this instance of Appsmith`, and the account created here becomes the instance administrator.
Tell them to put the password in their password manager as they type it: there is no mail
server here, so there is no reset link.

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

Assert: the archive exists and is non-empty. Print its size. The stop and start cost a few
minutes of downtime, because the container has to bring all three engines back up. Upstream
also ships `appsmithctl backup`, which prompts for an encryption password at the terminal;
this archive answers to no prompt, which is what makes it runnable from cron.

A backup on the same disk as the data is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/appsmith
scp vps:/srv/appsmith/backups/*.tar.gz ~/backups/appsmith/
```

To restore: `docker compose down`, `sudo rm -rf /srv/appsmith/stacks`, then
`sudo tar -xzf /srv/appsmith/backups/<archive> -C /srv/appsmith`, then `docker compose up -d`.
Untar it with sudo, always, because the archive carries the uid the embedded PostgreSQL owns
its data directory as, and an extract that flattens those owners gives a container that starts
and a database that does not. Tell the user those four commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/appsmithorg/appsmith/releases. Take the backup
from step 8 first, then edit the image line in /srv/appsmith/compose.yml to the new tag and its
digest:

```bash
cd /srv/appsmith
docker compose pull
docker compose up -d
docker compose logs --tail 40 appsmith
```

Appsmith runs its own database migrations on the way up, so watch that log until it settles,
then re-run the health check from step 7 before calling the update done.

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
  password-reset email, and that is a trade the user makes later, not a step here.
- Do not point `APPSMITH_DB_URL` or `APPSMITH_REDIS_URL` at an external database. The embedded
  ones are the shape of this install and moving them is a migration, not a setting.
- Do not install the `appsmith-ee` image or ask the user for a license key. This prompt
  installs the community edition, which is the Apache-2.0 one.
