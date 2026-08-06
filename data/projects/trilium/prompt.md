You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Trilium 0.104.1 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. Its A record must already point at this server. Say one thing when you ask: Trilium
does not support multiple users, so this hostname is a personal notebook, not a team space.

Trilium needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64, and armv7 and armv8 on a best-effort basis. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop.
Do not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot
be issued a certificate for a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/trilium /srv/trilium/backups
sudo install -d -m 700 /srv/trilium/data
ls -la /srv/trilium
```

Assert: `ls -la` shows `backups` owned by the login user and `data` at mode `700` owned by
root. Leave `data` owned by root on purpose. The Trilium image starts as root, chowns that
directory to the `node` user inside the container and then drops to it, so an ownership fix
here is undone on the next start. Everything the service keeps lives under that one
directory: `document.db`, the `config.ini` it writes on first start, its own rolling backup
copies, and the logs.

## 3. Secrets

One secret: the password the user will type into Trilium's set-password screen in step 7.
Generate it on the server. Do not print it, do not repeat it in your summary, and do not put
it in any log line.

```bash
umask 077
openssl rand -base64 24 > /srv/trilium/login-password
chmod 600 /srv/trilium/login-password
umask 022
ls -l /srv/trilium/login-password
```

Assert: the file exists with mode `-rw-------`. There is no `.env` here and this value is
never handed to the container: Trilium takes its password from a form a human fills in, so
the credential stays out of the application's environment. Tell the user to read it
themselves with `sudo cat /srv/trilium/login-password`, and that changing it later happens
inside Trilium under Options, which does not update this file.

## 4. compose.yml

```bash
cat > /srv/trilium/compose.yml <<'EOF'
# Trilium · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.triliumnotes.org/user-guide/setup/server/installation/docker
#   configuration ...... https://docs.triliumnotes.org/user-guide/advanced-usage/configuration
#   trusted proxy ...... https://docs.triliumnotes.org/user-guide/setup/server/reverse-proxy/trusted-proxy
#   data directory ..... https://docs.triliumnotes.org/user-guide/setup/data-directory
#   image definition ... https://github.com/TriliumNext/Trilium/blob/v0.104.1/apps/server/Dockerfile
#
# One service. Everything Trilium owns lives in one directory: document.db, the
# config.ini it writes on first start, the automatic backup copies and the logs.
# There is no database process here and nothing to dump. The container starts as
# root, chowns that directory to the node user inside it and then drops to that
# user, which is why /srv/trilium/data is created once at mode 700 and left
# alone afterwards. No env_file: nothing this container needs is a secret. The
# one credential this install generates is the password a human types into the
# browser, and it is kept out of the application's environment on purpose.
# Tag and digest were read from Docker Hub on 2026-08-06; the image publishes
# amd64 and arm64, plus armv7 and armv8 on a best-effort basis.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  trilium:
    image: triliumnext/trilium:v0.104.1@sha256:3332fa03198f0b3ecddf11fcf37f3aace352a664728d669a1ffa7a5594a6f2d6
    container_name: trilium
    restart: unless-stopped
    environment:
      # The single directory this service writes to, inside the container.
      TRILIUM_DATA_DIR: /home/node/trilium-data
      # Caddy is in front, so the visitor's address arrives in X-Forwarded-For
      # and Trilium reads the left-most entry from it. The Caddyfile overwrites
      # that header rather than appending to it, so the entry is Caddy's own
      # measurement and the login rate limiter counts the right address.
      TRILIUM_NETWORK_TRUSTEDREVERSEPROXY: "true"
      # Day notes roll over at midnight in this zone, and the daily automatic
      # backup follows it. UTC is the choice here; another tz database name is
      # a one-line edit.
      TZ: UTC
    volumes:
      - /srv/trilium/data:/home/node/trilium-data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8103.
      - "127.0.0.1:8103:8080"
EOF
cd /srv/trilium && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one bind mount. There is
no database container because there is no database process: Trilium writes a SQLite file
inside the directory step 2 created, which is what makes step 8 one archive and not a dump
plus an archive.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by
the real hostname. Copy the file first: a syntax error here takes down every other site on
the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-trilium
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Trilium · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.triliumnotes.org/user-guide/setup/server/reverse-proxy/trusted-proxy,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Trilium speaks
# plain http on loopback and Caddy terminates TLS in front of it; the browser
# and the server also hold a WebSocket open for live updates, which Caddy
# upgrades without any extra directive.

<DOMAIN> {
	# The client is a large JavaScript bundle, so compression pays for itself
	# on the first load. WebSocket upgrades pass through untouched.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8103 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8103 {
		# Set, not append. Caddy's default is to add the client address to
		# whatever X-Forwarded-For arrived, and Trilium trusts the left-most
		# entry, so without this line a visitor could put any address at the
		# front and the login rate limiter would count their attempts against
		# a stranger.
		header_up X-Forwarded-For {remote_host}
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-trilium, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own, so there is nothing to
schedule. The `header_up` line is the security-relevant one: Caddy appends to whatever
`X-Forwarded-For` a visitor sent, Trilium reads the left-most entry from that header, and
overwriting it is what keeps the login rate limiter counting the right address.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8103 stays closed because compose binds it to 127.0.0.1 and the host's
Caddy is the only thing that reaches it. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule for 8103. If a previous run left one, remove it
with `sudo ufw delete allow 8103`.

## 7. Start and verify

Read this whole block before running anything in it. A brand new Trilium has no account, and
it serves every request without authentication until one exists, so the window between the
container starting and the user finishing the wizard is a window in which anyone who knows
the hostname can finish it instead. Do not start the container unless the user is at a
browser now.

```bash
cd /srv/trilium
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health-check); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/api/health-check
curl -sS https://<DOMAIN>/bootstrap | grep -o '"triliumVersion":"[^"]*"'
```

Assert, all three: the loop ends printing `200`; the health call prints `{"status":"ok"}`;
the last line prints `"triliumVersion":"0.104.1"`, which is how you know the pinned digest is
the code that is running. Print what you received for each. If any of the three misses, stop,
run `docker compose logs --tail 40 trilium`, and say which earlier step is the likely cause: a
`404` where `200` was expected means Caddy is not reaching the container, and a connection
error on the first attempt is usually the certificate still being issued.

The first screen at https://<DOMAIN> is the setup wizard. It is headed `Language` with a
`Continue` button; the screen after that is headed `Get started with Trilium` and offers
`New knowledge base`. Once the knowledge base exists, Trilium shows a screen headed
`Set password`.

STOP: tell the user to open https://<DOMAIN> now, pick a language, choose `New knowledge base`
and then `Empty`, and when the `Set password` screen appears to read their password with
`sudo cat /srv/trilium/login-password` and paste it into both fields. Wait. Do not continue
until they confirm they are signed in.

Once they confirm, prove the instance is no longer open:

```bash
curl -sS https://<DOMAIN>/bootstrap | grep -o '"loggedIn":false'
```

Assert: that prints `"loggedIn":false`. That is the whole security claim of this install in
one line, because the same request answered without it a few minutes ago: the server now
refuses to hand the application to a client that has not logged in. If it prints nothing, the
password was not set, the instance is still open, and the fix is to finish the wizard rather
than to carry on. A running container is not success.

## 8. First backup and restore

One artifact. The notes, the settings, the password file and the config that rebuilds the
service around them.

```bash
cd /srv/trilium
docker compose stop
sudo tar -czf /srv/trilium/backups/trilium-$(date +%F).tar.gz -C /srv/trilium data login-password compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/trilium/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped for the
few seconds the archive takes, because Trilium writes its SQLite database continuously and a
copy taken mid-write is not a copy. Trilium also keeps its own rolling copies under
`/srv/trilium/data/backup`, one daily, one weekly, one monthly and one before each version
migration, and they sit on the same disk as the original, so they cover a bad edit and not a
dead disk.

A backup on the same disk is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/trilium
scp vps:/srv/trilium/backups/*.tar.gz ~/backups/trilium/
```

To restore: `docker compose down`, `sudo rm -rf /srv/trilium/data`, recreate it as in step 2,
`sudo tar -xzf` the archive into /srv/trilium, then `docker compose up -d`. The notes are in
`data/document.db`, the password is in `login-password`, and the archive's `Caddyfile` member
is the live site block copied from /etc/caddy, for the day that is what is missing. Tell the
user that is the whole disaster plan, and that the archive holds their password in clear
text, so wherever they copy it is as sensitive as the notes.

## 9. Updating later

New versions are listed at https://github.com/TriliumNext/Trilium/releases. Take a backup
first, then edit the image line in /srv/trilium/compose.yml to the new tag and its digest:

```bash
cd /srv/trilium
docker compose pull
docker compose up -d
docker compose logs --tail 30 trilium
```

Trilium migrates its own database on the way up and writes a copy of the old one into
`data/backup` before it does. Watch that log until it settles, then re-run the health check
from step 7 and confirm `"triliumVersion"` reports the new number before calling the update
done.

## 10. What will probably go wrong

The gap in step 7 is wider than it looks. I brought Trilium up on a VPS, got pulled into
something else before opening the browser, and came back to an instance that had been
publicly reachable with no password on it for forty minutes. Nothing had happened, but
nothing had to: while the database is uninitialised there is nobody to authenticate, so
upstream lets every request through, and whoever loads that URL first is the person who
completes the wizard and picks the password. Run step 7 in one sitting with the user at a
browser. If they have to walk away before the `Set password` screen, run `docker compose down`
and start step 7 again when they are back.

## 11. Out of scope

- Do not configure SMTP. Trilium sends no mail and has no password-reset email, which is
  exactly why step 3 puts the password in a file the user owns.
- Do not set up sync or a second instance. Trilium's sync is one server and one desktop app
  holding the same single-user document, not a way to give a second person an account.
- Do not enable OpenID Connect or TOTP. Both are real features and both are a second signup
  or a second device, and this prompt installs one service with one credential.
- Do not turn on batch OCR. Tesseract runs on this box's CPU and processing an existing note
  tree is an hour of load the user did not ask for tonight.
