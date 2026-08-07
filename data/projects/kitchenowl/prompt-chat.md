This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing KitchenOwl 0.7.10 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. `<DOMAIN>` becomes `FRONT_URL`, and it is also the address every phone
in your household types into the KitchenOwl app to find this server, so changing it later means
visiting every phone. Pick the hostname you intend to keep.

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
resolve, and failed attempts count against a rate limit you cannot see. An architecture that is
not `amd64` or `arm64` is a stop, because upstream builds the image for those two only. Under
1024 MB available is also a stop: the backend is a Python service that loads an English
part-of-speech tagger for its ingredient parsing, and a box that cannot spare the memory meets
the OOM killer during the first start rather than later.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kitchenowl /srv/kitchenowl/backups
sudo install -d -m 755 /srv/kitchenowl/data
ls -la /srv/kitchenowl
```

You should see: `backups` owned by you, and `data` at mode `drwxr-xr-x`.

If you do not: nothing here needs fixing by hand. Everything KitchenOwl keeps goes under `data`:
the SQLite file the shopping lists, recipes, meal plans and expenses live in, and an `upload`
directory of item and recipe photos it creates the first time it starts. The container process
runs as root and writes there itself, so leave the ownership alone, and expect the backup
command in step 8 to need `sudo` once the container has been up.

## 3. Secrets

One secret: the JWT signing key. Upstream's own sample compose file sets it to a fixed
placeholder string printed on the same documentation page, so an install that leaves the
default alone can have its session tokens minted by anyone who read that page. Replace
`<DOMAIN>` on the first line with your real hostname before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when
the lines are pasted separately into different shells. Run `chmod 600 /srv/kitchenowl/.env` and
carry on. If the file already existed from an earlier attempt, this block has overwritten the
signing key, which is harmless before anybody has signed in and a mass logout afterwards: every
phone and browser has to sign in again, and nothing else is lost.

Do not paste that file, the key, or any command output containing it into this chat window. The
value is yours and no third party needs a copy. `FRONT_URL` is the origin upstream documents for
the CORS header, and it has to match the address you open the app at exactly, scheme included
and no trailing slash.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/kitchenowl/.env not found` means step 3 did not write the file, or
you are not in /srv/kitchenowl. `services must be a mapping` means the indentation was lost
between the page and your terminal: run `rm /srv/kitchenowl/compose.yml` and paste again in one
go. Upstream documents a PostgreSQL driver and a split front-and-back deployment as well, and
this file takes neither. SQLite inside the one image is the default, and it is one less thing to
run, watch and dump.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-kitchenowl /etc/caddy/Caddyfile`, reload,
and paste again. The usual cause is a `<DOMAIN>` left literal in the site line. Caddy requests
the certificate on the first request to the hostname and renews it on its own, so there is
nothing to schedule and no certificate path to write down.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8167`.

If you do not: delete anything for `8167` with `sudo ufw delete allow 8167`. That port is bound
to 127.0.0.1 by the compose file, so a firewall rule for it opens a door that leads nowhere and
confuses the next person who reads the output. 80/tcp is there to redirect to HTTPS and answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The container migrates its database and imports a default item list on the way up, so the first
start is slower than the ones after it. Understand what is open while it runs: with no account
in the database, the onboarding endpoint hands the owner account to whoever posts to it first,
and it is on the public internet from the second the container answers. Do not start this block
and walk away.

```bash
cd /srv/kitchenowl
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health/8M4F88S8ooi4sMbLBfkkV7ctWwgibW6V); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health/8M4F88S8ooi4sMbLBfkkV7ctWwgibW6V
curl -sS https://<DOMAIN>/api/onboarding
curl -sS https://<DOMAIN>/ | grep -o '<title>[^<]*</title>'
```

You should see, in order: the loop reaching `200`, a small JSON object whose `msg` field reads
`OK` and which has no `open_registration` field, then a second object with `onboarding` set to
`true`, then `<title>KitchenOwl</title>`.

If you do not: the loop can legitimately take a minute or two on a small box, because the
container runs its migrations and imports a default item list before it answers anything. Give
it all thirty attempts before touching anything. A `502` that never clears means Caddy is
reaching nothing on 8167: check `docker compose ps`. A container restarting in a loop usually
means step 3 wrote nothing, so the signing key never reached it. The missing `open_registration`
field is not an error: the server only prints that key when public signups are on, so its
absence is the report that they are off.

Now claim the owner account, which is the part of this install with real security meaning. Open
https://<DOMAIN> in a browser. The first screen shows the heading `Let's create a user` above a
`Start` button, with a `Switch server` link under it. Press `Start` and create your account with
a username, a name and a password you choose yourself, and put that password in your password
manager. Do not type it into this chat window.

That first account is the owner: the server creates it with admin rights, and once it exists the
server refuses to create a second one this way. Everyone else in the household joins by
invitation from inside the app.

Then prove the door is shut:

```bash
curl -sS https://<DOMAIN>/api/onboarding
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/auth/signup
```

You should see: an object with `onboarding` set to `false`, then `404`.

If you do not: a first line still reading `true` means the account was not created and the owner
slot on your public hostname is still unclaimed by you. Go back to the browser and finish it
before anything else, because this is the one window in the install where a stranger who guessed
your hostname could take the admin account. The `404` on the second line is the assert with
teeth: with public registration off, the server does not publish a signup route at all, so its
absence is the correct answer rather than a routing fault. A `200` there would mean signups are
open, which is a stop.

Last, the step this install exists for: on each phone, install KitchenOwl from its app store,
choose the option to use your own server, and give it https://<DOMAIN>. Anyone you invite from
inside the app does the same on their phone.

## 8. First backup and restore

Two artifacts. The data archive holds the SQLite database and the photo uploads; the config
archive holds the files that rebuild the service around them. The container stops for the data
archive, because a SQLite file copied while it is being written is not a backup.

```bash
cd /srv/kitchenowl
docker compose stop
sudo tar -czf /srv/kitchenowl/backups/kitchenowl-data-$(date +%F).tar.gz -C /srv/kitchenowl data
docker compose start
sudo tar -czf /srv/kitchenowl/backups/kitchenowl-config-$(date +%F).tar.gz -C /srv/kitchenowl compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/kitchenowl/backups/
```

You should see: two files, the data archive a few hundred kilobytes on a fresh install and the
config archive a couple of kilobytes. The service is down for about five seconds.

If you do not: `tar: data: Cannot open: Permission denied` means you dropped the `sudo`. The
data directory is written by a container running as root, which step 2 warned about. A data
archive of about 45 bytes is an empty tar, which means the path was wrong.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/kitchenowl
scp vps:/srv/kitchenowl/backups/* ~/backups/kitchenowl/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/kitchenowl/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty shopping list:

```bash
cd /srv/kitchenowl
docker compose down
sudo rm -rf /srv/kitchenowl/data
sudo tar -xzf /srv/kitchenowl/backups/kitchenowl-data-$(date +%F).tar.gz -C /srv/kitchenowl
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/onboarding
```

You should see: `onboarding` set to `false`, which means your owner account came back with the
database, and your browser session still signed in when you reload the page.

If you do not: `onboarding` reading `true` after a restore is the worst answer here. It means
the archive did not contain the database, so the server thinks it has no users and is offering
the owner slot to the internet again. Stop, put the container down, and check that the archive
was made with `-C /srv/kitchenowl data` rather than from inside the directory. Being signed out
while onboarding reads `false` is a milder problem: the signing key lives in `.env` rather than
in the database, so a restore that skipped the config archive invalidates every session and
everyone signs in again.

## 9. Updating later

New versions are listed at https://github.com/TomBursch/kitchenowl/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/kitchenowl/compose.yml to the new tag and
its digest.

```bash
cd /srv/kitchenowl
docker compose pull
docker compose up -d
docker compose logs --tail 30 kitchenowl
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done. One thing worth knowing before you
delay an update for months: the phone apps carry a minimum server version of their own, so an
app that stops connecting after a store update is a server that has been left behind rather than
a broken phone.

## 10. What will probably go wrong

The first browser load looks like a failed install. I ran the step 7 checks, got `200`, got the
title back from curl, opened the hostname in a browser and sat looking at an empty off-white
page long enough to start reading logs. Nothing was wrong: the interface is a compiled bundle of
several megabytes that the browser downloads before it paints anything, and the page served in
the meantime carries a background colour and no content. Give it a full minute, reload once, and
only then start checking whether Caddy is reaching 8167.

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
