You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install changedetection.io 0.55.8 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say two things when you ask. One: that hostname
becomes `BASE_URL` in the environment, and notification links and the reverse-proxy sense of
"where am I" use it, so a hostname that does not match the browser address produces wrong links.
Two: until the password step finishes, the UI would be open to anyone who can reach the
hostname; this install closes that door before the first public request by setting
`SALTED_PASS`, not a fictional `PASSWORD` env var.

changedetection.io needs 1024 MB of RAM available and 5 GB free on /srv. The 0.55.8 image
publishes amd64 and arm64. Python 3 on the host is required in step 3 to build the same password
hash upstream uses. Measure:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
command -v python3 && python3 --version
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
hostname that does not resolve. If `python3` is missing, install it from the distro packages
(`sudo apt-get install -y python3` on Debian/Ubuntu) or stop and say why.

This install does **not** include Playwright or sockpuppetbrowser. The plain HTTP fetcher works
for static HTML and many product pages. Sites that paint price or stock only after JavaScript
runs will look empty here until the user adds the browser sidecar later. Name that limit to the
user once in this step so it is not a surprise in week two.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/changedetection /srv/changedetection/backups /srv/changedetection/data
ls -la /srv/changedetection
```

Assert: `ls -la` shows `backups` and `data` owned by the login user. `data` is the host side of
the `/datastore` mount: watches, snapshot history, and any Settings-stored password hash land
there. Nothing is written outside `/srv/changedetection`.

## 3. Secrets

One secret: the UI login password. Upstream does **not** read a `PASSWORD` environment variable.
It accepts either a password typed in Settings, or `SALTED_PASS`: base64 of a 32-byte salt plus a
pbkdf2-hmac-sha256 key at 100000 rounds, the same construction as `SaltyPasswordField` in the
0.55.8 source. Generate the plain password with openssl, hash it with python3, write both into
`.env`, and never print either value into the chat.

```bash
umask 077
LOGIN_PASSWORD="$(openssl rand -base64 24)"
export LOGIN_PASSWORD
SALTED_PASS="$(python3 - <<'PY'
import base64, hashlib, os, secrets
plain = os.environ.get("LOGIN_PASSWORD", "").encode("utf-8")
salt = secrets.token_bytes(32)
key = hashlib.pbkdf2_hmac("sha256", plain, salt, 100000)
print(base64.b64encode(salt + key).decode("ascii"))
PY
)"
cat > /srv/changedetection/.env <<EOF
BASE_URL=https://<DOMAIN>
LOGIN_PASSWORD=${LOGIN_PASSWORD}
SALTED_PASS=${SALTED_PASS}
EOF
chmod 600 /srv/changedetection/.env
umask 022
unset LOGIN_PASSWORD SALTED_PASS
ls -l /srv/changedetection/.env
```

Replace `<DOMAIN>` on the `BASE_URL` line with the real hostname before the block runs. Assert:
the file exists with mode `-rw-------`. Do not print `LOGIN_PASSWORD` or `SALTED_PASS`. Tell the
user their login password is only in that file, read once with
`grep LOGIN_PASSWORD /srv/changedetection/.env`, and put it in a password manager now.
`LOGIN_PASSWORD` is for humans; the process inside the container checks `SALTED_PASS` only.

## 4. compose.yml

```bash
cat > /srv/changedetection/compose.yml <<'EOF'
# changedetection.io · the deterministic fallback. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker ............. https://github.com/dgtlmoon/changedetection.io/blob/0.55.8/README.md#docker
#   compose example .... https://github.com/dgtlmoon/changedetection.io/blob/0.55.8/docker-compose.yml
#   password ........... https://github.com/dgtlmoon/changedetection.io/wiki/Password-protection
#   salted pass ........ SALTED_PASS in changedetectionio/flask_app.py at tag 0.55.8
#   playwright ......... https://github.com/dgtlmoon/changedetection.io/wiki/Playwright-content-fetcher
#
# One service. Watches, history and the hashed UI password live under /datastore.
# SALTED_PASS and BASE_URL come from /srv/changedetection/.env (generated on the
# server). There is no PASSWORD env var in this software: the app checks a
# base64 salt+pbkdf2 hash under SALTED_PASS, or a password set in the Settings
# UI. This install sets SALTED_PASS so the UI is closed from first boot.
# No Playwright / sockpuppetbrowser sidecar: JavaScript-heavy pages need that
# second container and more RAM; the upgrade path is named in the prompts.
# Digest read from Docker Hub on 2026-08-07 for tag 0.55.8.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  changedetection:
    image: dgtlmoon/changedetection.io:0.55.8@sha256:5438423d5e906eff4e8f7886823482ad23f472bf7b8530ccaca89fb48c337882
    container_name: changedetection
    restart: unless-stopped
    env_file: /srv/changedetection/.env
    volumes:
      # Watches, snapshot history, and the Settings-stored password hash.
      - /srv/changedetection/data:/datastore
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8205.
      - "127.0.0.1:8205:5000"
EOF
cd /srv/changedetection && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no database container, no
browser sidecar. Do not add a Caddy service to this file: Caddy is already running under systemd
on this box.

## 5. Caddy and TLS

Write the site block under `/srv/changedetection/Caddyfile`, then append it to the live Caddyfile
with `<DOMAIN>` replaced by the real hostname. Copy the live file first: a syntax error here
takes down every other site on the box.

```bash
cat > /srv/changedetection/Caddyfile <<'EOF'
# changedetection.io · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/dgtlmoon/changedetection.io/wiki/Running-changedetection.io-behind-a-reverse-proxy
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8205 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8205
}
EOF
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-changedetection
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" /srv/changedetection/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `DOMAIN_HOST` to the real hostname from step 1 before running `sed`. That is the house form:
no nested quotes around the replacement. Assert: `caddy validate` exits 0 and the reload exits
0. If validate fails, restore `/etc/caddy/Caddyfile.before-changedetection`, reload, and report
what it objected to. Caddy requests the certificate on the first request and renews it on its
own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8205 stays closed because compose binds it to 127.0.0.1. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8205 or 5000.

## 7. Start and verify

```bash
cd /srv/changedetection
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sS -o /dev/null -w 'unauth_status=%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -ci 'password'
docker compose ps
```

Assert all of the following, and print what you received for each. The loop ends with a 2xx or
3xx status. The unauthenticated status is `302` (or `401`/`403`): with `SALTED_PASS` set, the
app's `before_request` hook sends unauthenticated callers to the login view rather than the
dashboard. The `grep -ci password` count is greater than `0` after following redirects, because
the login form carries a password field. If the unauthenticated status is plain `200` with a
dashboard and no password field, stop: `SALTED_PASS` did not load (check `.env` mode, the
`env_file` line, and `docker compose config`). If Caddy returns 502 with a running container,
step 5 is the likely cause. A running container is not success.

STOP: tell the user to read `grep LOGIN_PASSWORD /srv/changedetection/.env` on the server,
open https://<DOMAIN>/ in a private window, sign in with that password, and confirm they see the
watches dashboard (empty is fine). Do not continue until they confirm.

After they confirm, re-check that a cold unauthenticated request is still refused:

```bash
curl -sS -o /dev/null -w 'still_unauth=%{http_code}\n' https://<DOMAIN>/
```

Assert: that status is still not a dashboard-serving bare `200` without auth. Print the code.

## 8. First backup and restore

One archive: the datastore (the real mounted state), the compose file, `.env`, and the live
Caddy site block. Take it now, before there is a month of watch history to lose.

```bash
cd /srv/changedetection
docker compose stop
sudo tar -czf /srv/changedetection/backups/changedetection-$(date +%F).tar.gz \
  -C /srv/changedetection data compose.yml .env \
  -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/changedetection/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is short; the container is
stopped on purpose so files under `data/` are not half-written. Never append `|| true` to this
tar: a failed backup must fail the step.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/changedetection
scp vps:/srv/changedetection/backups/*.tar.gz ~/backups/changedetection/
```

To restore: `cd /srv/changedetection`, `docker compose down`, move aside the current `data` and
`.env`, untar the archive into `/srv/changedetection` (and put the Caddyfile back under
`/etc/caddy` if that is what was lost), then `docker compose up -d`. Tell the user which half
matters: `data/` is every watch and every snapshot, and `.env` is how they log in. Losing
`.env` without a copy of `LOGIN_PASSWORD` is a lockout (upstream also documents a
`removepassword.lock` escape hatch under `/datastore` if they ever need it). Losing `data/`
costs the product.

## 9. Updating later

New versions are listed at https://github.com/dgtlmoon/changedetection.io/releases. The image tag
tracks the release. Take a backup first, then edit the image line in
`/srv/changedetection/compose.yml` to the new tag and its digest:

```bash
cd /srv/changedetection
docker compose pull
docker compose up -d
docker compose logs --tail 30 changedetection
```

Re-run step 7's unauthenticated-refusal check after every upgrade. If the user later needs
JavaScript rendering, the upgrade path is the upstream sockpuppetbrowser / Playwright sidecar:
add a browser service, set `PLAYWRIGHT_DRIVER_URL=ws://browser-sockpuppet-chrome:3000` (or the
name they chose), raise RAM, and follow
https://github.com/dgtlmoon/changedetection.io/wiki/Playwright-content-fetcher. Do not add that
sidecar in this install unless they explicitly ask after reading the memory cost.

## 10. What will probably go wrong

You will add a watch against a modern storefront, wait for the interval, and get a snapshot that
looks like an empty shell or a "enable JavaScript" page. I hit that on the first price I cared
about. This install ships the plain fetcher only; it does not run a browser. The fix is not
"check more often". It is either a CSS/JSON selector against HTML that really is in the first
response, or the Playwright/sockpuppetbrowser path named in step 9. Until one of those is true,
a polite interval just records the same empty shell more carefully.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy is already running under systemd on
  this box, and a second one would fight it for 80 and 443.
- Do not publish 8205 on `0.0.0.0` or open it in the firewall. Caddy is the only way in.
- Do not invent a `PASSWORD` environment variable. Upstream does not read one.
- Do not add Playwright, sockpuppetbrowser, Selenium, or a second browser container unless the
  user explicitly asks after the limitation in steps 1 and 9 is clear.
- Do not skip the first backup or the unauthenticated-refusal assert.
