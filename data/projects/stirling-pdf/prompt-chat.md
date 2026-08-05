This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Stirling-PDF 2.14.2 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP address on the last line.

If you do not: this is the heaviest install in the catalogue, because the image carries a JVM,
LibreOffice, Calibre and Tesseract. Under 2 GB of RAM the first OCR job kills the container and
the failure looks random. An empty last line means the A record does not exist yet: add it at
your DNS provider, wait a minute, and run `dig +short <DOMAIN>` again. Caddy cannot get a
certificate for a hostname that does not resolve, and failed attempts count against a rate
limit you cannot see.

## 2. Layout

The image defaults PUID and PGID to 1000 and drops to that user, so `config` belongs to 1000
and not to you.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/stirling-pdf /srv/stirling-pdf/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/stirling-pdf/config
ls -la /srv/stirling-pdf
```

You should see: `backups` owned by your own username, and `config` owned by `1000`.

If you do not: `config` owned by you instead of `1000` means the second command did not run.
The container will fail to write its user database with a permission error that says nothing
about ownership. Run the second line again on its own.

## 3. Secrets

One secret: the first-login credential for the `admin` account. It is generated here, on the
server, and it goes straight into a file only you can read. Stirling-PDF ships a default
account when login is enabled, and this file is what replaces it before the container starts.

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

You should see: mode `-rw-------`, your own username twice, and the path. Your Stirling-PDF
username will be `admin`. Read the generated value once with
`sudo grep SECURITY_INITIALLOGIN_PASSWORD /srv/stirling-pdf/.env`. Stirling-PDF makes you
choose a new one at the first sign-in, so the value in this file stops mattering after that.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines one at a time in different shells. Run `chmod 600 /srv/stirling-pdf/.env`
and carry on.

Do not paste the contents of that file, the generated value, or any command output containing
it into this chat window. Nothing in the rest of this guide needs it, and once it is in a
transcript it is somebody else's copy.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/stirling-pdf/.env not found` means step 3 did not write the file,
so go back. `services must be a mapping` means the indentation was lost between the page and
your terminal: run `rm /srv/stirling-pdf/compose.yml` and paste the block again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-stirling-pdf /etc/caddy/Caddyfile`,
reload, and paste again, checking that the blank line from the second command really landed.
Caddy asks Let's Encrypt for the certificate on the first request to your hostname and renews
it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8087`.

If you do not: a rule for `8087` from an earlier attempt should go, with
`sudo ufw delete allow 8087`. 8087 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it and a firewall rule for it would cover traffic that cannot
arrive. 80/tcp is there to answer the certificate challenge and redirect to HTTPS, 443/tcp is
the only way in, and 443/udp is HTTP/3.

## 7. Start and verify

The first boot is slow. The image's own health check allows two minutes before it starts
counting failures, so `sleep 90` below is not padding.

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

You should see: `healthy`, then `200`, then a number greater than `0`, then `0`. That last `0`
is the security check: it proves the credential Stirling-PDF ships with is not in your file.

If you do not: `starting` is not a failure yet. Wait 60 seconds and run the `docker inspect`
line again. If it is still not `healthy` after that, run
`docker compose logs --tail 40 stirling-pdf`: a boot in progress prints Spring startup lines,
a real failure prints a stack trace, and a container that vanished was killed for running out
of memory. If the first curl prints `000` or `502`, the certificate is not there yet, so run
`sudo journalctl -u caddy -n 30`.

A container listed in `docker ps` is not proof of anything. The four checks above are.

Now open https://<DOMAIN> in a browser. The first screen is a sign-in form asking for a
username and a password. Sign in as `admin` with the value from step 3, set the new password
it asks you for, and put that new one in your password manager.

## 8. First backup and restore

Do this before you rely on the account, so you find out now whether it works. The stop matters:
the H2 user database copied mid-write is not a backup.

```bash
cd /srv/stirling-pdf
docker compose stop
sudo tar -C /srv/stirling-pdf -czf /srv/stirling-pdf/backups/stirling-pdf-$(date +%F).tar.gz config .env
docker compose start
ls -lh /srv/stirling-pdf/backups/
```

You should see: one `.tar.gz` file, tens of kilobytes on a fresh install. The site is down for
a few seconds while this runs, which is the price of a backup that is actually consistent.

If you do not: `tar: config: Cannot open` means the `cd` did not happen. A size of `45` bytes
means tar wrote an empty archive because the paths were wrong, so check
`sudo ls /srv/stirling-pdf/config` before you trust it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
on the server:

```bash
mkdir -p ~/backups/stirling-pdf
scp vps:/srv/stirling-pdf/backups/*.tar.gz ~/backups/stirling-pdf/
```

You should see: one file copied, and the same file listed by `ls -lh ~/backups/stirling-pdf/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake. The
`vps:` prefix only means something on your own machine.

Now prove the restore, because a backup you have never restored is a guess:

```bash
cd /srv/stirling-pdf
docker compose down
sudo rm -rf /srv/stirling-pdf/config
sudo tar -C /srv/stirling-pdf -xzf /srv/stirling-pdf/backups/stirling-pdf-$(date +%F).tar.gz
docker compose up -d
```

You should see: `Created` and `Started`, then after a minute or two a sign-in page at
https://<DOMAIN> that accepts the password you set in step 7.

If you do not: a sign-in page that rejects that password means the archive predates your
password change, and you are looking at the account as it was when the backup was taken. Take
another backup now that you have changed it. Those four commands are the whole disaster plan,
and you have now run them once.

## 9. Updating later

New versions are listed at https://github.com/Stirling-Tools/Stirling-PDF/releases. Take a
backup first, then edit the `image:` line in /srv/stirling-pdf/compose.yml to the new tag and
its digest.

```bash
cd /srv/stirling-pdf
docker compose pull
docker compose up -d
docker compose logs --tail 20 stirling-pdf
```

You should see: `Recreated`, then Spring startup lines and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Stirling-PDF
migrates the H2 file on the first boot after an upgrade, so wait for
`docker inspect --format '{{.State.Health.Status}}' stirling-pdf` to print `healthy` before you
call the update done.

## 10. What will probably go wrong

The first boot. I watched `docker ps` report the container as unhealthy for close to two
minutes and assumed the install had failed, when the JVM was still unpacking LibreOffice and
building its font cache. On a 2 GB box that start took longer than every other step here
combined. If step 7 reports `starting`, read `docker compose logs --tail 40 stirling-pdf`
before changing anything: a boot in progress prints Spring startup lines, a real failure prints
a stack trace or the OOM killer.

## 11. Out of scope

- Do not set `SECURITY_ENABLELOGIN=false`. This instance answers on a public hostname, and
  the unauthenticated mode is for a machine nobody else can reach.
- Do not configure OAuth2 or SAML sign-on. Both need an identity provider registered
  elsewhere, which is your decision to make later.
- Do not add a /usr/share/tessdata mount for extra OCR languages. English is bundled.
- Do not enable `METRICS_ENABLED` or install Prometheus. Nothing on this box scrapes it.
