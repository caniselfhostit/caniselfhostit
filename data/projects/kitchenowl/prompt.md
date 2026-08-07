You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install KitchenOwl 0.7.10 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname becomes
`FRONT_URL`, and it is also the address every phone in the household types into the KitchenOwl
app to find this server, so changing it later means visiting every phone.

KitchenOwl needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. Stop on anything that is not `amd64` or `arm64`. If `dig +short` prints
nothing, print that and stop: Caddy cannot get a certificate for a name that does not resolve,
and failed attempts count against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kitchenowl /srv/kitchenowl/backups
sudo install -d -m 755 /srv/kitchenowl/data
ls -la /srv/kitchenowl
```

Assert: `ls -la` shows `backups` owned by the login user and `data` present. Everything
KitchenOwl keeps goes under `data`: the SQLite file the shopping lists, recipes, meal plans and
expenses live in, and an `upload` directory of item and recipe photos it creates on the way up.
The container process runs as root and writes there itself, so leave the ownership alone and
expect to read that directory back with sudo after step 7.

## 3. Secrets

One secret: the JWT signing key. Upstream's own sample compose file sets it to a fixed
placeholder string printed on the same documentation page, so an install that leaves the
default alone can have its session tokens minted by anyone who read that page. Hex, not base64,
because it travels in a container environment variable. Generate it here, print it never, and
keep it out of your summary and every log line.

```bash
umask 077
cat > /srv/kitchenowl/.env <<EOF
FRONT_URL=https://<DOMAIN>
JWT_SECRET_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/kitchenowl/.env
umask 022
ls -l /srv/kitchenowl/.env
```

Assert: the file exists with mode `-rw-------` and the login user's name twice. Replace
`<DOMAIN>` on the first line with the real hostname before running the block. `FRONT_URL` is
the origin upstream documents for the CORS header, and it has to match the address the app is
opened at exactly, scheme included and no trailing slash. Tell the user one thing about the
key: it is not a password they ever type, but rotating it later signs every phone and browser
out.

## 4. compose.yml

```bash
cat > /srv/kitchenowl/compose.yml <<'EOF'
# KitchenOwl · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   self-hosting ....... https://docs.kitchenowl.org/v0.7.10/self-hosting/
#   variable reference . https://docs.kitchenowl.org/v0.7.10/self-hosting/advanced/
#   reverse proxy ...... https://docs.kitchenowl.org/v0.7.10/self-hosting/reverse-proxy/
#   image .............. https://github.com/TomBursch/kitchenowl/blob/v0.7.10/Dockerfile
#
# One service. Upstream publishes two shapes, a split front-and-back pair and an
# all-in-one image, and this file takes the all-in-one: the same container serves
# the web app on 8080 and answers /api on that same port, so there is nothing to
# route between two containers. The database driver defaults to sqlite and the
# file lands in /data next to the uploaded photos, so no database container runs
# here and there is nothing to dump. The image declares its own HEALTHCHECK
# against the /api/health route, so none is repeated below. Tag and digest read
# from Docker Hub on 2026-08-07; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  kitchenowl:
    image: tombursch/kitchenowl:v0.7.10@sha256:bd821a41b8cb27fd7fcf429acd1fc67e9f889485a2cd1193d68c2d804a8e1bef
    container_name: kitchenowl
    restart: unless-stopped
    # FRONT_URL and the signing key come from /srv/kitchenowl/.env, mode 600 and
    # owned by the login user. The image carries a signing-key default that
    # upstream prints in its own sample, so this file is only safe with that
    # file in place.
    env_file: /srv/kitchenowl/.env
    environment:
      # Nobody can create an account from the sign-in screen. The first account
      # invites the rest of the household instead.
      OPEN_REGISTRATION: "false"
      # Onboarding stays available until one account exists, then the server
      # closes it on its own: the endpoint counts users and refuses at one.
      DISABLE_ONBOARDING: "false"
    volumes:
      - /srv/kitchenowl/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8167.
      - "127.0.0.1:8167:8080"
EOF
cd /srv/kitchenowl && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount. Upstream
documents a PostgreSQL driver and a split front-and-back deployment as well, and this install
takes neither: SQLite inside the one image is the default and it is one less thing to operate.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-kitchenowl
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# KitchenOwl · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.kitchenowl.org/v0.7.10/self-hosting/reverse-proxy/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# FRONT_URL in .env, and upstream asks for an exact match including the scheme,
# so the two have to stay the same string.

<DOMAIN> {
	# The interface is a compiled web bundle and the API answers JSON. Caddy
	# leaves the already-compressed recipe and item photos alone.
	encode zstd gzip

	# Upstream calls Strict-Transport-Security the header this app needs, on
	# the grounds that a plain-http answer on this hostname is enough to hand
	# an attacker a session. The frame and sniff headers come from the same
	# page.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# The app opens a websocket back to this hostname and upstream warns that
	# some requests get noticeably slower without one. Caddy upgrades the
	# connection here with no extra directive.
	#
	# 8167 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8167
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-kitchenowl, reload, and report what it objected to. Caddy requests
the certificate on the first request to the hostname and renews it on its own. Nothing to
schedule, and no certificate path is written down anywhere.

## 6. Firewall

Two ports open, both Caddy's, and both idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3, and 8167 stays closed because compose binds it to 127.0.0.1. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8167.

## 7. Start and verify

The container migrates its database and imports a default item list on the way up, so the first
start is slower than the ones after it. Understand what is open while it runs: with no account
in the database, the onboarding endpoint hands the owner account to whoever posts to it first,
and it is on the public internet from the second the container answers. The gap between this
block starting and the user creating their account is the whole risk in this install.

```bash
cd /srv/kitchenowl
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health/8M4F88S8ooi4sMbLBfkkV7ctWwgibW6V); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health/8M4F88S8ooi4sMbLBfkkV7ctWwgibW6V
curl -sS https://<DOMAIN>/api/onboarding
curl -sS https://<DOMAIN>/ | grep -o '<title>[^<]*</title>'
```

Assert all four, and print what you received for each: the loop ends on `200`; the health JSON
has a `msg` field reading `OK` and no `open_registration` field, which is how the server reports
that public signups are off; the onboarding call answers with `onboarding` set to `true`,
meaning the database has no users yet; the last prints `<title>KitchenOwl</title>`. If any of the
four misses, stop, run `docker compose logs --tail 40 kitchenowl`, and name the likely earlier
step: a `502` instead of `200` means Caddy is reaching nothing on 8167, and a container
restarting in a loop points at step 2 or at an empty `.env` from step 3. A running container is
not success.

The first screen at https://<DOMAIN> shows the heading `Let's create a user` above a `Start`
button, with a `Switch server` link under it. That heading is the onboarding form, and it
appears because no account exists.

STOP: tell the user to open https://<DOMAIN> now, press `Start`, and create their account
with a username, a name and a password they choose themselves. Wait.
Do not continue until they confirm. That first account is the owner: the server creates
it with admin rights and then refuses to create a second one this way.

Once they confirm, prove the door is shut:

```bash
curl -sS https://<DOMAIN>/api/onboarding
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/auth/signup
```

Assert both: the first answers with `onboarding` set to `false`, and the second prints `404`.
The `404` is the security assert in this block: with public registration off, the server does
not publish a signup route at all, so a missing one is the correct answer rather than a routing
fault. Both must pass before you report success. If `onboarding` still reads `true`, the account
was not created and the owner slot is unclaimed, so stop and say so plainly.

Then hand the user the step this install exists for: each phone installs KitchenOwl from its
app store, picks the use-your-own-server option, and types https://<DOMAIN> into it once.
Invited household members do the same on their phones.

## 8. First backup and restore

Two artifacts. The data archive holds the SQLite database and the photo uploads; the config
archive holds the files that rebuild the service around them. Stop the container for the
archive: a SQLite file copied while it is being written is not a backup. Downtime is a few
seconds.

```bash
cd /srv/kitchenowl
docker compose stop
sudo tar -czf /srv/kitchenowl/backups/kitchenowl-data-$(date +%F).tar.gz -C /srv/kitchenowl data
docker compose start
sudo tar -czf /srv/kitchenowl/backups/kitchenowl-config-$(date +%F).tar.gz -C /srv/kitchenowl compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/kitchenowl/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. A backup on the same disk as
the data is not a backup, so run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/kitchenowl
scp vps:/srv/kitchenowl/backups/* ~/backups/kitchenowl/
```

To restore: `docker compose down`, `sudo rm -rf /srv/kitchenowl/data`,
`sudo tar -xzf /srv/kitchenowl/backups/kitchenowl-data-<date>.tar.gz -C /srv/kitchenowl`, untar
the config archive into /srv/kitchenowl so compose.yml and .env are back, then
`docker compose up -d`. Tell the user the fact that matters at 2am: the signing key is in
`.env` and not in the database, so restoring the data without that file signs every phone in
the house out, and restoring both signs nobody out.

## 9. Updating later

New versions are listed at https://github.com/TomBursch/kitchenowl/releases. Take both backup
artifacts first, then edit the image line in /srv/kitchenowl/compose.yml to the new tag and its
digest:

```bash
cd /srv/kitchenowl
docker compose pull
docker compose up -d
docker compose logs --tail 30 kitchenowl
```

KitchenOwl runs its own database migrations on the way up, so watch that log until it settles,
then re-run the health check from step 7 before calling the update done. The phone apps carry a
minimum server version of their own, so an app that stops connecting after a store update is a
server that has been left behind rather than a broken phone.

## 10. What will probably go wrong

The first browser load looks like a failed install. I ran the step 7 checks, got `200`, got the
title back from curl, opened the hostname in a browser and sat looking at an empty off-white
page long enough to start reading logs. Nothing was wrong: the interface is a compiled bundle
of several megabytes that the browser downloads before it paints anything, and the page served
in the meantime carries a background colour and no content. Give it a full minute, reload once,
and only then start checking whether Caddy is reaching 8167.

## 11. Out of scope

- Do not switch the database driver to PostgreSQL. SQLite in the one image is the default and
  the choice here, and moving between the two is a restore, not an edit.
- Do not configure SMTP. KitchenOwl runs without it; the cost is password-reset mail, and the
  owner can hand out household invitations from inside the app instead.
- Do not set `OPEN_REGISTRATION` or `DISABLE_USERNAME_PASSWORD_LOGIN`, and do not configure
  OIDC, Google or Apple sign-in. Public signups on a household grocery list are a spam surface,
  and the three identity options need an account somewhere else.
- Do not set `KITCHENOWL_MCP_ENABLED` or `COLLECT_METRICS`. The first publishes an agent
  endpoint and the second a metrics endpoint whose default basic-auth password is printed in
  upstream's documentation.
