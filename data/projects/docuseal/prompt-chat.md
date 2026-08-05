This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing DocuSeal 3.1.7 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise. Replace `<DOMAIN>` with the hostname whose A record already points at the
box, and `<ADMIN_EMAIL>` with the address your first account will use.

Have three things to hand before you start: the hostname of an SMTP relay you already have, its
port, and your username on it. DocuSeal invites signers by email, so a document you cannot send
is a document you cannot get signed.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP address on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it at your DNS
provider, wait a minute, and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate
for a hostname that does not resolve, and failed attempts count against a rate limit you cannot
see. Under 2 GB of RAM the PDF rendering is what falls over, usually on the third document.

## 2. Layout

The image creates a `docuseal` account with uid 2000 and runs as it, so `data` belongs to 2000
and not to you.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/docuseal /srv/docuseal/backups
sudo install -d -m 750 -o 2000 -g 2000 /srv/docuseal/data
ls -la /srv/docuseal
```

You should see: `backups` owned by your own username, and `data` owned by `2000`.

If you do not: `data` owned by you means the second command did not run, and the container will
fail to create its database with a permission error that mentions nothing about ownership. Run
the second line again on its own.

## 3. Secrets

One secret is generated here: `SECRET_KEY_BASE`. Before you paste, edit three lines in the
block: `SMTP_ADDRESS` to your relay's hostname, `SMTP_PORT` to its port, and `SMTP_USERNAME` to
your username on it if that is not your email address.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines one at a time in different shells. Run `chmod 600 /srv/docuseal/.env` and
carry on.

One thing about `SECRET_KEY_BASE` that is worth reading twice: it is not only a session key,
it is what the record encryption keys are derived from. If you ever regenerate it, every stored
signature and configuration value becomes unreadable. It gets backed up in step 8 with the
database, and those two belong together forever.

Now add the relay credential. These five lines never echo it and never put it in your shell
history:

```bash
umask 077
printf 'SMTP_PASSWORD=' >> /srv/docuseal/.env
read -rs && printf '%s\n' "$REPLY" >> /srv/docuseal/.env
unset REPLY
chmod 600 /srv/docuseal/.env
```

You should see: nothing at all after the third line. The cursor sits there waiting. Type or
paste the credential, press Return, and you are back at a prompt. Then check the shape of it
without reading it back:

```bash
sudo awk -F= '/^SMTP_PASSWORD/ {print "recorded, length " length($2)}' /srv/docuseal/.env
```

You should see: `recorded, length` and a number greater than zero.

If you do not: no output means the line is missing, so run the five-line block again. A length
of `0` means you pressed Return before typing anything: edit the file with
`sudo nano /srv/docuseal/.env` and fix that one line.

Do not paste the contents of that file, the relay credential, or any command output containing
it into this chat window. Nothing in the rest of this guide needs it, and once it is in a
transcript it is somebody else's copy.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/docuseal/.env not found` means step 3 did not write the file, so
go back. `services must be a mapping` means the indentation was lost between the page and your
terminal: run `rm /srv/docuseal/compose.yml` and paste the block again in one go.

Upstream's own example compose file runs PostgreSQL beside the app. This one does not, because
a single-person install on SQLite is one process to operate and one directory to copy.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-docuseal /etc/caddy/Caddyfile`, reload,
and paste again, checking that the blank line from the second command really landed. Caddy asks
Let's Encrypt for the certificate on the first request to your hostname and renews it on its
own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8089`, `25`, `465` or `587`.

If you do not: a rule for `8089` from an earlier attempt should go, with
`sudo ufw delete allow 8089`. 8089 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it. The mail ports stay closed because this box sends outbound
through your relay and never accepts mail.

## 7. Start and verify

Rails migrates as it boots, so the first start is slow. Do not add `-L` to these commands: the
redirect is the signal you are looking for.

```bash
cd /srv/docuseal
docker compose pull
docker compose up -d
sleep 45
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/up
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
```

You should see: `200` twice. `/up` is the Rails health route and answers only once the app has
booted. `/setup` is the first-run form, and it answers 200 exactly while no user exists.

If you do not: `000` or `502` means the certificate is not there yet, so run
`sudo journalctl -u caddy -n 30`. If `/up` still misses after another minute, run
`docker compose logs --tail 40 docuseal`: a permission error on `/data/docuseal` is step 2 done
wrong, and a container that vanished was killed for running out of memory.

A container listed in `docker ps` is not proof of anything. The two checks above are.

Now open https://<DOMAIN>/setup in a browser and create your account. Do it before you make
coffee: until that account exists, anyone who finds this hostname can create it instead, and
they would own every document you later put here. Then prove the form closed itself:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/setup
```

You should see: `302`. DocuSeal redirects /setup to the sign-in page once a user exists.

If you do not: `200` means no account was created, and your hostname is standing open. Go back
to the browser and finish the form.

## 8. First backup and restore

Do this before the first real document, so you find out now whether it works. The stop matters:
a SQLite file copied mid-write is not a backup.

```bash
cd /srv/docuseal
docker compose stop
sudo tar -C /srv/docuseal -czf /srv/docuseal/backups/docuseal-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/docuseal/backups/
```

You should see: one `.tar.gz` file, a few hundred kilobytes on a fresh install.

If you do not: `tar: data: Cannot open` means the `cd` did not happen. A size of `45` bytes
means tar wrote an empty archive because the paths were wrong, so check
`sudo ls /srv/docuseal/data` before you trust it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not on
the server:

```bash
mkdir -p ~/backups/docuseal
scp vps:/srv/docuseal/backups/*.tar.gz ~/backups/docuseal/
```

You should see: one file copied, and the same file listed by `ls -lh ~/backups/docuseal/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake. The
`vps:` prefix only means something on your own machine.

Now prove the restore, because a backup you have never restored is a guess:

```bash
cd /srv/docuseal
docker compose down
sudo rm -rf /srv/docuseal/data
sudo tar -C /srv/docuseal -xzf /srv/docuseal/backups/docuseal-$(date +%F).tar.gz
docker compose up -d
```

You should see: `Created` and `Started`, then after a minute a sign-in page at https://<DOMAIN>
that still accepts your account.

If you do not: a page that has turned back into the setup form means the archive did not
contain the database. Stop and go back to the tar step. If you can sign in but every document
shows an error, the archive had `data` without `.env`, which is the one mistake this install
cannot recover from. Those four commands are the whole disaster plan, and you have now run them
once.

## 9. Updating later

New versions are at https://github.com/docusealco/docuseal/releases. Take a backup first, then
edit the `image:` line in /srv/docuseal/compose.yml to the new tag and its digest.

```bash
cd /srv/docuseal
docker compose pull
docker compose up -d
docker compose logs --tail 20 docuseal
```

You should see: `Recreated`, then migration lines, then Puma booting and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Rails migrates
on the next boot, so read that log and load the page once before you call the update done.

## 10. What will probably go wrong

The signing invitation will not arrive, and the install will look fine while it happens.
Hetzner blocks outbound 25, 465 and 587 on new cloud accounts until you open a support ticket,
and DigitalOcean restricts them too. What makes it worse here than elsewhere is that DocuSeal
is configured not to raise delivery errors, so the interface stays green and cheerful while
nothing leaves the box. I only found it by sending myself a test document and watching nothing
happen. Run `docker compose logs --tail 40 docuseal` and look for a timeout to your relay host
before you touch anything else.

## 11. Out of scope

- Do not add PostgreSQL. SQLite is why this is one container with one directory to copy.
- Do not change `SECRET_KEY_BASE` after the first boot. The record encryption keys are derived
  from it, and rotating it makes stored signatures unreadable.
- Do not configure S3, GCS or Azure attachment storage. Documents stay on this disk.
- Do not enable the embedded signing form or the API integrations. Both are decisions with a
  security surface, and they are yours to make later.
