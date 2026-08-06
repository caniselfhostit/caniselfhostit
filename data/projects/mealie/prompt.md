You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Mealie 3.22.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname becomes
`BASE_URL`, which Mealie writes into the invitation links it sends the rest of the household,
so changing it later invalidates every invitation already out.

Mealie needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64; upstream does not support 32-bit ARM. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. Stop on `armhf` too. If `dig +short` prints nothing, print that and
stop: Caddy cannot get a certificate for a name that does not resolve, and failed attempts
count against a rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mealie /srv/mealie/backups
sudo install -d -m 755 /srv/mealie/data
ls -la /srv/mealie
```

Assert: `ls -la` shows `backups` owned by the login user and `data` present. Everything Mealie
keeps lives under `data`: the SQLite database, the recipe photos, and the two key files it
writes for itself on first start. Leave its ownership alone. The image runs as uid 911 and
chowns /app on the way up, so after step 7 that directory belongs to 911 and is read back with
sudo. That is the image working as designed.

## 3. Secrets

One secret, generated here on the server: `ADMIN_PASSWORD`, which step 7 puts on the account
the image seeds in place of the password upstream publishes. Mealie writes its own token
signing keys at `data/.secret` and `data/.session_secret` on first start, so there is nothing
else to create. Hex, not base64: it travels inside a JSON body. Do not print it, do not repeat
it in your summary, and keep it out of every log line.

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

Assert: the file exists with mode `-rw-------` and the login user's name twice. Docker Compose
reads it for the `${...}` substitutions in compose.yml whenever it runs from /srv/mealie, so
`BASE_URL` and `TZ` reach the container and the file is never mounted. `ADMIN_PASSWORD` is not
a Mealie setting and no container sees it: step 7 hands it to the running API and it stays here
as the user's only copy.

## 4. compose.yml

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

Assert: that prints `compose OK`. One service, one published port, one bind mount. Upstream
documents a PostgreSQL deployment too and this install ignores it: SQLite in the same image is
what upstream recommends at household scale, and it is one less thing to operate.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-mealie, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it on its own. Nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's, and both idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3, and 8117 stays closed because compose binds it to 127.0.0.1. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8117.

## 7. Start and verify

Mealie runs its migrations on the way up, and that same start-up seeds one admin account whose
username and password upstream publishes in its installation checklist. Until the second half
of this step runs, that is a known credential on a public hostname. Bring it up and prove it
answers:

```bash
cd /srv/mealie
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/app/about); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/app/about
curl -sS https://<DOMAIN>/ | grep -o '<title>[^<]*</title>'
```

Assert all three, and print what you received for each: the loop ends on `200`; the JSON
contains `"version":"v3.22.0"`, the running container agreeing with the pinned digest, and
`"allowSignup":false`; the last command prints `<title>Mealie</title>`. If any of the three
misses, stop, run `docker compose logs --tail 40 mealie`, and name the likely earlier step: a
`502` instead of `200` means Caddy is reaching nothing on 8117, and a container restarting in a
loop points at step 2. A running container is not success.

Now close the seeded account. Its email is `changeme@example.com` and its password is
`MyPassword`, both printed in the upstream checklist, so anyone who reads that page can sign
in until this runs:

```bash
cd /srv/mealie
shipped=MyPassword
token=$(curl -sS -X POST https://<DOMAIN>/api/auth/token --data-urlencode 'username=changeme@example.com' --data-urlencode "password=$shipped" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$token" ] && echo "logged in"
printf '{"currentPassword":"%s","newPassword":"%s"}' "$shipped" "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' /srv/mealie/.env)" | curl -sS -o /dev/null -w '%{http_code}\n' -X PUT https://<DOMAIN>/api/users/password -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' --data-binary @-
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/auth/token --data-urlencode 'username=changeme@example.com' --data-urlencode "password=$shipped"
unset token shipped
```

Assert all three: `logged in`, then `200` from the update, then `401` from the second login.
That `401` is the security assert in this block and it decides whether this install is safe to
leave running. If the first line does not print `logged in`, nothing below it ran against a
real session, so stop there. If the last prints anything other than `401`, the published
password still works: stop, say so plainly, and do not report success. The new password was
piped into curl from the file rather than typed on a command line, so it never reaches the
process list, and neither it nor the token enters your output. The rejected login costs one
of the five tries Mealie allows before it locks an account for a day; the next successful
sign-in resets that counter.

The first screen at https://<DOMAIN> shows the wordmark `Mealie` over a `Sign in` heading, an
`Email or Username` box, a `Password` box and a `Login` button. Above them sits a first-login
banner printing the shipped email and password; it keys off that email address rather than the
password, so it goes on advertising one that no longer works.

STOP: tell the user to read their password with `grep ADMIN_PASSWORD /srv/mealie/.env`, put it
in their password manager, sign in at https://<DOMAIN> as `changeme@example.com`, and confirm
the recipe page loads. Wait. Do not continue until they confirm. Then tell them to put their
own address on the account under user settings, which is what clears that banner.

## 8. First backup and restore

Two artifacts. The data archive holds the SQLite database, the recipe photos and the two key
files Mealie wrote for itself; the config archive holds the files that rebuild the service
around them. Upstream's advice is to stop the container and copy `data` whole, which is what
runs here; downtime is a few seconds.

```bash
cd /srv/mealie
docker compose stop
sudo tar -czf /srv/mealie/backups/mealie-data-$(date +%F).tar.gz -C /srv/mealie data
docker compose start
sudo tar -czf /srv/mealie/backups/mealie-config-$(date +%F).tar.gz -C /srv/mealie compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/mealie/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. A backup on the same disk as
the data is not a backup, so run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/mealie
scp vps:/srv/mealie/backups/* ~/backups/mealie/
```

To restore: `docker compose down`, `sudo rm -rf /srv/mealie/data`,
`sudo tar -xzf /srv/mealie/backups/mealie-data-<date>.tar.gz -C /srv/mealie`, untar the config
archive into /srv/mealie so compose.yml and .env are back, then `docker compose up -d`. Tell
the user the fact that matters at 2am: the recipes, the photos and the signing keys all live
inside `data`, so restoring that one directory restores everything and nobody is logged out.

## 9. Updating later

New versions are listed at https://github.com/mealie-recipes/mealie/releases, and upstream asks
you to read the release notes before upgrading, not after. Take both backup artifacts first,
then edit the image line in /srv/mealie/compose.yml to the new tag and its digest:

```bash
cd /srv/mealie
docker compose pull
docker compose up -d
docker compose logs --tail 30 mealie
```

Mealie migrates its own database on the way up: watch that log until it settles, then re-run
the `/api/app/about` check from step 7 and confirm the version matches the tag you pinned.

## 10. What will probably go wrong

The first thing the user does after step 7 is paste a recipe URL, and one of the first few will
come back empty. I imported a dozen sites cleanly, then got a blank recipe from a large
publisher and read it as a broken scraper. It was not: that site answers a bot check instead of
a page, so there was no recipe markup to read. Mealie reads that markup from hundreds of sites
and cannot read a site that refuses to serve it, or one that draws the ingredients with
JavaScript after the page arrives. No setting fixes that. Tell the user to paste those recipes
in by hand and carry on; the sites that work are most of them.

## 11. Out of scope

- Do not configure SMTP. Mealie runs without it; the cost is invitation and password-reset
  mail, and the admin can create household accounts by hand instead.
- Do not switch the database to PostgreSQL. SQLite in the one image is the choice here, and
  moving between the two is a restore, not an edit.
- Do not add FlareSolverr or set `SCRAPER_PROXY_URL`. Those get past bot checks at the cost of
  a second service and a third-party relay, for a problem step 10 solves with copy and paste.
- Do not enable OIDC or LDAP. Both need an identity provider this install does not have.
