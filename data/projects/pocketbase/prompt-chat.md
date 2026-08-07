This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing PocketBase 0.39.10 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box, and `<ADMIN_EMAIL>` with the address your superuser account will be created
under. Nothing in this install sends mail to that address: it is the name you type into the
dashboard login form.

One thing to know before step 1. PocketBase publishes no Docker image of its own, and says so
in its own production documentation. The image below is a community build maintained outside
the PocketBase project, at github.com/muchobien/pocketbase-docker. Its Dockerfile downloads
upstream's release zip and unpacks it without checking it against the checksums.txt upstream
publishes beside it, which upstream's own example Dockerfile also does not do. What fixes the
bytes you run is the digest in the image line, which names exactly one build, and step 7 asks
the binary inside it which version it is.

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
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for this
hostname while you install, because the certificate would otherwise be issued to somebody
else's edge. If free memory is under 512 MB, this will still boot and then behave strangely
under the first real load; add swap or move to a bigger box rather than continuing.

## 2. Layout

The container runs as uid 1000, so its data directory belongs to 1000 rather than to you.
Backups stay yours, because you are the one who copies them off the box.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/pocketbase /srv/pocketbase/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/pocketbase/data
ls -la /srv/pocketbase
```

You should see: `backups` owned by you, and `data` owned by `1000`.

If you do not: `data` owned by your own username means the second line did not run, and the
container will fail on its first write with a permissions error on `/pb_data`. Run the second
line again on its own. Keep this directory on the server's local disk: it holds a SQLite
database, and SQLite on a network mount corrupts quietly and weeks later.

## 3. Secrets

One secret: the password of your first superuser account. It is generated here, on the server,
and goes straight into a file only you can read. Hex rather than base64, because you are going
to retype this string into a browser login form and hex has no characters you can mistake for
each other.

```bash
umask 077
cat > /srv/pocketbase/.env <<EOF
PB_ADMIN_EMAIL=<ADMIN_EMAIL>
PB_ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/pocketbase/.env
umask 022
ls -l /srv/pocketbase/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace
`<ADMIN_EMAIL>` on the first line with your real address before you paste. Read the password
once with `sudo grep PB_ADMIN_PASSWORD /srv/pocketbase/.env` and put it in your password
manager: it is the only credential this install has.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately into different shells. Run `chmod 600 /srv/pocketbase/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
the password, which is harmless: the container applies whatever is in this file at its next
start, so the new value becomes the real one.

Do not paste that file, the password, or any command output containing it into this chat
window. The agent path never sees those values; this path will hand them to a third party
unless you make a point of not doing it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/pocketbase/compose.yml <<'EOF'
# PocketBase · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   introduction ....... https://pocketbase.io/docs/
#   production notes ... https://pocketbase.io/docs/going-to-production/
#   health endpoint .... https://pocketbase.io/docs/api-health/
#   image entrypoint ... https://github.com/muchobien/pocketbase-docker/blob/22f36a08837f26b22a3327cb8066ad63c3362c70/entrypoint.sh
#
# One container. PocketBase is a single Go binary with SQLite compiled into it,
# so there is no database service here, and no Caddy service either: Prompt Zero
# already runs Caddy under systemd on the host.
#
# The PocketBase project publishes no image. Its production page states that
# PocketBase doesn't have an official Docker image, so this file uses
# ghcr.io/muchobien/pocketbase, built outside the PocketBase project from the
# revision named above, which is the one this digest was built from. That
# Dockerfile downloads upstream's own release zip for the target architecture
# and unpacks it, and it does not check that zip against the checksums.txt
# upstream publishes beside it. Neither does the example Dockerfile in
# upstream's own docs. What fixes the bytes you run is the digest below, which
# names one build and nothing else, and step 7 asserts the binary inside it
# reports 0.39.10. Digest read from ghcr.io on 2026-08-07; the index carries
# linux/amd64, linux/arm64 and linux/armv7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  pocketbase:
    image: ghcr.io/muchobien/pocketbase:0.39.10@sha256:dfebd2550d6b5176d67afd3e859f9b642096e624c7f6ada1b5a5bc70a5d21be1
    container_name: pocketbase
    restart: unless-stopped
    # The image declares no USER, so without this line it runs as root.
    # PocketBase writes nothing outside its data directory, so uid 1000 is
    # enough, and step 2 hands that directory to 1000.
    user: "1000:1000"
    env_file: /srv/pocketbase/.env
    environment:
      # Inside the container the server has to listen on every interface, or
      # the loopback port published on the host reaches nothing. 8090 is the
      # port the image's entrypoint defaults to, named here so a change to
      # that default cannot move it under the healthcheck and the Caddy block.
      PB_HOST: "0.0.0.0"
      PB_PORT: "8090"
    volumes:
      # The one mount: data.db, every uploaded file, and PocketBase's own
      # backup archives. Local disk only: SQLite needs real POSIX file locks,
      # and a network mount corrupts it quietly.
      - /srv/pocketbase/data:/pb_data
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8090/api/health || exit 1"]
      start_period: 10s
      interval: 15s
      retries: 10
    ports:
      # Loopback only. The host's Caddy is the only thing that reaches 8166,
      # and 8166 never enters the firewall.
      - "127.0.0.1:8166:8090"
EOF
cd /srv/pocketbase && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/pocketbase/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal;
run `rm /srv/pocketbase/compose.yml` and paste again in one go. The container serves on 8090
inside itself and 8166 is bound to 127.0.0.1 on the host, so Caddy is the only route in. Do not
add a Caddy service to this file: Caddy already runs under systemd on this box, and a container
claiming 80 and 443 would fail to start and take every other site down with it.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-pocketbase
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# PocketBase · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://pocketbase.io/docs/going-to-production/ and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# No `encode` directive here, on purpose. PocketBase's realtime endpoint is
	# a long-lived text/event-stream, which Caddy flushes to the client
	# immediately instead of buffering, and a compressor in front of a stream
	# that carries JSON this small earns nothing.
	#
	# reverse_proxy sets X-Forwarded-For itself and ignores whatever the client
	# sent in that header, which is what makes it safe to name in PocketBase's
	# User IP proxy headers setting.
	#
	# 8166 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8166
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-pocketbase /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and
not the other. Caddy requests the certificate on the first request to the hostname and renews
it on its own, so there is no cron job to add and nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8166`.

If you do not: delete anything for `8166` with `sudo ufw delete allow 8166`. That port is bound
to 127.0.0.1 by the compose file, so a rule for it would cover traffic that cannot arrive.
80/tcp is there to answer the ACME challenge and redirect to HTTPS, 443/tcp is the only way in,
and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different
problem: Prompt Zero left this firewall enabled, so something has turned it off since, and
`sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

The image's entrypoint creates your superuser account from the two variables in .env, then
starts the server. The account therefore exists before the port answers its first request,
which is why there is no setup window here for somebody else to walk into.

```bash
cd /srv/pocketbase
docker compose pull
docker compose up -d
docker compose exec -T pocketbase pocketbase --version
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/api/health
echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/collections
docker compose logs pocketbase | grep -c 'Successfully saved superuser'
```

You should see, in order: a version line containing `0.39.10`, the loop reaching `200`, a small
JSON object containing `"message":"API is healthy."`, then `401`, then a number of at least `1`.

If you do not: the `401` is the one worth understanding. It means the API is up and refusing a
call that carries no superuser token, so seeing it is good news, and a `200` there would mean
something is very wrong. If the loop never reaches `200`, run
`docker compose logs --tail 40 pocketbase` first: a restart loop mentioning `/pb_data` is step 2
done wrong, and a clean log with no HTTP answer is usually Caddy still waiting on DNS. A count
of `0` on the last line means the entrypoint found no `PB_ADMIN_EMAIL` and `PB_ADMIN_PASSWORD`,
so step 3 wrote the file somewhere else or the compose file is not reading it. A version line
that does not say `0.39.10` means the digest in the image line was edited; put it back.

Now open https://<DOMAIN>/_/ in a browser. The first screen is a login form headed
`Superuser login`, with an email field, a password field and no way to create an account. Read
your password with `sudo grep PB_ADMIN_PASSWORD /srv/pocketbase/.env`, sign in with the address
you put in `<ADMIN_EMAIL>`, and save both in your password manager.
A running container is not success; this screen and that sign-in are.

## 8. First backup and restore

Take the backup now, before you create a single collection. The container stops first, because
upstream says plainly that copying `pb_data` is the backup and that the application must not be
running while it happens.

```bash
cd /srv/pocketbase
docker compose stop
sudo tar -czf /srv/pocketbase/backups/pocketbase-$(date +%F).tar.gz -C /srv/pocketbase data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/pocketbase/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install. Downtime is a few seconds.

If you do not: an archive of about 100 bytes means `tar` found nothing at those paths, so check
you are in /srv/pocketbase. That one archive is the whole install: the SQLite database with
every account and record, the uploaded files, the compose file, your password, and the live
Caddy site block from /etc/caddy, which is where the `-C /etc/caddy Caddyfile` at the end comes
from.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/pocketbase
scp vps:/srv/pocketbase/backups/*.tar.gz ~/backups/pocketbase/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/pocketbase/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty database:

```bash
cd /srv/pocketbase
docker compose down
sudo rm -rf /srv/pocketbase/data
sudo install -d -m 750 -o 1000 -g 1000 /srv/pocketbase/data
sudo tar -xzf /srv/pocketbase/backups/pocketbase-$(date +%F).tar.gz -C /srv/pocketbase data
sudo chown -R 1000:1000 /srv/pocketbase/data
docker compose up -d
sleep 10
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/health
```

You should see: `200`, and your existing password still signing you in at https://<DOMAIN>/_/.

If you do not: a restart loop after a restore is nearly always the `chown` line being skipped,
because `tar` restored the files as root. Run it and `docker compose up -d` again. Note what
the archive does not put back on its own: the Caddy site block is in it at `Caddyfile`, and
restoring that means opening the file and pasting the block into /etc/caddy/Caddyfile by hand,
because that file also holds every other site on the box.

## 9. Updating later

New versions are listed at https://github.com/pocketbase/pocketbase/releases, and the image
tags that follow them are at
https://github.com/muchobien/pocketbase-docker/pkgs/container/pocketbase. Take a backup first,
then edit the `image:` line in /srv/pocketbase/compose.yml to the new tag and its digest.

```bash
cd /srv/pocketbase
docker compose pull
docker compose up -d
docker compose logs --tail 30 pocketbase
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
step 7's health check and the version check before you call the update done. Read the upstream
release notes before every bump: PocketBase is pre-1.0 and says so, and breaking changes land
in minor releases rather than waiting for a major one, so a jump of two minor versions can want
a change in your own code.

## 10. What will probably go wrong

The password will come back. I changed my superuser password inside the dashboard, restarted
the container a week later, and could not sign in with the new one. Nothing was broken: the
image's entrypoint runs `superuser upsert` from `PB_ADMIN_EMAIL` and `PB_ADMIN_PASSWORD` on
every single start, so the value in /srv/pocketbase/.env wins over whatever the dashboard was
told, every time the container comes up. Treat that file as the source of truth. To change the
password, edit .env and run `docker compose up -d --force-recreate`, and if you would rather
the dashboard owned it, delete the `PB_ADMIN_PASSWORD` line from .env once you have set your
own.

## 11. Out of scope

- Do not configure SMTP or S3 file storage. PocketBase's core loop needs neither, the superuser
  account this install creates needs no mail, and uploaded files belong in /pb_data, which is
  what step 8 backs up.
- Do not set `--encryptionEnv`. That flag encrypts the SMTP password and the S3 credentials
  stored in the database, and this install configures neither of them.
- Do not add mounts for /pb_public or /pb_hooks. Serving a frontend and writing JavaScript
  hooks are compose edits you make once you have something to put in them.
- Do not build an application on top of this. Collections and API rules are your work, and each
  is a decision this install has no business making for you.
