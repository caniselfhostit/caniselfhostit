You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install DocuSeal 3.1.7 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask for both once and stop until the user
answers. The A record must already point here. In the same message ask three more things and
then stop asking: an SMTP relay hostname they already have, its port, and their username on it.
Do not ask for the relay credential; a STOP in step 3 has the user type that in themselves.
DocuSeal renders PDFs, so it needs 2048 MB of RAM available and 10 GB free on /srv, on amd64 or
arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If RAM is under 2048 MB or disk under 10 GB, print both and stop. If `dig +short` prints
nothing, stop: Caddy cannot certify a hostname that does not resolve.

## 2. Layout

The image creates a `docuseal` account with uid 2000 and runs as it, so `data` belongs to 2000.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/docuseal /srv/docuseal/backups
sudo install -d -m 750 -o 2000 -g 2000 /srv/docuseal/data
ls -la /srv/docuseal
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by `2000`.

## 3. Secrets

One secret is generated here: `SECRET_KEY_BASE`. Do not print it, repeat it in your summary, or
log it. Replace `smtp.example.net`, `587` and `SMTP_USERNAME` with the step 1 values.

```bash
umask 077
cat > /srv/docuseal/.env <<EOF
SECRET_KEY_BASE=$(openssl rand -hex 64)
HOST=<DOMAIN>
FORCE_SSL=<DOMAIN>
SMTP_ADDRESS=smtp.example.net
SMTP_PORT=587
SMTP_DOMAIN=<DOMAIN>
SMTP_USERNAME=<ADMIN_EMAIL>
SMTP_ENABLE_STARTTLS=true
EOF
chmod 600 /srv/docuseal/.env
ls -l /srv/docuseal/.env
```

Assert: mode `-rw-------`. Tell the user one thing and make it stick: `SECRET_KEY_BASE` is also
what the record encryption keys are derived from, so changing it later makes every stored
signature unreadable. Step 8 backs it up with the database, and those two belong together.

STOP: tell the user to open their own terminal and run the block below on the server, so the
relay credential never enters this session. The third line waits with no prompt and echoes
nothing. Wait until they report what the last line printed.

```bash
umask 077
printf 'SMTP_PASSWORD=' >> /srv/docuseal/.env
read -rs && printf '%s\n' "$REPLY" >> /srv/docuseal/.env
unset REPLY
chmod 600 /srv/docuseal/.env
sudo awk -F= '/^SMTP_PASSWORD/ {print "recorded, length " length($2)}' /srv/docuseal/.env
```

Assert: a length greater than 0. Nothing printed means the line is missing.

## 4. compose.yml

```bash
cat > /srv/docuseal/compose.yml <<'EOF'
# DocuSeal · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image, port, /data .. https://github.com/docusealco/docuseal/blob/master/README.md
#   database selection .. https://github.com/docusealco/docuseal/blob/master/config/database.yml
#   SMTP and FORCE_SSL .. https://github.com/docusealco/docuseal/blob/master/config/environments/production.rb
#
# One container. With DATABASE_URL unset the app uses SQLite at $WORKDIR/db.sqlite3,
# and the image already sets WORKDIR=/data/docuseal, so the single mount below
# holds the database, the uploaded documents and the signed PDFs. The image runs
# as uid 2000, hence the ownership in step 2. Tag and digest are the 3.1.7
# release read from Docker Hub on 2026-08-05, for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  docuseal:
    image: docuseal/docuseal:3.1.7@sha256:a8ce45fc96cb0b8670021ba781966591a1d09efb70882c920a465e87e4fea800
    container_name: docuseal
    restart: unless-stopped
    env_file: /srv/docuseal/.env
    volumes:
      # Database, attachments and signed documents, all in one directory.
      - /srv/docuseal/data:/data/docuseal
    ports:
      # Loopback only. The Caddy that Prompt Zero installed on the host is the
      # only thing that can reach this port, and 8089 never enters the firewall.
      - "127.0.0.1:8089:3000"
EOF
cd /srv/docuseal && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Upstream's own compose file runs PostgreSQL beside the app;
this one does not, because a single-person install on SQLite is one process and one directory.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-docuseal
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# DocuSeal · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://caddyserver.com/docs/automatic-https
# and https://github.com/docusealco/docuseal/blob/master/README.md
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. Caddy runs under systemd. No Caddy container here.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# No X-Frame-Options here: DocuSeal publishes an embeddable signing form,
	# and a blanket SAMEORIGIN would break it for anyone who uses that later.
	#
	# 8089 is the loopback port compose publishes; it is never in the firewall.
	# FORCE_SSL in .env makes Rails trust the X-Forwarded-Proto Caddy sets, so
	# the signing links it emails come out as https.
	reverse_proxy 127.0.0.1:8089
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-docuseal, reload,
and report what it objected to. Caddy gets the certificate on the first request.

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
is HTTP/3. 8089 stays closed, bound to 127.0.0.1, and nothing opens 25, 465 or 587: this box
sends through the user's relay and accepts no mail. Assert: `ufw status verbose` prints
`Status: active`, shows 80, 443/tcp and 443/udp, and no 8089.

## 7. Start and verify

Rails migrates as it boots, so the first start is the slow one. Do not follow redirects in
these checks: the redirect is the signal.

```bash
cd /srv/docuseal
docker compose pull
docker compose up -d
sleep 45
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/up
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
```

Assert: both print `200`, and print what you received. `/up` is the Rails health route and
answers only once the app has booted; `/setup` is the first-run form and answers 200 exactly
while no user exists. If either misses, stop, run `docker compose logs --tail 40 docuseal`, and
name the likely earlier step. A running container is not success.

The first screen at https://<DOMAIN> redirects to the setup form, which asks for a name, an
email address and a password for the first account.

STOP: tell the user to open https://<DOMAIN>/setup, create that first account with
<ADMIN_EMAIL>, and confirm when they are signed in. Wait. Until they do, whoever finds the
hostname can create it instead.

Now prove the setup form has closed itself:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
```

Assert: this prints `302`, not `200`. DocuSeal redirects /setup to the sign-in page once a user
exists, and that is the security assert here. If it still prints `200`, the account was not
created and the hostname is standing open.

## 8. First backup and restore

Take the backup now, before the first real document. Stop first: SQLite copied mid-write is not
a backup.

```bash
cd /srv/docuseal
docker compose stop
sudo tar -C /srv/docuseal -czf /srv/docuseal/backups/docuseal-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/docuseal/backups/
```

Assert: the archive exists and is non-empty. Print its size. `data` and `.env` travel together:
the documents are in `data`, and the key that decrypts the encrypted columns comes from
`SECRET_KEY_BASE` in `.env`. A backup on the same disk is not one, so run this from the user's
machine:

```bash
mkdir -p ~/backups/docuseal
scp vps:/srv/docuseal/backups/*.tar.gz ~/backups/docuseal/
```

To restore: `docker compose down`, `sudo rm -rf /srv/docuseal/data`,
`sudo tar -C /srv/docuseal -xzf` the archive, then `docker compose up -d`. Those four commands
are the whole disaster plan. A signed agreement is a document somebody else is relying on, so
this archive belongs somewhere the user would still have after a fire.

## 9. Updating later

New versions are at https://github.com/docusealco/docuseal/releases. Back up first, then edit
the image line in /srv/docuseal/compose.yml to the new tag and digest. Rails migrates on the
next boot, so read the log until it settles before calling this done.

```bash
cd /srv/docuseal
docker compose pull
docker compose up -d
docker compose logs --tail 20 docuseal
```

## 10. What will probably go wrong

The signing invitation will not arrive, and the install will look fine while it happens.
Hetzner blocks outbound 25, 465 and 587 on new cloud accounts until you open a support ticket,
and DigitalOcean restricts them too. Worse here than elsewhere: DocuSeal is configured not to
raise delivery errors, so a mail that never leaves the box produces a cheerful green interface
and silence at the other end. I only found it by sending myself a test document and watching
nothing happen. Run `docker compose logs --tail 40 docuseal` and look for a timeout to the
relay host before touching anything else.

## 11. Out of scope

- Do not add PostgreSQL. SQLite is why this is one container with one directory to copy.
- Do not change `SECRET_KEY_BASE` after the first boot. Record encryption keys derive from it,
  and rotating it makes stored signatures unreadable.
- Do not configure S3, GCS or Azure attachment storage. Documents stay on this disk.
- Do not enable the embedded signing form or the API integrations. Both carry a security
  surface, and they belong to the user, not to this install.
