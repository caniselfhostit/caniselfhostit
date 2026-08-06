This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Vikunja 2.5.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box. The same hostname goes into `VIKUNJA_SERVICE_PUBLICURL` in step 3, and Vikunja refuses
to start when that value is empty, so decide it before you begin.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. If the memory number is
under 512 MB, stop here rather than watching the container get killed halfway through its first
database migration. Vikunja is one Go binary with an embedded SQLite database, so this is a
small install, but small is not free.

## 2. Layout

The container runs as uid 1000 with no group, so the two directories it writes to belong to that
uid rather than to you.

```bash
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" /srv/vikunja /srv/vikunja/backups
sudo install -d -m 750 -o 1000 -g "$(id -g)" /srv/vikunja/db /srv/vikunja/files
ls -la /srv/vikunja
```

You should see: four entries, with `backups` owned by you and `db` and `files` owned by `1000`.

If you do not: on most VPS images your own account already is uid 1000, so all four look
identical and nothing is wrong. If the numbers differ and you "fix" them by chowning `db` to
yourself, the container will exit at its next start with an error about opening the database.
`db` holds one SQLite file. `files` holds every attachment anyone ever uploads.

## 3. Secrets

One secret: the key Vikunja signs session tokens with. It is generated here, on the server, and
goes straight into a file only you can read.

```bash
umask 077
cat > /srv/vikunja/.env <<EOF
VIKUNJA_SERVICE_PUBLICURL=https://<DOMAIN>
VIKUNJA_SERVICE_TIMEZONE=UTC
VIKUNJA_SERVICE_ENABLEREGISTRATION=true
VIKUNJA_SERVICE_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 /srv/vikunja/.env
umask 022
ls -l /srv/vikunja/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/vikunja/.env` and carry
on. Upstream documents that without a value here a fresh random one is generated at every
start, which signs out every logged-in session on every restart, so this line is the difference
between an app that remembers you and one that does not.

Do not paste that file, the secret, or any command output containing it into this chat window.
The value never has to leave the server: you can read it back yourself with
`sudo grep VIKUNJA_SERVICE_SECRET /srv/vikunja/.env`, and nothing in this install ever asks you
to type it anywhere.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/vikunja/compose.yml <<'EOF'
# Vikunja · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installing ......... https://vikunja.io/docs/installing/
#   docker examples .... https://vikunja.io/docs/full-docker-example/
#   config reference ... https://vikunja.io/docs/config-options/
#   reverse proxy ...... https://vikunja.io/docs/reverse-proxy/
#   what to backup ..... https://vikunja.io/docs/what-to-backup/
#
# One service. Upstream's own quick start runs this image with SQLite and two
# mounts, and the image ships VIKUNJA_DATABASE_PATH=/db/vikunja.db already set,
# so a single container is the documented shape here rather than a shortcut.
# The API and the web interface are the same binary on the same port, 3456.
#
# The image is built FROM scratch and runs as uid 1000 with no group. There is
# no shell in it, which is why this file declares no healthcheck: nothing in the
# image could run one. It is also why /srv/vikunja/db and /srv/vikunja/files
# have to be owned by uid 1000 on the host, which is what step 2 of the prompt
# does. Everything else about this container is unwritable by design.
#
# Tag and digest were read from Docker Hub on 2026-08-05; the manifest list
# publishes linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  vikunja:
    image: vikunja/vikunja:2.5.0@sha256:22df4c1bc8843c28d383bc5f52b59e7b601bf5f6560b36b29c0a500833c77fa3
    container_name: vikunja
    restart: unless-stopped
    env_file: /srv/vikunja/.env
    environment:
      # SQLite, written out even though it is the image default, because this
      # file is what a reviewer reads to find out where the data actually is.
      VIKUNJA_DATABASE_TYPE: sqlite
      VIKUNJA_DATABASE_PATH: /db/vikunja.db
      VIKUNJA_FILES_BASEPATH: /app/vikunja/files
      # No outbound mail. Upstream's reminder job only delivers over mail or a
      # webhook, so with this false a due date is something you see when you
      # open the app, not something that arrives. Block 10 says so out loud.
      VIKUNJA_MAILER_ENABLED: "false"
    volumes:
      - /srv/vikunja/db:/db
      - /srv/vikunja/files:/app/vikunja/files
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8097.
      - "127.0.0.1:8097:3456"
EOF
cd /srv/vikunja && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/vikunja/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/vikunja/compose.yml` and paste again in one go. Upstream also documents a
PostgreSQL compose example, and this install does not use it: a single-user task list is the
case SQLite was built for, and the image already points at `/db/vikunja.db` without being asked.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-vikunja
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Vikunja · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://vikunja.io/docs/reverse-proxy/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also VIKUNJA_SERVICE_PUBLICURL in .env and the two have to agree: Vikunja
# refuses to start when the public URL is empty, and it builds the links it
# hands out from that value.

<DOMAIN> {
	# One origin serves the web interface and the JSON API, so there is no
	# second route and no CORS to arrange. Frames are denied because nothing
	# here is meant to be embedded, and the referrer is trimmed because task
	# and project names travel inside these URLs.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# Caddy imposes no request body limit of its own, so attachments up to
	# Vikunja's own 20MB ceiling pass through with no size directive here.
	# 8097 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8097
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-vikunja /etc/caddy/Caddyfile`, reload,
and paste again. The commonest cause is a `<DOMAIN>` you replaced in one place and not the
other. Caddy requests the certificate on the first request and renews it on its own, so there is
nothing here to schedule and nothing to put in a calendar.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8097`.

If you do not: delete anything for `8097` with `sudo ufw delete allow 8097`. 8097 is bound to
127.0.0.1 by the compose file, so Caddy reaches it over loopback and nothing outside the box
ever can. 80/tcp is there to redirect to HTTPS and to answer the ACME challenge, 443/tcp is the
only way in, and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a
different problem: Prompt Zero left this firewall enabled, so something has turned it off since,
and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

Vikunja creates its own SQLite schema on the first start. Nothing is seeded, and there is no
default account waiting to be found.

```bash
cd /srv/vikunja
docker compose pull
docker compose up -d
for i in $(seq 1 20); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/info); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v1/info | grep -o '"registration_enabled":[a-z]*'
```

You should see, in order: the loop reaching `200`, then the line
`"registration_enabled":true`.

If you do not: run `docker compose logs --tail 40 vikunja`. That is the only window you have,
because this image is built from nothing at all and has no shell in it, so `docker compose exec`
answers `executable file not found` rather than giving you a prompt. A log line about the public
URL points at step 3, where `<DOMAIN>` was probably left literal. A log line about opening the
database points at step 2. A loop that never leaves `502` usually means Caddy is up and the
container is not.

The first screen at https://<DOMAIN> is a login form with the heading `Login`, a field labelled
`Username Or Email Address`, and beneath the button the line `Don't have an account yet?` next
to a `Create account` link.

Open https://<DOMAIN> now, follow `Create account`, and register the one account you want.
Registration is open to the whole internet until you finish this block, so do it now rather than
after dinner. Then close it:

```bash
sed -i 's/^VIKUNJA_SERVICE_ENABLEREGISTRATION=true$/VIKUNJA_SERVICE_ENABLEREGISTRATION=false/' /srv/vikunja/.env
cd /srv/vikunja && docker compose up -d --force-recreate
sleep 15
curl -sS https://<DOMAIN>/api/v1/info | grep -o '"registration_enabled":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' https://<DOMAIN>/api/v1/register
```

You should see: `"registration_enabled":false`, then `404`. Reload https://<DOMAIN> in your
browser and check the `Create account` link is gone.

If you do not: a second `true` means the `sed` matched nothing, so open the file and check the
line reads exactly `VIKUNJA_SERVICE_ENABLEREGISTRATION=true` before you re-run it. A `200` from
the register call means the container did not pick the file up, so run
`docker compose up -d --force-recreate` again and wait longer. Both of those leave anyone who
finds your hostname able to make an account on your server, so do not move on until you have
seen `false` and `404`. A running container is not success.

## 8. First backup and restore

Take the backup now, before you move a single task in. Nothing here runs inside the container,
because there is no shell in it: the archive is made on the host from the two mounted
directories. Stop the container first, because copying a SQLite file mid-write is not a backup.

```bash
cd /srv/vikunja
docker compose stop
sudo tar -C /srv/vikunja -czf /srv/vikunja/backups/vikunja-$(date +%F).tar.gz db files .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/vikunja/backups/
```

You should see: one `.tar.gz`, tens of kilobytes on a fresh install. Downtime is about five
seconds.

If you do not: a file of a few hundred bytes means `tar` found empty directories, so check the
container really started once. `tar: Cannot open: Permission denied` means you left off the
`sudo`, which matters because the files inside `db` were written by uid 1000 and not by you.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/vikunja
scp vps:/srv/vikunja/backups/*.tar.gz ~/backups/vikunja/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/vikunja/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty task list:

```bash
cd /srv/vikunja
docker compose down
sudo rm -rf /srv/vikunja/db /srv/vikunja/files
sudo tar -C /srv/vikunja -xzf /srv/vikunja/backups/vikunja-$(date +%F).tar.gz
sudo install -d -m 750 -o 1000 -g "$(id -g)" /srv/vikunja/db /srv/vikunja/files
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/v1/info | grep -o '"registration_enabled":[a-z]*'
```

You should see: `"registration_enabled":false`, and your account still logs in in the browser.

If you do not: the `install -d` line is the one people skip. `tar` restores the ownership it
recorded, and if that is wrong for this box the container exits without writing anything.
Understand the stakes before you decide to skip this whole block: every task, project, comment
and label lives in `db/vikunja.db`, every attachment is a file under `files/`, and the signing
key is in `.env`. Restore the database without the key and everyone is signed out.

## 9. Updating later

New versions are listed at https://github.com/go-vikunja/vikunja/releases. Take a backup first,
then edit the `image:` line in /srv/vikunja/compose.yml to the new tag and its digest.

```bash
cd /srv/vikunja
docker compose pull
docker compose up -d
docker compose logs --tail 30 vikunja
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
info check from step 7 before you call the update done, and log in once as well, because a
service that answers on `/api/v1/info` can still be failing on a migration that stopped halfway.

## 10. What will probably go wrong

Reminders. I set a due date, waited past it, and nothing arrived, and I spent twenty minutes
looking for a broken notification setting that does not exist. Upstream's reminder job only runs
when mail or webhooks can carry the message, and this install has no mail, so a due date here is
something you see when you open the app rather than something that comes to find you. If you are
arriving from Todoist that is the one habit that does not survive the move. Learn it on the day
you install this, not the week you miss something.

## 11. Out of scope

- Do not configure SMTP. It is a real gap, named in step 10, and closing it means a mail
  provider, a sending domain and DNS records, which is a longer job than this whole install.
- Do not enable the Todoist migration. It needs a developer app registered in your own Todoist
  account with a client id and secret, which is a decision to make later and on purpose.
- Do not switch the database to PostgreSQL. SQLite is the choice here and the image expects it.
- Do not install a Vikunja Pro licence key. The admin panel, time tracking and audit logs are
  paid features; everything else works without one.
