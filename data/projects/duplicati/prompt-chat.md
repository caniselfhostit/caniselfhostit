This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Duplicati 2.3.0.4 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. Duplicati is a backup client, not a place to put backups. It reads files
on the machine it runs on, encrypts them there, and uploads the pieces to a destination you
supply and pay for: a bucket, an SFTP account, a disk in a friend's house. What stops is a
subscription; what starts is a storage bill, or a second box of your own. And the machine it runs
on is this server, so the files in scope are /srv and whatever your other services keep in it,
not your laptop.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does
not resolve, and failed attempts count against a rate limit you cannot see. If free disk is under
5 GB, stop and add disk. That 5 GB is the image, the temporary volumes Duplicati builds while
uploading, and a per-job database that grows with the number of files you track rather than with
their size.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/duplicati /srv/duplicati/backups
sudo install -d -m 700 /srv/duplicati/data /srv/duplicati/restore
ls -la /srv/duplicati
```

You should see: three directories, `backups` owned by you, and `data` and `restore` at mode
`drwx------` owned by root.

If you do not: leave the two root-owned ones alone. The container runs as root, because no UID
and GID pair is set for it and the files it reads under /srv were written by your other services
as other users. `data` is Duplicati's own settings database, which is a different thing from the
backups it makes: the image declares /data as a volume and points its config path there.

## 3. Secrets

Two secrets, generated here on the server, into a file only you can read. Do not paste the
contents of `.env`, or any command output containing one of these values, back into this chat
window. The chat you are reading is a third party; the file is not.

The first line is the security decision. Duplicati always has a web password: set none and it
generates a random one at first start, then writes a one-time sign-in link into the container
log, which is a credential sitting in `docker compose logs` on a public hostname. Setting the
password before the container has ever run replaces that with a value you own.
`SETTINGS_ENCRYPTION_KEY` is the one variable here with no `DUPLICATI__` prefix; it encrypts the
credential fields in the settings database, where your destination's access keys are about to
live. The third line is the hostname the API will answer for: the allowed list ships holding
localhost, 127.0.0.1 and bare IP addresses, so a Duplicati behind a real hostname refuses its own
front end until that name is added.

Replace `<DOMAIN>` on the last line with your hostname before you paste this.

```bash
umask 077
cat > /srv/duplicati/.env <<EOF
DUPLICATI__WEBSERVICE_PASSWORD=$(openssl rand -hex 24)
SETTINGS_ENCRYPTION_KEY=$(openssl rand -hex 32)
DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES=<DOMAIN>
EOF
chmod 600 /srv/duplicati/.env
umask 022
ls -l /srv/duplicati/.env
sudo grep DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES /srv/duplicati/.env
```

You should see: `-rw-------` on the listing, and your real hostname on the last line, bare, with
no scheme, no port and no angle brackets.

If you do not: if the last line still shows the placeholder, the substitution did not happen.
Fix the file before you go further, because the API answers 403 to every request through Caddy
until that value is right. Your web password is in that file and was never printed. Read it with
`sudo grep DUPLICATI__WEBSERVICE_PASSWORD /srv/duplicati/.env` and put both values in your
password manager today.

## 4. compose.yml

```bash
cat > /srv/duplicati/compose.yml <<'EOF'
# Duplicati · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker image readme . https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/ReleaseBuilder/Resources/Docker/README.md
#   image build ......... https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/ReleaseBuilder/Resources/Docker/Dockerfile
#
# One service. Duplicati is the backup client, not the storage behind it: it
# encrypts files here and uploads them to a destination you pay for
# separately. It runs as root, since no UID and GID pair is set and the files
# it reads under /srv belong to other services. .env carries the web password,
# the settings-database encryption key and the hostname the API answers for,
# because Duplicati refuses a request whose Host it does not know.
#
# Tag and digest read from docker.io on 2026-08-12; the manifest list covers
# amd64, arm64 and arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  duplicati:
    image: duplicati/duplicati:2.3.0.4-stable@sha256:01f8cb81ad7d548b7ceec61d696bb5d27d8057fee0ddee37c2b8a0ff1f1729f7
    container_name: duplicati
    restart: unless-stopped
    env_file: /srv/duplicati/.env
    environment:
      # The container's clock zone. Schedules fire against it.
      TZ: UTC
      # Usage reporting ships on; this is upstream's own opt-out variable.
      DO_NOT_TRACK: "1"
    volumes:
      # Duplicati-server.sqlite, the per-job databases, the JWT signing keys.
      - /srv/duplicati/data:/data
      # Everything this catalogue keeps, read only. Restores go to /restore.
      - /srv:/source:ro
      - /srv/duplicati/restore:/restore
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8188.
      - "127.0.0.1:8188:8200"
    healthcheck:
      # /health needs no token and no allowed hostname; curl is in the image.
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8200/health"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd /srv/duplicati && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `docker compose config` prints the line it objected to. A heredoc that was pasted
through a chat window sometimes loses its indentation, and YAML cares. The most common damage is
the two-space indent in front of `duplicati:` and the four in front of `image:`. Delete the file
and paste the block again rather than fixing it by eye.

## 5. Caddy and TLS

Write the site block to its own file, then append it with your hostname substituted. The copy on
the first line is your undo: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-duplicati
cat > /srv/duplicati/Caddyfile <<'EOF'
# Duplicati · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/ReleaseBuilder/Resources/Docker/README.md
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That name is
# also DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES in .env: Duplicati answers 403
# to an API request whose Host is not on its list, and that list ships
# holding localhost and nothing else.

<DOMAIN> {
	encode zstd gzip

	# Duplicati sets no transport headers of its own. HSTS is on because
	# every request here carries the token that reads this server.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8188 is the loopback port compose publishes here. It is not open in
	# the firewall. The progress feed on /notifications is a WebSocket,
	# which reverse_proxy upgrades with no extra directive.
	reverse_proxy 127.0.0.1:8188
}
EOF
DUP_HOST=$(sudo grep DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES /srv/duplicati/.env | cut -d= -f2-)
echo "site block will be appended for $DUP_HOST"
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sed "s|<DOMAIN>|$DUP_HOST|g" /srv/duplicati/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: your real hostname after `site block will be appended for`, then
`Valid configuration` from `caddy validate`, then nothing at all from the reload.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-duplicati /etc/caddy/Caddyfile`, reload, and read what
validate objected to. The substitution deliberately reads the hostname back out of .env rather
than asking you twice, so the site block and the allowed-hostnames value cannot drift apart. If
the echo printed nothing, step 3 did not write the file.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 80/tcp, 443/tcp and 443/udp. No rule mentioning
8188.

If you do not: if 8188 has a rule from an earlier attempt, remove it with
`sudo ufw delete allow 8188`. Compose binds that port to 127.0.0.1, so Caddy on this same box is
the only thing that can reach it, and opening it in the firewall would hand the login page to the
internet on plain HTTP. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the
way in, 443/udp is HTTP/3.

## 7. Start and verify

```bash
cd /srv/duplicati
docker compose pull
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/backups
printf '{"Password":"%s","RememberMe":false}' "$(sudo grep DUPLICATI__WEBSERVICE_PASSWORD /srv/duplicati/.env | cut -d= -f2-)" | curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @-
```

You should see: `Healthy`, then `401`, then `200`.

If you do not: the `401` is the security check, and it means the API refuses a call carrying no
token, so nobody who finds your hostname can read or edit a backup job. The `200` proves two
things at once: the generated password is the one the server holds, and the allowed-hostnames
value took effect, since that route rejects an unknown Host with `403` before it reads the body.
So a `403` on the last line points at step 3 or step 5, your hostname disagreeing between .env
and the Caddy block. A `401` on the last line means .env holds a password the container did not
start with, which happens if the container ran once before .env existed: `docker compose down`,
check the file, `docker compose up -d`. If the first command printed nothing at all, wait another
thirty seconds and run it again, then `docker compose logs --tail 40 duplicati`. A running
container is not success.

Now open https://<DOMAIN> in a browser. The first screen is one `Password` box: Duplicati has no
usernames and no second account. Read your password with
`sudo grep DUPLICATI__WEBSERVICE_PASSWORD /srv/duplicati/.env`, sign in, and do not go on until
you are looking at the inside of the application.

## 8. First backup and restore

Two different backups live in this step. The archive below backs up Duplicati itself, the
settings database that knows what to copy and where to send it. Your own first backup job is the
second half, and only you can make it.

```bash
cd /srv/duplicati
docker compose stop
sudo tar -czf /srv/duplicati/backups/duplicati-config-$(date +%F).tar.gz -C /srv/duplicati data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/duplicati/backups/
```

You should see: one `.tar.gz` with a size in kilobytes or more, never `0`.

If you do not: an archive of a few hundred bytes usually means `data` was empty because the
container had not started yet. The stop is on purpose, because a SQLite database copied
mid-write is not a backup, and it costs a few seconds. That archive holds .env, so it holds the
key protecting everything else in it: keep it where you keep passwords.

Then copy it off the box. Run this on your own machine, not the server:

```bash
mkdir -p ~/backups/duplicati
scp vps:/srv/duplicati/backups/*.tar.gz ~/backups/duplicati/
```

You should see: the filename listed as it copies, and the same file in `~/backups/duplicati`.

If you do not: a backup on the same disk as the data is not a backup. If `scp` cannot find the
alias `vps`, use the hostname you gave the server in your ssh config.

Now the half only you can do. In the browser, choose `Add backup`, set a passphrase, pick a
destination, add `/source` as the source folder with `/source/duplicati` excluded, run the job
once, then restore one file from it into `/restore`. Two things worth knowing while you do it.
The passphrase encrypts every file before it leaves this box, nothing here can recover it, and
losing it makes the destination unreadable to you as much as to anyone else, so it goes in the
password manager beside the login. And the source box wants paths inside the container, where
this server's /srv is `/source`, while `/source/duplicati` is this app's own state and belongs in
the excludes rather than in the upload.

```bash
sudo ls -lR /srv/duplicati/restore
```

You should see: the file you restored, with a size greater than zero.

If you do not: an empty listing means the restore went somewhere else. Duplicati's restore screen
asks where to put the files, and `/source` cannot be written, which is deliberate: a restore
should never land on top of a running service. Point it at `/restore` and run it again. A backup
nobody has restored is a hope, and that listing is what turns it into a fact.

To restore Duplicati itself: `docker compose down`, `sudo rm -rf /srv/duplicati/data`, recreate
the directories as in step 2, untar the archive back into /srv/duplicati so .env is in place
before anything starts, put the Caddy block back if that was lost, then `docker compose up -d`
and re-run step 7.

## 9. Updating later

Upstream publishes three channels and this install pins stable, the slowest; beta and canary
carry higher version numbers on the same day and are where changes are tried out. Backups are the
wrong place to be early. Stable releases appear at
https://github.com/duplicati/duplicati/releases with a tag ending in `_stable_`, and the matching
image tag on Docker Hub ends in `-stable`. Take the step 8 archive first, then edit the image
line in /srv/duplicati/compose.yml to the new tag and its digest:

```bash
cd /srv/duplicati
docker compose pull
docker compose up -d
docker compose logs --tail 30 duplicati
```

You should see: the new image pulled, the container recreated, and a quiet log.

If you do not: Duplicati migrates its settings database on the way up, and a version step can
also rebuild a job's local file index on its first run after it, which is slow and looks like a
hang. Leave it alone and watch the log until it settles, then re-run step 7's three checks before
calling the update done.

## 10. What will probably go wrong

The page will load and then do nothing. I got the login screen over HTTPS, typed the password,
and watched a spinner turn with no error anywhere on screen; the container was healthy and the
log was quiet. Duplicati checks the Host header on every `/api/` call against an allowed list
that ships holding localhost and nothing else, so the static files came back fine over the public
hostname and every request behind them came back `403`. The tell is your browser's network tab,
not the container log. Check that the hostname in /srv/duplicati/.env matches the site block in
/etc/caddy/Caddyfile exactly, with no scheme and no port, then
`docker compose up -d --force-recreate`.

## 11. Out of scope

- Do not install updates from inside the web UI. The version here is the image tag, and whatever
  an in-place update writes into the container is gone at the next recreate.
- Do not set UID and GID on the container. It runs as root so that it can read files under /srv
  that your other services wrote as other users.
- Do not mount /source read-write for restore in place. Restoring on top of a running service is
  how a bad afternoon becomes a bad week, and /restore exists for this.
- Do not configure SMTP or the upstream reporting console. Both are separate signups.
