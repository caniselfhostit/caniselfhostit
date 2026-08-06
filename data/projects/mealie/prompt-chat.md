This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Mealie 3.22.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read this before step 1. `<DOMAIN>` becomes `BASE_URL`, the address Mealie writes into the
invitation links it sends the rest of your household, so changing it later invalidates every
invitation already out. Pick the hostname you intend to keep.

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
resolve, and failed attempts count against a rate limit you cannot see. `armhf` on the third
line is a stop: upstream does not build Mealie for 32-bit ARM, and on a newer Raspberry Pi the
fix is a 64-bit operating system rather than anything in this prompt. Under 1024 MB available
is also a stop. Mealie is a Python service and this install caps it at 1000 MB on purpose, so a
box that cannot spare that will meet the OOM killer during your first bulk import.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mealie /srv/mealie/backups
sudo install -d -m 755 /srv/mealie/data
ls -la /srv/mealie
```

You should see: `backups` owned by you, and `data` at mode `drwxr-xr-x`.

If you do not: nothing here needs fixing by hand. Everything Mealie keeps goes under `data`:
the SQLite database, the recipe photos, and two key files it writes for itself the first time
it starts. Leave its ownership alone. The image runs as uid 911 and chowns /app on the way up,
so after step 7 `ls -la` will show `data` owned by `911` instead of by you. That is the image
working as designed, and it is why the backup command in step 8 uses `sudo`.

## 3. Secrets

One secret, generated here on the server: `ADMIN_PASSWORD`, which step 7 puts on the account
the image seeds in place of the password upstream publishes. Mealie writes its own token
signing keys into `data/` on first start, so there is nothing else to create. Replace
`<DOMAIN>` on the first line with your real hostname before you paste.

```bash
umask 077
cat > /srv/mealie/.env <<EOF
BASE_URL=https://<DOMAIN>
TZ=UTC
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/mealie/.env
umask 022
ls -l /srv/mealie/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens when
the lines are pasted separately into different shells. Run `chmod 600 /srv/mealie/.env` and
carry on. If the file already existed from an earlier attempt, this block has overwritten
`ADMIN_PASSWORD`, which is harmless before step 7 has run and a lockout afterwards, because the
account keeps the password it was actually given.

Do not paste that file, the password, or any command output containing it into this chat
window. The value is yours; read it once with `grep ADMIN_PASSWORD /srv/mealie/.env` after step
7 and put it straight into your password manager.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/mealie/compose.yml <<'EOF'
# Mealie · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install checklist .. https://docs.mealie.io/documentation/getting-started/installation/installation-checklist/
#   sqlite sample ...... https://docs.mealie.io/documentation/getting-started/installation/sqlite/
#   variable reference . https://docs.mealie.io/documentation/getting-started/installation/backend-config/
#   backups ............ https://docs.mealie.io/documentation/getting-started/usage/backups-and-restoring/
#
# One service. Mealie ships a single all-in-one image with SQLite inside it, and
# upstream calls SQLite the right choice at one to twenty users, so there is no
# second container to run or dump. The image writes its own signing keys to
# /app/data/.secret and .session_secret on first start, which is why this
# install generates exactly one secret of its own: the password step 7 puts on
# the account the image seeds. The 1000M ceiling is upstream's recommendation
# for Python, which reserves far more than it needs on a large host. The image
# runs as uid 911 and chowns /app on start, so /srv/mealie/data ends up owned by
# 911 and is read back with sudo. Its own HEALTHCHECK covers /api/app/about, so
# none is repeated here. Tag and digest read from ghcr.io on 2026-08-06; the
# image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:v3.22.0@sha256:36c28f0642fb6c75fae8997a2d55994631b9b4bcffba3016c208fc132a4c1e69
    container_name: mealie
    restart: unless-stopped
    environment:
      # Compose substitutes both from /srv/mealie/.env, which is mode 600 and is
      # never mounted. ADMIN_PASSWORD is in that same file and deliberately not
      # listed here, so no container ever sees it.
      BASE_URL: ${BASE_URL}
      TZ: ${TZ}
      # Nobody can create an account from the login screen. The seeded admin
      # invites the rest of the household instead.
      ALLOW_SIGNUP: "false"
    volumes:
      - /srv/mealie/data:/app/data
    deploy:
      resources:
        limits:
          memory: 1000M
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8117.
      - "127.0.0.1:8117:9000"
EOF
cd /srv/mealie && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/mealie/compose.yml` and paste again in one go. A warning that
`BASE_URL` is not set means you are not in /srv/mealie, or step 3 did not write the file:
Compose reads `.env` from the directory it runs in. There is no database container in this
file, and that is deliberate. Upstream documents a PostgreSQL deployment as well, and SQLite
inside the same image is what they recommend at one to twenty users, which is one less thing to
run, watch and dump.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-mealie
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Mealie · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.mealie.io/documentation/getting-started/installation/security/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# BASE_URL in .env, which Mealie puts inside the invitation links it generates,
# so the two have to stay the same string.

<DOMAIN> {
	# The recipe list is a JavaScript bundle and the API answers JSON. Caddy
	# leaves the already-compressed recipe photos alone.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy here: recipe pages embed YouTube and Vimeo
	# players by design, and a policy written without testing those embeds
	# breaks them in a way that reads as a broken recipe.

	# 8117 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8117
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-mealie /etc/caddy/Caddyfile`, reload,
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
mentioning `8117`.

If you do not: delete anything for `8117` with `sudo ufw delete allow 8117`. That port is bound
to 127.0.0.1 by the compose file, so a firewall rule for it opens a door that leads nowhere and
confuses the next person to read the output. 80/tcp is there to redirect to HTTPS and answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

Mealie runs its migrations on the way up, and that start-up seeds one admin account whose
username and password upstream publishes in its own installation checklist. Until the second
half of this step runs, that is a known credential on a public hostname, so do not stop halfway.

```bash
cd /srv/mealie
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/app/about); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/app/about
curl -sS https://<DOMAIN>/ | grep -o '<title>[^<]*</title>'
```

You should see, in order: the loop reaching `200`, a JSON object containing `"version":"v3.22.0"`
and `"allowSignup":false`, then `<title>Mealie</title>`.

If you do not: the loop can legitimately take a minute or two on a small box, because the
container migrates its database before it answers anything. Give it all thirty attempts before
touching anything. A `502` that never clears means Caddy is reaching nothing on 8117: check
`docker compose ps`. A version string that is not `v3.22.0` means the pull took a different
image than the digest in compose.yml, which is worth stopping over. Then close the seeded
account, which is the part of this install with real security meaning:

```bash
cd /srv/mealie
shipped=MyPassword
token=$(curl -sS -X POST https://<DOMAIN>/api/auth/token --data-urlencode 'username=changeme@example.com' --data-urlencode "password=$shipped" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$token" ] && echo "logged in"
printf '{"currentPassword":"%s","newPassword":"%s"}' "$shipped" "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' /srv/mealie/.env)" | curl -sS -o /dev/null -w '%{http_code}\n' -X PUT https://<DOMAIN>/api/users/password -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' --data-binary @-
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/auth/token --data-urlencode 'username=changeme@example.com' --data-urlencode "password=$shipped"
unset token shipped
```

You should see: `logged in`, then `200`, then `401`.

If you do not: that `401` is the whole point of the block. It is the shipped password being
refused, and until you see it your recipe manager is sitting on the public internet with a
password printed in upstream's documentation. Anything other than `401` on the last line means
stop and do not leave the service running. A missing `logged in` means nothing below it ran
against a real session, most often because the container had not finished starting; wait and
paste the block again. Note that one refused login costs one of the five attempts Mealie allows
before it locks the account for a day, so do not paste the block repeatedly to see the `401`
again. Your next successful sign-in resets that counter.

The first screen at https://<DOMAIN> shows the wordmark `Mealie` over a `Sign in` heading, an
`Email or Username` box, a `Password` box and a `Login` button. Above them sits a first-login
banner printing the shipped email and password. That banner keys off the seeded email address
rather than the password, so it goes on advertising one that no longer works.

Read your password once with `grep ADMIN_PASSWORD /srv/mealie/.env`, put it in your password
manager, then sign in at https://<DOMAIN> as `changeme@example.com`. Change that address to
your own under user settings straight away: it is what clears the banner, and it leaves the
account carrying your name rather than the one the image picked.

## 8. First backup and restore

Two artifacts. The data archive holds the SQLite database, the recipe photos and the two key
files Mealie wrote for itself; the config archive holds the files that rebuild the service
around them. Upstream's advice is to stop the container and copy `data` whole, which is what
this does.

```bash
cd /srv/mealie
docker compose stop
sudo tar -czf /srv/mealie/backups/mealie-data-$(date +%F).tar.gz -C /srv/mealie data
docker compose start
sudo tar -czf /srv/mealie/backups/mealie-config-$(date +%F).tar.gz -C /srv/mealie compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/mealie/backups/
```

You should see: two files, the data archive a few hundred kilobytes on a fresh install and the
config archive a couple of kilobytes. The service is down for about five seconds.

If you do not: `tar: data: Cannot open: Permission denied` means you dropped the `sudo`. The
data directory belongs to uid 911 after the container's first start, which step 2 warned about.
A data archive of about 45 bytes is an empty tar, which means the path was wrong.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/mealie
scp vps:/srv/mealie/backups/* ~/backups/mealie/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/mealie/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty recipe box:

```bash
cd /srv/mealie
docker compose down
sudo rm -rf /srv/mealie/data
sudo tar -xzf /srv/mealie/backups/mealie-data-$(date +%F).tar.gz -C /srv/mealie
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/app/about
```

You should see: the same JSON as in step 7, and your browser session still signed in when you
reload the page.

If you do not: being signed out means the restore did not bring back `data/.secret`, which is
the file Mealie signs login tokens with, so check that the archive really was made with
`-C /srv/mealie data` and not from inside the directory. Understand the stakes before you skip
this: recipes you clipped over five years and photographed yourself are not on anyone else's
server any more, and this archive is the only copy.

## 9. Updating later

New versions are listed at https://github.com/mealie-recipes/mealie/releases, and upstream asks
you to read the release notes before upgrading, not after. Take both backup artifacts first,
then edit the `image:` line in /srv/mealie/compose.yml to the new tag and its digest.

```bash
cd /srv/mealie
docker compose pull
docker compose up -d
docker compose logs --tail 30 mealie
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/api/app/about` check from step 7 and confirm the version it prints is the tag you pinned,
because a container that answers on the old image is an update that did not happen.

## 10. What will probably go wrong

The first thing you will do after step 7 is paste a recipe URL, and one of the first few will
come back empty. I imported a dozen sites cleanly, then got a blank recipe from a large
publisher and read it as a broken scraper. It was not: that site answers a bot check instead of
a page, so there was no recipe markup to read. Mealie reads that markup from hundreds of sites
and cannot read a site that refuses to serve it, or one that draws the ingredients with
JavaScript after the page arrives. No setting fixes that. Paste those recipes in by hand and
carry on; the sites that work are most of them.

## 11. Out of scope

- Do not configure SMTP. Mealie runs without it; the cost is invitation and password-reset
  mail, and the admin can create household accounts by hand instead.
- Do not switch the database to PostgreSQL. SQLite in the one image is the choice here, and
  moving between the two is a restore, not an edit.
- Do not add FlareSolverr or set `SCRAPER_PROXY_URL`. Those get past bot checks at the cost of
  a second service and a third-party relay, for a problem step 10 solves with copy and paste.
- Do not enable OIDC or LDAP. Both need an identity provider this install does not have.
