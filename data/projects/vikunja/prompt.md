You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Vikunja 2.5.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and the same hostname becomes
`VIKUNJA_SERVICE_PUBLICURL` in step 3. Vikunja refuses to start when that value is empty, so the
two are not independent choices.

Vikunja needs 512 MB of RAM available and 5 GB free on /srv. It is one Go binary with an
embedded SQLite database, and the image publishes amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve, and the failed attempts count against a rate limit
you cannot see.

## 2. Layout

The container runs as uid 1000 with no group, so the two directories it writes to are owned by
that uid rather than by the login user:

```bash
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" /srv/vikunja /srv/vikunja/backups
sudo install -d -m 750 -o 1000 -g "$(id -g)" /srv/vikunja/db /srv/vikunja/files
ls -la /srv/vikunja
```

Assert: `ls -la` shows four entries, with `backups` owned by the login user and `db` and `files`
owned by `1000`. On a box where the login user already is uid 1000 those look the same, which is
fine. `db` will hold one SQLite file and `files` will hold every attachment anyone uploads.

## 3. Secrets

One secret: the signing key Vikunja uses for session tokens. Generate it on the server, do not
print it, do not repeat it in your summary, and do not put it in any log line. Hex rather than
base64 so nothing downstream has to escape it.

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

Assert: the file exists with mode `-rw-------`. Replace `<DOMAIN>` on the first line with the
real hostname before running the block. Upstream documents that without this value a fresh
random one is generated at every start, which signs out every logged-in session on every restart,
so this file is the difference between an app that remembers people and one that does not. The
user can read it back with `sudo grep VIKUNJA_SERVICE_SECRET /srv/vikunja/.env`; tell them that
command rather than the value. Registration is open only until step 7 closes it.

## 4. compose.yml

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

Assert: that prints `compose OK`. Upstream also documents a PostgreSQL compose example, and this
install does not use it. A single-user task list is the case SQLite was built for, and the image
already points at `/db/vikunja.db` without being asked.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-vikunja, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. The commands are idempotent, so on a box Prompt Zero configured
they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8097 stays closed because compose binds it to 127.0.0.1 and Caddy reaches it from the
same host. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp,
and no rule mentioning 8097. If an earlier run left one, remove it: `sudo ufw delete allow 8097`.

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

Assert both: the loop ends printing `200`, and the second command prints
`"registration_enabled":true`. Print what you received for each. If either misses, stop, run
`docker compose logs --tail 40 vikunja`, and say which earlier step is the likely cause. A log
line about the public URL points at step 3; one about opening the database points at step 2. A
running container is not success.

The first screen at https://<DOMAIN> is a login form with the heading `Login`, a field labelled
`Username Or Email Address`, and beneath the button the line `Don't have an account yet?` next to
a `Create account` link.

STOP: tell the user to open https://<DOMAIN>, follow `Create account`, register the one account
they want, and wait. Do not continue until they confirm. Registration is open to the whole
internet until they do and until the next block runs.

Once they confirm, close registration and restart:

```bash
sed -i 's/^VIKUNJA_SERVICE_ENABLEREGISTRATION=true$/VIKUNJA_SERVICE_ENABLEREGISTRATION=false/' /srv/vikunja/.env
docker compose up -d --force-recreate
sleep 15
curl -sS https://<DOMAIN>/api/v1/info | grep -o '"registration_enabled":[a-z]*'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' https://<DOMAIN>/api/v1/register
```

Assert both: the first prints `"registration_enabled":false`, and the second prints `404`, which
is what upstream's register handler returns once registration is off. Then have the user reload
https://<DOMAIN> and confirm the `Create account` link is gone. All three must pass before you
report success.

## 8. First backup and restore

Take the backup now, before the user moves a single task in. The image has no shell, so nothing
here runs inside the container: the archive is made on the host from the two mounted directories.
Stop the container first, because copying a SQLite file mid-write is not a backup.

```bash
cd /srv/vikunja
docker compose stop
sudo tar -C /srv/vikunja -czf /srv/vikunja/backups/vikunja-$(date +%F).tar.gz db files .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/vikunja/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/vikunja
scp vps:/srv/vikunja/backups/*.tar.gz ~/backups/vikunja/
```

To restore: `docker compose down`, `sudo rm -rf /srv/vikunja/db /srv/vikunja/files`, untar the
archive back into /srv/vikunja, re-run the two `install -d` lines from step 2 in case the
ownership did not survive the copy, then `docker compose up -d` and check step 7's info endpoint
again. Every task, project, comment and label is in `db/vikunja.db`; every attachment is a file
under `files/`; the signing key is in `.env`, and restoring the database without it signs
everyone out. Tell the user those five commands are the whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/go-vikunja/vikunja/releases. Take a backup first,
then edit the image line in /srv/vikunja/compose.yml to the new tag and its digest:

```bash
cd /srv/vikunja
docker compose pull
docker compose up -d
docker compose logs --tail 30 vikunja
```

Vikunja migrates its own database on the way up, so watch that log until it settles, then re-run
the info check from step 7 before calling the update done.

## 10. What will probably go wrong

Reminders. I set a due date, waited past it, and nothing arrived, and I spent twenty minutes
looking for a broken notification setting that does not exist. Upstream's reminder job only runs
when mail or webhooks can carry the message, and this install has no mail, so a due date here is
something you see when you open the app rather than something that comes to find you. If the user
is arriving from Todoist that is the one habit that does not survive the move. Tell them plainly
on the day they install it, not the week they miss something.

## 11. Out of scope

- Do not configure SMTP. It is a real gap, named in step 10, and fixing it means a mail provider,
  a sending domain and DNS records, which is a longer job than this whole install.
- Do not enable the Todoist migration. It needs a developer app registered in the user's Todoist
  account with a client id and secret, and that is their decision to make, not yours.
- Do not switch the database to PostgreSQL. SQLite is the choice here and the image expects it.
- Do not install a Vikunja Pro licence key. The admin panel, time tracking and audit logs are
  paid features; everything else works without one.
