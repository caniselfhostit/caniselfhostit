This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Trilium 0.104.1 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

One thing to know before step 1, because it shapes what you are building. Trilium does not
support multiple users. One instance is one person's knowledge base, so the hostname you pick
is a personal notebook and a second person means a second container with its own data
directory and its own hostname.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, and run `dig +short <DOMAIN>` again. Caddy cannot be issued a certificate for a
hostname that does not resolve, and failed attempts count against a rate limit you cannot
see. If the architecture prints `armhf` you are on 32-bit ARM, which the image still builds
but which upstream supports on a best-effort basis only.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/trilium /srv/trilium/backups
sudo install -d -m 700 /srv/trilium/data
ls -la /srv/trilium
```

You should see: `backups` owned by you, and `data` at mode `drwx------` owned by root.

If you do not: leave `data` owned by root on purpose. The Trilium image starts as root,
chowns that directory to the `node` user inside the container and then drops to it, so an
ownership fix you make here is undone on the next start. Everything the service keeps lives
in that one directory: `document.db` with your notes in it, the `config.ini` it writes on
first start, its own rolling backup copies, and the logs.

## 3. Secrets

One secret: the password you will type into Trilium's set-password screen in step 7. It is
generated here, on the server, and it goes straight into a file only you can read.

```bash
umask 077
openssl rand -base64 24 > /srv/trilium/login-password
chmod 600 /srv/trilium/login-password
umask 022
ls -l /srv/trilium/login-password
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/trilium/login-password`
and carry on. If the file already existed from an earlier attempt, this block has now
overwritten it, which is fine before you have set a password in the browser and useless
afterwards, because Trilium keeps the password you actually typed and this file is not
consulted again.

Do not paste that file, that password, or any command output containing it into this chat
window. Read it with `sudo cat /srv/trilium/login-password` in your own terminal in step 7,
paste it straight into the browser form, and put it in your password manager. There is no
`.env` in this install and this value is never handed to the container: Trilium takes its
password from a form a human fills in, so the credential stays out of the application's
environment. Changing it later happens inside Trilium under Options, which does not update
this file.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page
and your terminal. Run `rm /srv/trilium/compose.yml` and paste again in one go. There is no
database container here because there is no database process: Trilium writes a SQLite file
into the directory step 2 created, which is what makes the backup in step 8 a single archive
rather than a dump plus an archive.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-trilium /etc/caddy/Caddyfile`, reload,
and paste again. The `header_up` line is the one worth understanding rather than skipping.
Caddy adds your address to whatever `X-Forwarded-For` a visitor sent instead of replacing it,
and Trilium reads the left-most entry from that header, so without this line a stranger could
put any address at the front and the login rate limiter would count their guesses against
somebody else.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8103`.

If you do not: delete anything for `8103` with `sudo ufw delete allow 8103`. That port is
bound to 127.0.0.1 by the compose file, so the host's Caddy is the only thing that reaches it
and a firewall rule would only widen the install. 80/tcp is there to redirect to HTTPS and to
answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy
offers by default. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back before you
go any further.

## 7. Start and verify

Read this whole block before you run any of it. A brand new Trilium has no account, and it
serves every request without authentication until one exists, so the minutes between the
container starting and you finishing the wizard are minutes in which anyone who knows the
hostname can finish it instead of you. Do not start the container unless you are at a browser
right now.

```bash
cd /srv/trilium
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health-check); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/api/health-check
curl -sS https://<DOMAIN>/bootstrap | grep -o '"triliumVersion":"[^"]*"'
```

You should see, in order: the loop reaching `200`, then `{"status":"ok"}`, then
`"triliumVersion":"0.104.1"`.

If you do not: a `404` where `200` was expected means Caddy is not reaching the container, so
check `docker compose ps`. A connection error on the first few attempts is usually the
certificate still being issued, which is why the loop runs for two and a half minutes. If the
version line prints a different number, the image line in your compose file is not the one
this page pinned. Run `docker compose logs --tail 40 trilium` before changing anything else.

Now open https://<DOMAIN> in a browser. The first screen is the setup wizard, headed
`Language` with a `Continue` button. Pick a language, then on the screen headed
`Get started with Trilium` choose `New knowledge base`, then `Empty`. When the screen headed
`Set password` appears, read your password in your terminal with
`sudo cat /srv/trilium/login-password` and paste it into both fields.

Once you are signed in, prove the instance is no longer open:

```bash
curl -sS https://<DOMAIN>/bootstrap | grep -o '"loggedIn":false'
```

You should see: `"loggedIn":false`.

If you do not: nothing printed means no password is set and the instance is still serving
itself to anyone who asks, so go back and finish the wizard rather than carrying on. This one
line is the whole security claim of the install, because the same request answered without it
a few minutes ago. A running container is not success.

## 8. First backup and restore

One artifact. Your notes, your settings, the password file and the config that rebuilds the
service around them.

```bash
cd /srv/trilium
docker compose stop
sudo tar -czf /srv/trilium/backups/trilium-$(date +%F).tar.gz -C /srv/trilium data login-password compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/trilium/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install. Trilium is offline for
the few seconds the archive takes, because it writes its SQLite database continuously and a
copy taken mid-write is not a copy.

If you do not: an archive of about 100 bytes means `tar` found nothing, which means step 2
made the directory somewhere else. Trilium also keeps its own rolling copies under
/srv/trilium/data/backup, one daily, one weekly, one monthly and one per version migration.
Those live on the same disk as the original, so they cover a bad edit and not a dead disk.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/trilium
scp vps:/srv/trilium/backups/*.tar.gz ~/backups/trilium/
```

You should see: one file copied, and listed by `ls -lh ~/backups/trilium/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the alias Prompt Zero created lives.
That archive holds your password in clear text, so wherever it lands is as sensitive as the
notes.

Now prove the restore, today, while the only thing at risk is an empty notebook:

```bash
cd /srv/trilium
docker compose down
sudo rm -rf /srv/trilium/data
sudo install -d -m 700 /srv/trilium/data
sudo tar -xzf /srv/trilium/backups/trilium-$(date +%F).tar.gz -C /srv/trilium data
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/bootstrap | grep -o '"loggedIn":false'
```

You should see: `"loggedIn":false` again, and your own notes when you reload the browser,
which means the database survived being deleted and put back.

If you do not: if the browser offers the setup wizard again, the archive did not contain
`data/document.db` and the restore put back an empty directory. Check with
`sudo tar -tzf /srv/trilium/backups/trilium-$(date +%F).tar.gz | head` before you trust
either the archive or the procedure.

## 9. Updating later

New versions are listed at https://github.com/TriliumNext/Trilium/releases. Take a backup
first, then edit the `image:` line in /srv/trilium/compose.yml to the new tag and its digest.

```bash
cd /srv/trilium
docker compose pull
docker compose up -d
docker compose logs --tail 30 trilium
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Trilium
migrates its own database on the way up and writes a copy of the old one into
/srv/trilium/data/backup before it does, so a failed upgrade has a file to go back to. Re-run
the health check from step 7 and confirm `"triliumVersion"` reports the new number before you
call the update done.

## 10. What will probably go wrong

The gap in step 7 is wider than it looks. I brought Trilium up on a VPS, got pulled into
something else before opening the browser, and came back to an instance that had been
publicly reachable with no password on it for forty minutes. Nothing had happened, but
nothing had to: while the database is uninitialised there is nobody to authenticate, so
upstream lets every request through, and whoever loads that URL first is the person who
completes the wizard and picks the password. Run step 7 in one sitting with a browser open.
If you have to walk away before the `Set password` screen, run `docker compose down` and start
step 7 again when you are back.

## 11. Out of scope

- Do not configure SMTP. Trilium sends no mail and has no password-reset email, which is
  exactly why step 3 puts the password in a file you own.
- Do not set up sync or a second instance. Trilium's sync is one server and one desktop app
  holding the same single-user document, not a way to give a second person an account.
- Do not enable OpenID Connect or TOTP. Both are real features and both are a second signup
  or a second device, and this install has one service and one credential.
- Do not turn on batch OCR. Tesseract runs on this box's CPU, and processing an existing note
  tree is an hour of load you did not ask for tonight.
