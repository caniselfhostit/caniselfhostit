You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Stirling-PDF 2.14.2 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. Its A record must already point at this server. This is a JVM shipping
LibreOffice, Calibre and Tesseract inside the image, so it needs 2048 MB of RAM available
and 10 GB free on /srv. The 2.14.2 image is published for amd64 and arm64. Measure all
four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and
stop: the image is several GB before a document is uploaded, and a JVM out of heap during
an OCR pass looks like a random failure. If `dig +short` prints nothing, print that and
stop: Caddy cannot certify a hostname that does not resolve.

## 2. Layout

The image defaults PUID and PGID to 1000 and drops to that user, so /configs belongs to
1000.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/stirling-pdf /srv/stirling-pdf/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/stirling-pdf/config
ls -la /srv/stirling-pdf
```

Assert: `ls -la` shows `backups` owned by the login user and `config` owned by `1000`.
Everything lives under /srv/stirling-pdf and nothing is written outside it.

## 3. Secrets

One secret: the first-login credential for the `admin` account, generated on the server.
Do not print it, do not repeat it in your summary, and do not put it in any log line.

This install runs with login enabled. That is the one decision in this prompt: with
`SECURITY_ENABLELOGIN=false` anyone who finds the hostname can push documents through the
user's server. Login enabled ships a default account, so the generated value below
replaces it before the container starts.

```bash
umask 077
cat > /srv/stirling-pdf/.env <<EOF
DISABLE_ADDITIONAL_FEATURES=false
SECURITY_ENABLELOGIN=true
SECURITY_INITIALLOGIN_USERNAME=admin
SECURITY_INITIALLOGIN_PASSWORD=$(openssl rand -base64 24)
SYSTEM_DEFAULTLOCALE=en-GB
SYSTEM_MAXFILESIZE=100
SYSTEM_GOOGLEVISIBILITY=false
METRICS_ENABLED=false
EOF
chmod 600 /srv/stirling-pdf/.env
umask 022
ls -l /srv/stirling-pdf/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user their username is `admin`,
that they read the generated value once with
`sudo grep SECURITY_INITIALLOGIN_PASSWORD /srv/stirling-pdf/.env`, and that Stirling-PDF
makes them choose a new one at the first sign-in. `SYSTEM_GOOGLEVISIBILITY=false` asks
search engines not to index the instance; `METRICS_ENABLED=false` turns off the Prometheus
endpoint, which nothing here scrapes.

## 4. compose.yml

```bash
cat > /srv/stirling-pdf/compose.yml <<'EOF'
# Stirling-PDF · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image and ports .... https://docs.stirlingpdf.com/Installation/Docker%20Install
#   login settings ..... https://docs.stirlingpdf.com/Configuration/System%20and%20Security/
#
# One container, no database process: the user table is an embedded H2 file under
# /configs, so that directory plus the .env is the whole install. The image runs
# as uid 1000, hence the ownership in step 2. Tag and digest are the 2.14.2
# release read from Docker Hub on 2026-08-05, for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  stirling-pdf:
    image: stirlingtools/stirling-pdf:2.14.2@sha256:7ed4d9681d18e4fbc3aa6a63647c4b5c2bcc4b75841df7c05d7e3d2320f5c9a1
    container_name: stirling-pdf
    restart: unless-stopped
    env_file: /srv/stirling-pdf/.env
    volumes:
      # The H2 user database and the generated server certificate live here.
      # One mount, so one directory to copy. OCR language packs beyond the
      # bundled English set would need a second mount at /usr/share/tessdata.
      - /srv/stirling-pdf/config:/configs
    ports:
      # Loopback only. The Caddy that Prompt Zero installed on the host is the
      # only thing that can reach this port, and 8087 never enters the firewall.
      - "127.0.0.1:8087:8080"
EOF
cd /srv/stirling-pdf && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container serves on port 8080 inside itself and 8087
is bound to 127.0.0.1 on the host, so the only route in is Caddy.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by
the real hostname. Copy the file first: a syntax error takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-stirling-pdf
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Stirling-PDF · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://caddyserver.com/docs/automatic-https and
# https://docs.stirlingpdf.com/Installation/Docker%20Install
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

	# 8087 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Caddy sets no request
	# body limit of its own, so SYSTEM_MAXFILESIZE in .env is the ceiling.
	reverse_proxy 127.0.0.1:8087
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-stirling-pdf, reload, and report what it objected to. Caddy
gets the certificate on the first request and renews it with no cron job.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured
they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in,
443/udp is HTTP/3. 8087 stays closed: bound to 127.0.0.1, a rule for it would cover
traffic that cannot arrive, and if it appears there a previous run left it, which
`sudo ufw delete allow 8087` fixes. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule for 8087.

## 7. Start and verify

The first boot is slow, and the image's own health check allows two minutes before it
counts failures. Wait for that health check rather than guessing:

```bash
cd /srv/stirling-pdf
docker compose pull
docker compose up -d
sleep 90
docker inspect --format '{{.State.Health.Status}}' stirling-pdf
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -ci 'stirling'
sudo grep -ci 'stirling$' /srv/stirling-pdf/.env
```

Assert, all four: `docker inspect` prints `healthy`, the first curl prints `200`, the
second prints a number greater than `0` because `Stirling` appears in the served document,
and the last prints `0`, proving the shipped default credential is not in this install.
Print what you received for each. If health is still `starting`, wait 60 seconds and check
again before treating it as a failure. If anything misses after that, stop, run
`docker compose logs --tail 40 stirling-pdf`, and name the earlier step that is the likely
cause. A running container is not success; four asserts passing is. The first screen at
https://<DOMAIN> is a sign-in form asking for a username and a password.

STOP: tell the user to open https://<DOMAIN>, sign in as `admin` with the value from step 3,
set the new password Stirling-PDF demands, and save it. Wait for their confirmation.

## 8. First backup and restore

Take the backup now, before the user relies on the account. Stop first: the H2 user
database copied mid-write is not a backup.

```bash
cd /srv/stirling-pdf
docker compose stop
sudo tar -C /srv/stirling-pdf -czf /srv/stirling-pdf/backups/stirling-pdf-$(date +%F).tar.gz config .env
docker compose start
ls -lh /srv/stirling-pdf/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds,
and `config` plus `.env` is the whole install: uploaded documents are never kept. A backup
on the same disk is not a backup, so run this from the user's machine, not the server:

```bash
mkdir -p ~/backups/stirling-pdf
scp vps:/srv/stirling-pdf/backups/*.tar.gz ~/backups/stirling-pdf/
```

To restore: `docker compose down`, `sudo rm -rf /srv/stirling-pdf/config`,
`sudo tar -C /srv/stirling-pdf -xzf` the archive, then `docker compose up -d`. The account
lives in the H2 file under `config/`. Those four commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/Stirling-Tools/Stirling-PDF/releases. Take a
backup first, then edit the image line in /srv/stirling-pdf/compose.yml to the new tag and
digest. Stirling-PDF migrates the H2 file on the first boot after an upgrade, so wait for
the health check to go green before calling the update done.

```bash
cd /srv/stirling-pdf
docker compose pull
docker compose up -d
docker compose logs --tail 20 stirling-pdf
```

## 10. What will probably go wrong

The first boot. I watched `docker ps` report the container as unhealthy for close to two
minutes and assumed the install had failed, when the JVM was still unpacking LibreOffice
and building its font cache. On a 2 GB box that start took longer than every other step
here combined. If step 7 reports `starting`, read
`docker compose logs --tail 40 stirling-pdf` before changing anything: a boot in progress
prints Spring startup lines, a real failure prints a stack trace or the OOM killer.

## 11. Out of scope

- Do not set `SECURITY_ENABLELOGIN=false`. This instance answers on a public hostname, and
  the unauthenticated mode is for a machine nobody else can reach.
- Do not configure OAuth2 or SAML sign-on. Both need an identity provider registered
  elsewhere, which is the user's decision and not this install's.
- Do not add a /usr/share/tessdata mount for extra OCR languages. English is bundled.
- Do not enable `METRICS_ENABLED` or install Prometheus. Nothing on this box scrapes it.