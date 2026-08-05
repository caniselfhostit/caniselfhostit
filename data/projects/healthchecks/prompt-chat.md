This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Healthchecks v4.3 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box and `<ADMIN_EMAIL>` with the address your account will use.

Before you start, have three things to hand: the hostname of an SMTP relay you already have,
its port, and your username on it. Healthchecks tells you when something did not happen, and it
does that by email. Without a relay you can install this and still not have a monitor.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP address on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it at your DNS
provider, wait a minute, and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate
for a hostname that does not resolve, and failed attempts count against a rate limit you cannot
see.

## 2. Layout

The image creates `/data` inside itself and hands it to a system account called `hc`. That
account's uid is decided when the image is built, so ask the image rather than guessing.

```bash
IMG=healthchecks/healthchecks:v4.3@sha256:cd7bcd94350818b3944f82eb5995f48bdeab8c8627977578a569ffa73f56f56f
docker pull "$IMG"
HCUID=$(docker run --rm "$IMG" id -u hc)
echo "hc is uid $HCUID"
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/healthchecks /srv/healthchecks/backups
sudo install -d -m 750 -o "$HCUID" -g "$HCUID" /srv/healthchecks/data
ls -la /srv/healthchecks
```

You should see: a line like `hc is uid 999`, then `backups` owned by your own username and
`data` owned by that number.

If you do not: `docker: permission denied` means your session predates the docker group change
from Prompt Zero, so log out and back in. `data` owned by you means the last install line did
not run, and the container will fail to write its database with an error that mentions nothing
about ownership.

## 3. Secrets

One secret is generated here: the Django `SECRET_KEY`. Before you paste, edit three lines in
the block: `EMAIL_HOST` to your relay's hostname, `EMAIL_PORT` to its port, and
`EMAIL_HOST_USER` to your username on it if that is not your email address.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines one at a time in different shells. Run `chmod 600 /srv/healthchecks/.env`
and carry on.

Now add the relay credential. These five lines never echo it and never put it in your shell
history:

```bash
umask 077
printf 'EMAIL_HOST_PASSWORD=' >> /srv/healthchecks/.env
read -rs && printf '%s\n' "$REPLY" >> /srv/healthchecks/.env
unset REPLY
chmod 600 /srv/healthchecks/.env
```

You should see: nothing at all after the third line. The cursor sits there waiting. Type or
paste the credential, press Return, and you are back at a prompt. Then check the shape of it
without reading it back:

```bash
sudo awk -F= '/^EMAIL_HOST_PASSWORD/ {print "recorded, length " length($2)}' /srv/healthchecks/.env
```

You should see: `recorded, length` and a number greater than zero.

If you do not: no output means the line is missing, so run the five-line block again. A length
of `0` means you pressed Return before typing anything: edit the file with
`sudo nano /srv/healthchecks/.env` and fix that one line.

Do not paste the contents of that file, the relay credential, or any command output containing
it into this chat window. Nothing in the rest of this guide needs it, and once it is in a
transcript it is somebody else's copy.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/healthchecks/.env not found` means step 3 did not write the file,
so go back. `services must be a mapping` means the indentation was lost between the page and
your terminal: run `rm /srv/healthchecks/compose.yml` and paste the block again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-healthchecks /etc/caddy/Caddyfile`,
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
mentioning `8088`, `25`, `465` or `587`.

If you do not: a rule for `8088` from an earlier attempt should go, with
`sudo ufw delete allow 8088`. 8088 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it. The mail ports stay closed because this box sends outbound
through your relay and never accepts mail.

## 7. Start and verify

uWSGI runs the database migrations as it boots, so the first start writes `hc.sqlite` and takes
longer than every later one.

```bash
cd /srv/healthchecks
docker compose up -d
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v3/status/
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/accounts/signup/
```

You should see: `200` twice. The first URL is the endpoint the image's own health check uses,
and it answers 200 only when the database connection is alive.

If you do not: `000` or `502` means the certificate is not there yet, so run
`sudo journalctl -u caddy -n 30`. `500` on the status endpoint usually means the `data`
directory is not writable by the container, which is step 2 done wrong: check with
`docker compose logs --tail 40 healthchecks`.

A container listed in `docker ps` is not proof of anything. The two checks above are.

Now open https://<DOMAIN>/accounts/signup/ and sign up with your address. Healthchecks emails
you a sign-in link, and that link is how you get in the first time. If it does not arrive,
read step 10 before you change anything: this is the single most likely place for this install
to stall, and it is usually not Healthchecks.

Once you are signed in, close registration so your monitor is not a public signup form:

```bash
sed -i 's/^REGISTRATION_OPEN=True$/REGISTRATION_OPEN=False/' /srv/healthchecks/.env
cd /srv/healthchecks && docker compose up -d --force-recreate
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v3/status/
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/accounts/signup/
```

You should see: `200`, then anything that is not `200`.

If you do not: a second `200` means the file was not edited, so check with
`grep REGISTRATION /srv/healthchecks/.env`. Until that reads `False`, anyone who finds your
hostname can create an account on your monitor.

## 8. First backup and restore

Do this before you add a check, so you find out now whether it works. The stop matters: a
SQLite file copied mid-write is not a backup.

```bash
cd /srv/healthchecks
docker compose stop
sudo tar -C /srv/healthchecks -czf /srv/healthchecks/backups/healthchecks-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/healthchecks/backups/
```

You should see: one `.tar.gz` file, a few hundred kilobytes on a fresh install.

If you do not: `tar: data: Cannot open` means the `cd` did not happen. A size of `45` bytes
means tar wrote an empty archive because the paths were wrong, so check
`sudo ls /srv/healthchecks/data` before you trust it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
on the server:

```bash
mkdir -p ~/backups/healthchecks
scp vps:/srv/healthchecks/backups/*.tar.gz ~/backups/healthchecks/
```

You should see: one file copied, and the same file listed by `ls -lh ~/backups/healthchecks/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake. The
`vps:` prefix only means something on your own machine.

Now prove the restore, because a backup you have never restored is a guess:

```bash
cd /srv/healthchecks
docker compose down
sudo rm -rf /srv/healthchecks/data
sudo tar -C /srv/healthchecks -xzf /srv/healthchecks/backups/healthchecks-$(date +%F).tar.gz
docker compose up -d
```

You should see: `Created` and `Started`, then a sign-in page at https://<DOMAIN> that still
knows your account.

If you do not: a sign-in page that has turned back into a signup form means the archive was
taken before you closed registration, which is harmless here but tells you the archive is
older than you thought. Take another one. Those four commands are the whole disaster plan, and
you have now run them once.

## 9. Updating later

New versions are at https://github.com/healthchecks/healthchecks/releases. Take a backup first,
then edit the `image:` line in /srv/healthchecks/compose.yml to the new tag and its digest.

```bash
cd /srv/healthchecks
docker compose pull
docker compose up -d
docker compose logs --tail 20 healthchecks
```

You should see: `Recreated`, then migration lines, then uWSGI workers starting and no repeating
restart.

If you do not: put the old tag and digest back and run the same three commands. uWSGI runs the
migrations on the next boot, so read that log before you call the update done.

## 10. What will probably go wrong

The signup email will not arrive, and the install will look broken when it is not. Hetzner
blocks outbound 25, 465 and 587 on new cloud accounts until you open a support ticket, and
DigitalOcean restricts them too. I sat watching an empty inbox for ten minutes with a container
that had been answering 200 the whole time. Run `docker compose logs --tail 40 healthchecks`
and look for a connection timeout to your relay host. That is the provider, not this install,
and the fix is a support ticket with a lead time measured in days.

## 11. Out of scope

- Do not switch the database to PostgreSQL. SQLite is why this is one file to copy.
- Do not set `SMTPD_PORT` or open an inbound mail listener. This install only sends.
- Do not configure Slack, Telegram or any other channel. Each is an account elsewhere.
- Do not add a cron job for the alert sender. uWSGI keeps `sendalerts` running already.
