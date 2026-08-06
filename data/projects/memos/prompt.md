You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Memos 0.30.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things to the user before anything installs, because together they decide whether they
want this at all. Memos is a capture stream: short markdown notes with tags, newest first, read
and written in a browser. There is no first-party phone app, and the third-party ones do not
speak this release yet, so on a phone this is a web page saved to the home screen. And nothing
here is end-to-end encrypted: every entry sits in a SQLite file this server can read, and from
today they are the person who runs that server.

Memos needs 512 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and arm64.
Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a hostname that does not resolve.

## 2. Layout

Three directories and one configuration file. That file is the security decision in this install,
so it is written before the container has ever run.

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

Assert: `ls -la` shows `data` owned by uid `10001`, `config` at mode `755`, and the JSON file at
mode `644`. Memos runs as uid 10001 and reads that file at start-up, so it is world-readable on
purpose: the container user is not the login user, and the file holds a policy flag rather than
a credential. Upstream scans /etc/secrets once per process for filenames of exactly this shape,
which means an edit here takes effect on the next restart and at no other time.

## 3. Secrets

No secret is generated for this install and there is no `.env` file. Memos keeps its own session
key inside its database, and the only credential a human ever types is the administrator account
created in a browser at step 7.

That is also why step 2 ran first. Most first-run installs leave registration open between the
container starting and a human claiming the account, and close it afterwards.
`disallowUserRegistration` is already on here before the first request arrives, and the very
first account still gets through, because an instance with zero users takes the setup path
rather than the registration path. Step 7 asserts both halves of that.

Tell the user now: after step 7 nobody can sign themselves up on this server, and the way to add
a second person is to create the account for them from the administrator settings.

## 4. compose.yml

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

Assert: that prints `compose OK`. One service, one published port, no database container: Memos
writes everything to `data/memos_prod.db` and puts uploaded photos beside it in `data/assets`.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-memos, reload, and report what it objected to. Caddy requests the
certificate on the first request to the hostname and renews it on its own, so there is nothing
to schedule.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3. 8131 stays closed because compose binds it to 127.0.0.1 and Caddy is the only
thing that speaks to it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp
and 443/udp, and no rule mentioning 8131 or 5230.

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

Assert all four, and print what you received for each: the loop ends printing `200`; the health
endpoint answers `Service ready.`; the profile JSON contains `"version":"0.30.0"` and
`"needsSetup":true`; the settings JSON contains `"disallowUserRegistration":true`. Those last two
together are the security assert in this block, and the order is the point: registration is shut
and no account exists yet. If the loop never reaches 200, stop, run
`docker compose logs --tail 40 memos`, and say which earlier step is the likely cause: a
container that exits immediately is usually step 2, because a malformed file under that mount
makes Memos refuse to start rather than ignore it, and a 502 from Caddy with a healthy container
is step 5. A running container is not success.

STOP: tell the user to open https://<DOMAIN>/auth/signup, create their account, put the password
in their password manager, and wait. Do not continue until they confirm. That exact path matters:
the sign-in page at https://<DOMAIN> carries no sign-up link, because step 2 turned registration
off. The screen at /auth/signup reads `Set up your instance` above
`Create the administrator account for this instance.`, with a `First run` badge and a
`Create admin account` button.

Once they confirm:

```bash
curl -sS https://<DOMAIN>/api/v1/instance/profile; echo
```

Assert: the response now contains `"admin":` and no longer contains `"needsSetup":true`. That is
the setup path closed behind them, and it is the other half of the security assert. If it still
prints `"needsSetup":true`, the account was not created and the server is still claimable; do
not go on.

## 8. First backup and restore

One archive: the database, the photos, the deployment configuration and the live Caddy site
block. Take it now, before the user writes anything they would miss.

```bash
cd /srv/memos
docker compose stop
sudo tar -czf /srv/memos/backups/memos-$(date +%F).tar.gz -C /srv/memos data config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/memos/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds, and
the container is stopped on purpose, because a SQLite database copied mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/memos
scp vps:/srv/memos/backups/*.tar.gz ~/backups/memos/
```

To restore: `docker compose down`, `sudo rm -rf /srv/memos/data`, recreate the directories as in
step 2, untar the archive back into /srv/memos, put the Caddy block back if that is what was
lost, then `docker compose up -d`. Entries, tags and accounts live in `data/memos_prod.db`, and
attached photos are ordinary files under `data/assets`, so a single entry can be recovered from
the archive with `sqlite3` and a copy command if the whole restore is more than the user needs.

## 9. Updating later

New versions are listed at https://github.com/usememos/memos/releases. Take a backup first, then
edit the image line in /srv/memos/compose.yml to the new tag and its digest. The Docker Hub tag
drops the leading `v`, so release `v0.31.0` is image tag `0.31.0`.

```bash
cd /srv/memos
docker compose pull
docker compose up -d
docker compose logs --tail 30 memos
```

Memos migrates its own database on the way up. Watch that log until it settles, then re-run the
`/healthz` and profile checks from step 7 before calling the update done.

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
