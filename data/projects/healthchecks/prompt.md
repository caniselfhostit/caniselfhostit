You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Healthchecks v4.3 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask for both once and stop until the user
answers. The A record must already point here. In the same message ask three more things and
then stop asking: an SMTP relay hostname they already have, its port, and their username on it.
Do not ask for the relay credential; a STOP in step 3 has the user type that in themselves.
Healthchecks needs 1024 MB of RAM available and 5 GB free on /srv, on amd64 or arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If RAM is under 1024 MB or disk under 5 GB, print both and stop. If `dig +short` prints
nothing, stop: Caddy cannot certify a hostname that does not resolve.

## 2. Layout

The image creates /data and hands it to a system account called `hc`. Ask the image which uid
that is, rather than assuming: a system uid is assigned at build time.

```bash
IMG=healthchecks/healthchecks:v4.3@sha256:cd7bcd94350818b3944f82eb5995f48bdeab8c8627977578a569ffa73f56f56f
docker pull "$IMG"
HCUID=$(docker run --rm "$IMG" id -u hc)
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/healthchecks /srv/healthchecks/backups
sudo install -d -m 750 -o "$HCUID" -g "$HCUID" /srv/healthchecks/data
ls -la /srv/healthchecks
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by a numeric uid.
Nothing is written outside /srv/healthchecks.

## 3. Secrets

One secret is generated here: the Django `SECRET_KEY`. Do not print it, repeat it in your
summary, or log it. Replace `smtp.example.net`, `587` and `EMAIL_HOST_USER` with the step 1
values.

```bash
umask 077
cat > /srv/healthchecks/.env <<EOF
SECRET_KEY=$(openssl rand -base64 48)
SITE_ROOT=https://<DOMAIN>
SITE_NAME=Checks
ALLOWED_HOSTS=<DOMAIN>
DB=sqlite
DB_NAME=/data/hc.sqlite
REGISTRATION_OPEN=True
DEFAULT_FROM_EMAIL=<ADMIN_EMAIL>
EMAIL_HOST=smtp.example.net
EMAIL_PORT=587
EMAIL_HOST_USER=<ADMIN_EMAIL>
EMAIL_USE_TLS=True
EOF
chmod 600 /srv/healthchecks/.env
ls -l /srv/healthchecks/.env
```

Assert: mode `-rw-------`. `SITE_ROOT` is what every absolute link is built from, ping URLs
included, so it carries https even though the container speaks plain HTTP to Caddy.

STOP: tell the user to open their own terminal and run the block below on the server, so the
relay credential never enters this session. The third line waits with no prompt and echoes
nothing. Wait until they report what the last line printed.

```bash
umask 077
printf 'EMAIL_HOST_PASSWORD=' >> /srv/healthchecks/.env
read -rs && printf '%s\n' "$REPLY" >> /srv/healthchecks/.env
unset REPLY
chmod 600 /srv/healthchecks/.env
sudo awk -F= '/^EMAIL_HOST_PASSWORD/ {print "recorded, length " length($2)}' /srv/healthchecks/.env
```

Assert: a length greater than 0. Nothing printed means the line is missing.

## 4. compose.yml

```bash
cat > /srv/healthchecks/compose.yml <<'EOF'
# Healthchecks · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image and proxy notes . https://github.com/healthchecks/healthchecks/blob/master/docker/README.md
#   configuration ......... https://healthchecks.io/docs/self_hosted_configuration/
#
# One container. DB=sqlite means no database process to operate: the instance is
# one file at /data/hc.sqlite, and uWSGI runs migrations on boot and keeps
# sendalerts alive, so there is no cron job. Tag and digest are the v4.3 release
# read from Docker Hub on 2026-08-05, for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  healthchecks:
    image: healthchecks/healthchecks:v4.3@sha256:cd7bcd94350818b3944f82eb5995f48bdeab8c8627977578a569ffa73f56f56f
    container_name: healthchecks
    restart: unless-stopped
    env_file: /srv/healthchecks/.env
    volumes:
      # Owned by the hc uid, hence step 2. SQLite needs real POSIX file locks.
      - /srv/healthchecks/data:/data
    ports:
      # Loopback only. The Caddy that Prompt Zero installed on the host is the
      # only thing that can reach this port, and 8088 never enters the firewall.
      - "127.0.0.1:8088:8000"
EOF
cd /srv/healthchecks && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on 8000 inside itself; 8088 is bound to
127.0.0.1, so the only route in is Caddy.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-healthchecks
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Healthchecks · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://caddyserver.com/docs/automatic-https
# and https://github.com/healthchecks/healthchecks/blob/master/docker/README.md
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. Caddy runs under systemd. No Caddy container here.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8088 is the loopback port compose publishes; it is never in the firewall.
	# Caddy replaces any client-supplied X-Forwarded-Proto with the real scheme,
	# which is what uWSGI in this image reads to decide a request is secure.
	reverse_proxy 127.0.0.1:8088
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-healthchecks,
reload, and report what it objected to. Caddy gets the certificate on the first request.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8088 stays closed, bound to 127.0.0.1, and nothing opens 25, 465 or 587: this box
sends through the user's relay and accepts no mail. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no 8088.

## 7. Start and verify

uWSGI runs the migrations as it boots, so the first start writes hc.sqlite and is the slow one.

```bash
cd /srv/healthchecks
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v3/status/
curl -sS https://<DOMAIN>/accounts/login/ | grep -c 'id="signup-modal"'
```

Assert: the first prints `200`, the second a number greater than 0, and print what you
received. The first is the image's own health-check endpoint and answers 200 only when the
database connection is alive, which is worth more than a green `docker ps`. If either misses,
stop, run `docker compose logs --tail 40 healthchecks`, and name the likely earlier step. The
first screen at https://<DOMAIN> is a sign-in form headed `Log In to Checks`, with an
`Email Me a Link` button and a `Sign Up` link that opens the sign-up form. `/accounts/signup/`
takes POST only, so there is no page to open there.

STOP: tell the user to open https://<DOMAIN>, click `Sign Up`, sign up with <ADMIN_EMAIL>, and
click the link they are emailed. Wait until they confirm they are signed in. If no mail
arrives, send them to step 10 before anything is changed.

Now close registration, so this is not a public signup form:

```bash
sed -i 's/^REGISTRATION_OPEN=True$/REGISTRATION_OPEN=False/' /srv/healthchecks/.env
cd /srv/healthchecks && docker compose up -d --force-recreate
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v3/status/
curl -sS https://<DOMAIN>/accounts/login/ | grep -c 'id="signup-modal"' || true
```

Assert: the first prints `200`, the second `0`. Print both. That `0` is the security assert,
`signup-modal` being the id of the sign-up form itself, so it counts the form gone from the
log-in page; `grep -c` exits 1 counting nothing, hence `|| true`. It stops a stranger who finds
the hostname creating an account here.

## 8. First backup and restore

Take the backup now, before the user adds a check. Stop first: SQLite copied mid-write is not a
backup.

```bash
cd /srv/healthchecks
docker compose stop
sudo tar -C /srv/healthchecks -czf /srv/healthchecks/backups/healthchecks-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/healthchecks/backups/
```

Assert: the archive exists and is non-empty. Print its size. `data` plus `.env` is the whole
install, relay credential included. A backup on the same disk is not one, so run this from the
user's machine:

```bash
mkdir -p ~/backups/healthchecks
scp vps:/srv/healthchecks/backups/*.tar.gz ~/backups/healthchecks/
```

To restore: `docker compose down`, `sudo rm -rf /srv/healthchecks/data`,
`sudo tar -C /srv/healthchecks -xzf` the archive, then `docker compose up -d`. Checks, history
and ping URLs all live in `data/hc.sqlite`, so URLs already in crontabs elsewhere survive.
Those four commands are the whole disaster plan.

## 9. Updating later

New versions are at https://github.com/healthchecks/healthchecks/releases. Back up first, then
edit the image line in /srv/healthchecks/compose.yml to the new tag and digest. uWSGI migrates
on the next boot, so read the log until it settles before calling this done.

```bash
cd /srv/healthchecks
docker compose pull
docker compose up -d
docker compose logs --tail 20 healthchecks
```

## 10. What will probably go wrong

The signup email will not arrive, and the install will look broken when it is not. Hetzner
blocks outbound 25, 465 and 587 on new cloud accounts until you open a support ticket, and
DigitalOcean restricts them too. I sat watching an empty inbox for ten minutes with a container
that had been answering 200 the whole time. Run `docker compose logs --tail 40 healthchecks`
and look for a timeout to the relay host. That is the provider, and the fix is a ticket with a
lead time in days.

## 11. Out of scope

- Do not switch the database to PostgreSQL. SQLite is why this is one file to copy.
- Do not set `SMTPD_PORT` or open an inbound mail listener. This install only sends.
- Do not configure Slack, Telegram or any other channel. Each is an account elsewhere.
- Do not add a cron job for alerts. uWSGI keeps `sendalerts` running already.
