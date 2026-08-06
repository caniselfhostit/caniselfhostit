This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Memos 0.30.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Two things to know before step 1, because they decide whether you want this at all. Memos is a
capture stream: short markdown notes with tags, newest first, read and written in a browser.
There is no first-party phone app and the third-party ones do not speak this release yet, so on a
phone this is a web page saved to your home screen. And nothing here is end-to-end encrypted:
every entry sits in a SQLite file the server can read, and from today you are the person who runs
that server.

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
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for this
hostname while the certificate is issued.

## 2. Layout

Three directories and one configuration file. That file is the security decision in this install,
and it is written before the container has ever run, so paste the whole block at once.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/memos /srv/memos/backups
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/memos/config
sudo install -d -m 750 -o 10001 -g 10001 /srv/memos/data
cat > /srv/memos/config/memos-instance-setting-general.json <<'EOF'
{
  "key": "GENERAL",
  "generalSetting": {
    "disallowUserRegistration": true
  }
}
EOF
chmod 644 /srv/memos/config/memos-instance-setting-general.json
ls -la /srv/memos /srv/memos/config
```

You should see: `data` owned by `10001`, `config` at `drwxr-xr-x` owned by you, `backups` owned
by you, and `memos-instance-setting-general.json` at `-rw-r--r--`.

If you do not: leave `data` owned by 10001 on purpose. Memos runs as that uid and writes its
database there. The JSON file is world-readable for the same reason, and that is safe here
because it holds one policy flag and no credential. Upstream reads files of exactly that name
from that mount once per process, so any later edit needs a container restart to mean anything.

## 3. Secrets

There are none to generate, and there is no `.env` file on this server. Memos keeps its own
session key inside its database, and the only credential a human types is the administrator
password you choose in a browser at step 7.

That is what step 2 bought you. Most first-run installs leave registration open between the
container starting and somebody claiming the account, then close it afterwards.
`disallowUserRegistration` is already on before the first request arrives, and the first account
still gets through, because an instance with zero users takes the setup path rather than the
registration path. Step 7 checks both halves of that.

Do not paste your Memos password, any personal access token you create later, or any command
output containing either, into this chat window. Nothing in this install writes a secret to a
file, so there is no file to leak; the password in your head is the whole credential, and a chat
window is a third party.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/memos/compose.yml <<'EOF'
# Memos · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose ....... https://www.usememos.com/docs/deploy/docker-compose
#   configuration ........ https://www.usememos.com/docs/configuration/environment-variables
#   security ............. https://www.usememos.com/docs/configuration/security
#   provisioning ......... https://github.com/usememos/memos/blob/v0.30.0/docs/configuration-provisioning.md
#
# One service and one SQLite file. There is no `user:` line on purpose: the
# image entrypoint starts as root, hands /var/opt/memos to uid 10001 and
# re-execs as that user, so pinning a uid here would undo the fix it performs
# for you. MEMOS_INSTANCE_URL is deliberately absent, because upstream treats an
# instance without one as private and limits anonymous callers to the sign-in
# endpoints. The read-only /etc/secrets bind carries one deployment
# configuration file, written in step 2, that turns self-registration off before
# the first request is ever served. Tag and digest read from Docker Hub on
# 2026-08-06; the image publishes amd64, arm64 and arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  memos:
    image: neosmemo/memos:0.30.0@sha256:71a5b4738d1bed96e92112004054f0888e92791b64eb78afd79077c96e6f9327
    container_name: memos
    restart: unless-stopped
    environment:
      MEMOS_PORT: "5230"
      MEMOS_DATA: /var/opt/memos
      MEMOS_DRIVER: sqlite
      # No MEMOS_INSTANCE_URL here. Empty means private, and private means an
      # anonymous visitor gets the sign-in page and nothing else.
    volumes:
      # memos_prod.db plus the assets/ folder that attachments land in.
      - /srv/memos/data:/var/opt/memos
      # Deployment configuration, read once at start-up and never written to.
      - type: bind
        source: /srv/memos/config
        target: /etc/secrets
        read_only: true
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8131.
      - "127.0.0.1:8131:5230"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:5230/healthz"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd /srv/memos && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/memos/compose.yml` and paste again in one go. There is no database
container and there is no second service: Memos writes everything to `data/memos_prod.db` and
puts uploaded photos beside it in `data/assets`.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-memos
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Memos · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.usememos.com/docs/deploy/reverse-proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Memos runs its own
# HTTP server and upstream still asks you to put a proxy in front of it that
# terminates TLS. This is that proxy.

<DOMAIN> {
	# The app bundle and the JSON API compress well. Caddy's default encode
	# matcher covers text, JSON, JavaScript and SVG only, so a photo attached
	# to an entry passes through untouched.
	encode zstd gzip

	# Memos sets no frame or transport headers of its own on the app routes,
	# so they are set here. HSTS is on because every request to this host
	# carries the session cookie for somebody's journal.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8131 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Caddy applies no
	# default request body limit, so a 30 MB attachment upload gets through,
	# and it flushes text/event-stream as it arrives, which is what the live
	# timeline updates ride on.
	reverse_proxy 127.0.0.1:8131
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-memos /etc/caddy/Caddyfile`, reload, and
paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the other.
Caddy requests the certificate on the first request to the hostname and renews it on its own, so
there is nothing to schedule and no cron job to forget.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8131` or `5230`.

If you do not: delete anything for `8131` with `sudo ufw delete allow 8131`. That port is bound
to 127.0.0.1 by the compose file, so a firewall rule for it would cover traffic that cannot
arrive. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem:
Prompt Zero left this firewall enabled, so something has turned it off since, and `sudo ufw
enable` puts it back before you go any further.

## 7. Start and verify

```bash
cd /srv/memos
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/healthz; echo
curl -sS https://<DOMAIN>/api/v1/instance/profile; echo
curl -sS https://<DOMAIN>/api/v1/instance/settings/GENERAL; echo
```

You should see, in order: the loop reaching `200`; the words `Service ready.`; a small JSON
object containing `"version":"0.30.0"` and `"needsSetup":true`; and a second JSON object
containing `"disallowUserRegistration":true`.

If you do not: those last two lines are the ones worth understanding. `"needsSetup":true` means
no account exists yet, and `"disallowUserRegistration":true` means nobody except the very first
visitor can make one, which is the whole point of step 2. If the loop never reaches `200`, run
`docker compose logs --tail 40 memos`: a container that exits immediately is step 2 done wrong,
because a malformed file under that mount makes Memos refuse to start rather than ignore it. A
`502` from Caddy with a container that stays up is step 5. A running container is not success.

Now claim the account, and go straight to this path rather than to the site root:

```
https://<DOMAIN>/auth/signup
```

You should see: a page headed `Set up your instance` above
`Create the administrator account for this instance.`, with a `First run` badge, a username box,
a password box and a `Create admin account` button. Fill it in, use a password you generated in
your password manager, and save it there before you submit.

If you do not: opening https://<DOMAIN> instead lands you on a sign-in page with no way to make
an account, which looks broken and is not. Closing registration in step 2 also removes the
sign-up link from that page; the first-run form is still at /auth/signup whether or not anything
links to it.

Then prove the setup path shut behind you:

```bash
curl -sS https://<DOMAIN>/api/v1/instance/profile; echo
```

You should see: a JSON object that now contains `"admin":` and no longer contains
`"needsSetup":true`.

If you do not: `"needsSetup":true` still means no account exists and the server is still
claimable by anyone who finds the hostname. Go back to /auth/signup and finish the form before
you do anything else.

## 8. First backup and restore

One archive: the database, the photos, the deployment configuration and the live Caddy site
block. Take it now, before you write anything you would miss.

```bash
cd /srv/memos
docker compose stop
sudo tar -czf /srv/memos/backups/memos-$(date +%F).tar.gz -C /srv/memos data config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/memos/backups/
```

You should see: one `.tar.gz`, a few hundred kilobytes on a fresh install. The site is down for
about five seconds, on purpose: a SQLite database copied mid-write is not a backup.

If you do not: an archive of about 100 bytes means `tar` found nothing, which usually means you
are in the wrong directory. Check `ls /srv/memos` shows `data`, `config` and `compose.yml`.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/memos
scp vps:/srv/memos/backups/*.tar.gz ~/backups/memos/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/memos/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty journal:

```bash
cd /srv/memos
docker compose down
sudo rm -rf /srv/memos/data
sudo install -d -m 750 -o 10001 -g 10001 /srv/memos/data
sudo tar -C /srv/memos -xzf /srv/memos/backups/memos-$(date +%F).tar.gz data config compose.yml
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/v1/instance/profile; echo
```

You should see: the same JSON as at the end of step 7, containing `"admin":` and no
`"needsSetup":true`. Your account survived a data directory that was deleted and rebuilt, and
you can sign in with the same password.

If you do not: `"needsSetup":true` here means the archive did not contain the database, so the
container started on an empty directory and offered you setup again. Do not create a second
account on top of it; restore the archive again and check `tar -tzf` on the file lists
`data/memos_prod.db`. Entries, tags and accounts live in that one file, and attached photos are
ordinary files under `data/assets`.

## 9. Updating later

New versions are listed at https://github.com/usememos/memos/releases. Take a backup first, then
edit the `image:` line in /srv/memos/compose.yml to the new tag and its digest. The Docker Hub
tag drops the leading `v`, so release `v0.31.0` is image tag `0.31.0`.

```bash
cd /srv/memos
docker compose pull
docker compose up -d
docker compose logs --tail 30 memos
```

You should see: migration lines, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/healthz` and profile checks from step 7 before you call the update done, and sign in as well,
because a server that answers `Service ready.` can still be failing a migration that only shows
up when the app loads a page.

## 10. What will probably go wrong

You will open https://<DOMAIN> after step 7 starts the container, land on a sign-in page with a
username box, a password box and no way to make an account, and conclude something is broken. I
did, and I spent ten minutes re-reading the compose file. Nothing was wrong: closing registration
in step 2 also removes the sign-up link from the sign-in page, and the first-run form lives at
https://<DOMAIN>/auth/signup whether or not anything links to it. Go straight to that path. Do
not switch `disallowUserRegistration` back to false to make the link reappear; that reopens the
server to anyone who finds the hostname.

## 11. Out of scope

- Do not set `MEMOS_INSTANCE_URL`. Upstream uses it as the switch for anonymous public access,
  and this install is a private journal that answers strangers with a sign-in page.
- Do not switch `MEMOS_DRIVER` to postgres or mysql. SQLite is the choice here, and it is what
  makes this one container and one file to copy.
- Do not configure SMTP, an S3 bucket or an AI provider in the instance settings. Each is an
  account somewhere else, and the file written in step 2 owns the general settings group only.
- Do not install the Telegram integration or the web clipper. They are separate upstream
  services with their own containers, and this prompt installs the server they would talk to.
