This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing changedetection.io 0.55.8 on a VPS where Prompt Zero is done: `ssh vps`
works, Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record
already points at the box.

Read these before step 1. The hostname becomes `BASE_URL`, so it must match what you type in the
browser. Upstream has no `PASSWORD` env var: this install builds `SALTED_PASS` (salt +
pbkdf2-hmac-sha256, base64) the same way the Settings UI does, so the UI is closed from first
boot. There is no Playwright or sockpuppetbrowser container here; JavaScript-only storefronts may
snapshot as empty shells until you add that sidecar later (wiki: Playwright-content-fetcher).


Also know: the datastore path inside the container is `/datastore`, which this install binds to
`/srv/changedetection/data` on the host. Backups must archive that directory, not an empty sibling
folder. Notifications use Apprise URL schemes you paste into a watch; nothing here signs you up
for Discord, Slack or email for you. Polite recheck intervals matter: this is a watcher, not a
load generator.

If you forget the UI password later, upstream documents an escape hatch: create
`/datastore/removepassword.lock` inside the container (or `data/removepassword.lock` on the host)
and restart, then set a new password. Prefer restoring `.env` from backup instead.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
command -v python3 && python3 --version
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, your
server's IP on the dig line, and a python3 version. If dig is empty, add the A record and wait.
If python3 is missing, install it (`sudo apt-get install -y python3` on Debian/Ubuntu) before step 3.

If free memory is under 1024 MB, stop. Adding the browser sidecar later will want more still; do
not start from a box that is already below the floor. arm/v7 is not the target of this pin's
verified path; stick to amd64 or arm64.



## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/changedetection /srv/changedetection/backups /srv/changedetection/data
ls -la /srv/changedetection
```

You should see: `backups` and `data` under `/srv/changedetection`, owned by your login user.
`data` is the host side of `/datastore` (watches, history, settings).

## 3. Secrets

One secret. Generate on the server. Do not paste the password into this chat after it prints in
your terminal for the `grep` read later.

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

Replace `<DOMAIN>` on `BASE_URL` with your real hostname before you run the block. You should
see mode `-rw-------`. Read the password later with
`grep LOGIN_PASSWORD /srv/changedetection/.env` and put it in a password manager.
`LOGIN_PASSWORD` is for you; the container checks `SALTED_PASS` only.

If `python3` is missing on a minimal image, install it before this block. Do not try to invent a
a fictional PASSWORD environment line; the process ignores it. Do not commit the env file under /srv to a git repo.



## 4. compose.yml

Paste this whole block. It must match the project's compose file byte for byte between the
markers.

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

You should see: `compose OK`. One service, port 8205 on loopback only. Do not add a Caddy
service here; Caddy already runs under systemd on the host.

## 5. Caddy and TLS

Write the site block, then append it with the hostname substituted. Copy the live Caddyfile
first.

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

Set `DOMAIN_HOST` to your real hostname (no quotes inside the sed replacement). `caddy validate`
and the reload must both exit 0. If validate fails, restore
`/etc/caddy/Caddyfile.before-changedetection`, reload, and fix the syntax. Caddy requests the
certificate on the first request and renews it on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for 80 and 443, and nothing for 8205 or 5000. 8205 stays
closed because compose binds it to 127.0.0.1.

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

You should see: a 2xx or 3xx from the loop; `unauth_status` of `302` (or `401`/`403`), not an
open dashboard; a password-field count greater than `0` after following redirects. If unauth is a
bare `200` with the watches UI and no password field, `SALTED_PASS` did not load: check `.env`
mode 600, the `env_file` line, and `docker compose config`. If Caddy returns 502, re-check step
5. A running container alone is not success.

Common misreads on this step: a `200` on the loop can still be the login page after a redirect
chain your curl did not show. Always print `unauth_status` without `-L` and the password-field
count with `-L`. Empty `docker compose ps` means pull or start failed; read
`docker compose logs --tail 40 changedetection` before changing Caddy. If validate passed and
the container is healthy but the public URL times out, the A record or firewall step is wrong,
not the image pin.



STOP: read `grep LOGIN_PASSWORD /srv/changedetection/.env` on the server, open
https://<DOMAIN>/ in a private window, sign in, and confirm you see the watches dashboard (empty
is fine). Do not continue until they confirm.

Then re-check:

```bash
curl -sS -o /dev/null -w 'still_unauth=%{http_code}\n' https://<DOMAIN>/
```

That status must still show an unauthenticated refusal, not an open dashboard.

## 8. First backup and restore

Archive the real mounted state (`data/` is `/datastore`), compose, `.env`, and the live Caddyfile.

```bash
cd /srv/changedetection
docker compose stop
sudo tar -czf /srv/changedetection/backups/changedetection-$(date +%F).tar.gz \
  -C /srv/changedetection data compose.yml .env \
  -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/changedetection/backups/
```

The archive must exist and be non-empty; print its size. Do not append `|| true` to tar. From
your laptop (not the server):

```bash
mkdir -p ~/backups/changedetection
scp vps:/srv/changedetection/backups/*.tar.gz ~/backups/changedetection/
```

To restore: `cd /srv/changedetection`, `docker compose down`, move aside `data` and `.env`, untar
into `/srv/changedetection` (restore `/etc/caddy/Caddyfile` if that half was lost), then
`docker compose up -d`. `data/` is the watches; `.env` is the login. Upstream also documents
`removepassword.lock` under `/datastore` if you ever need an emergency password reset.

After restore, re-run the unauthenticated-refusal curl from step 7 before you trust the UI. If
`.env` restored but `data/` did not, you can log in to an empty instance. If `data/` restored but
`.env` did not, you still have the watches on disk and need either the old `LOGIN_PASSWORD` or the
`removepassword.lock` procedure, then a new password in Settings.



## 9. Updating later

Releases: https://github.com/dgtlmoon/changedetection.io/releases. Backup first, edit the image
line in `/srv/changedetection/compose.yml` to the new tag and digest, then:

```bash
cd /srv/changedetection
docker compose pull
docker compose up -d
docker compose logs --tail 30 changedetection
```

Re-run the unauthenticated-refusal check from step 7 after every upgrade. For JavaScript-heavy
pages later, add the sockpuppetbrowser / Playwright sidecar and
`PLAYWRIGHT_DRIVER_URL` per
https://github.com/dgtlmoon/changedetection.io/wiki/Playwright-content-fetcher, and budget the
extra RAM. Do not add it until you know you need it.

When you pin a new digest, record it in a note next to the release tag so the next upgrade is a
diff you can read. If an upgrade restarts into a crash loop, roll back the image line to the
previous pin, `docker compose up -d`, and only then inspect migration logs. Do not run two
changedetection containers against the same `data/` directory.



## 10. What will probably go wrong

You will add a watch against a modern storefront, wait for the interval, and get a snapshot that
looks like an empty shell or a "enable JavaScript" page. This install ships the plain fetcher
only; it does not run a browser. Checking more often will not fill an empty shell. Fix it with a
selector against HTML that really is in the first response, or with the Playwright path in step
9. The second common failure is a notification URL you never tested: wire Apprise, send a
deliberate change, and confirm the channel before trusting silence.

A third failure mode is `BASE_URL` disagreeing with the browser hostname: notification links and
some UI redirects point at whatever was written into `.env`. If you rename the site later, update
`BASE_URL` and recreate the container so the new value loads. Fourth: filling the disk under
`data/` with long snapshot history. Prune old history from the UI when the volume grows past what
you meant to keep, and keep the off-box backup current before you prune.



## 11. Out of scope

- Do not add a Caddy container to compose. Caddy already runs under systemd on this host.
- Do not publish 8205 on `0.0.0.0` or open it in the firewall.
- Do not invent a `PASSWORD` environment variable. Upstream does not read one.
- Do not add Playwright, sockpuppetbrowser, or Selenium unless you explicitly decide to after
  reading the memory cost in step 9.
- Do not skip the first backup or the unauthenticated-refusal assert.


Hostname discipline: every place you type the public name must match. That is `BASE_URL` in
`.env`, the Caddy site address after sed, and the URL you open in the browser. A missing A
record fails Caddy; a wrong `BASE_URL` fails links and notification targets.

Security discipline: until `SALTED_PASS` is present and loaded, the UI is open. This path writes
the hash before `docker compose up`. If you ever recreate `.env` without `SALTED_PASS`, the next
start is open again. After every recreate, re-run the unauthenticated curl and confirm a
redirect or refusal, not a bare dashboard.

State discipline: `/srv/changedetection/data` is the product. Watches, history, tags and any
password later saved through Settings live there. Backups that archive only `compose.yml` are
not backups of changedetection.

Fetcher discipline: the plain HTTP client is what runs today. Visual Selector, browser steps and
many restock flows expect Playwright. Plan RAM before you uncomment a browser service. The
upstream wiki page for that is Playwright-content-fetcher; follow it when you need it, not
before.

Operational discipline: first backup tonight, off the box. Second backup after you add the first
ten watches. Update by pin and digest, never by floating `latest`. This path is NOT YET VERIFIED
on a clean harness machine; treat the asserts as the contract and stop when they fail.

If a step's assert fails, name the earlier step that most likely caused it before changing
anything else. Preflight failures are step 1. Missing password on the public URL is step 3.
Compose config errors are step 4. Certificate or 502 problems are step 5. Open ports that should
be closed are step 6. Dashboard without a login form is step 3 or 7. Empty backups are step 8.

NOT YET VERIFIED: no harness run has been recorded against this install path.
