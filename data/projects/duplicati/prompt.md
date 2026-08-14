You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Duplicati 2.3.0.4 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things to the user first. Duplicati is a backup client, not a place to put backups: it
encrypts files on the machine it runs on and uploads them to a destination the user supplies, so
what stops is a subscription and what starts is a storage bill. And the machine here is this
server, meaning /srv and what this catalogue keeps in it, not a laptop.

Duplicati needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64, arm64
and arm/v7. Measure all four.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve. The 5 GB covers the image, the temporary volumes
built while uploading, and a per-job database that grows with the file count.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/duplicati /srv/duplicati/backups
sudo install -d -m 700 /srv/duplicati/data /srv/duplicati/restore
ls -la /srv/duplicati
```

Assert: `ls -la` shows `backups` owned by the login user, and `data` and `restore` at mode `700`
owned by root. The container runs as root, because no UID and GID pair is set for it and the
files it reads under /srv were written by other services. `data` holds Duplicati's own settings
database, a different thing from the backups it makes.

## 3. Secrets

Two secrets, generated here on the server. Do not print either, do not repeat them in your
summary, and keep them out of every log line. Hex, because a human types one of them into a
form.

The security decision is the first line. Duplicati always has a web password: set none and it
generates a random one at first start, then writes a one-time sign-in link into the container
log, a credential sitting in `docker compose logs` on a public hostname. Setting the password
first replaces that with a value the user owns. `SETTINGS_ENCRYPTION_KEY` is the one variable
here with no `DUPLICATI__` prefix; it encrypts the credential fields in the settings database,
where the destination's access keys are about to live. The third line is not optional either: the
allowed-hostname list ships holding localhost, 127.0.0.1 and bare IPs, so a Duplicati behind a
real hostname refuses its own front end until that name is on it.

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

Replace `<DOMAIN>` in that block with the real hostname before running it. Assert: the file is at
mode `-rw-------`, and the last command prints the real hostname, bare, with no scheme, no port
and no angle brackets. If it still shows the placeholder, stop and fix it: the API answers 403 to
everything through Caddy until it is right. Tell the user the web password is readable with
`sudo grep DUPLICATI__WEBSERVICE_PASSWORD /srv/duplicati/.env` and that both values go in their
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

Assert: that prints `compose OK`. One service, one port, no database container: the settings and
the file indexes are SQLite files in /srv/duplicati/data.

## 5. Caddy and TLS

Write the site block to its own file, then append it with the hostname substituted. Copy the
live Caddyfile first: a syntax error takes down every other site here.

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

Assert: the echo prints the real hostname, `caddy validate` exits 0, the reload exits 0. The
substitution reads the hostname out of .env rather than asking again, so the site block and the
allowed-hostnames value cannot disagree. If validate fails, restore
/etc/caddy/Caddyfile.before-duplicati, reload, and say what it objected to. Caddy gets the
certificate on the first request and renews it alone.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8188 stays closed because compose binds it to 127.0.0.1. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8188.

## 7. Start and verify

```bash
cd /srv/duplicati
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/backups
printf '{"Password":"%s","RememberMe":false}' "$(sudo grep DUPLICATI__WEBSERVICE_PASSWORD /srv/duplicati/.env | cut -d= -f2-)" | curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @-
```

Assert all four, and print what you received for each. The loop ends printing `200`. The second
prints `Healthy`. The third prints `401`, the security assert here: the API refuses a call
carrying no token, so nobody who finds the hostname can read or edit a backup job. The fourth
prints `200`, proving both that the generated password is the one the server holds and that the
allowed-hostnames value took effect, since that route rejects an unknown Host with `403` first.
The password reaches curl on standard input, never a command line.

If any of the four misses, stop, run `docker compose logs --tail 40 duplicati`, and name the
likely earlier step. A `403` on the fourth is step 3 or 5, the hostname disagreeing. A `401`
there means .env holds a password the container did not start with, which happens if it ran
before .env existed: `docker compose down`, then `up -d`. A running container is not success.

STOP: tell the user to read their password with
`sudo grep DUPLICATI__WEBSERVICE_PASSWORD /srv/duplicati/.env`, put it in their password manager,
open https://<DOMAIN>, and sign in. Do not continue until they confirm. The first screen is one
`Password` box: Duplicati has no usernames and no second account.

## 8. First backup and restore

Two different backups live in this step. The archive below backs up Duplicati itself, the
settings database that knows what to copy and where to send it. The user's own first backup job
is the second half.

```bash
cd /srv/duplicati
docker compose stop
sudo tar -czf /srv/duplicati/backups/duplicati-config-$(date +%F).tar.gz -C /srv/duplicati data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/duplicati/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped on purpose,
because a SQLite database copied mid-write is not a backup. The archive holds .env, so it holds
the key protecting everything else in it.

A backup on the same disk is not a backup. Run this on the user's machine:

```bash
mkdir -p ~/backups/duplicati
scp vps:/srv/duplicati/backups/*.tar.gz ~/backups/duplicati/
```

STOP: tell the user to open https://<DOMAIN>, choose `Add backup`, set a passphrase, pick a
destination, add `/source` as the source folder with `/source/duplicati` excluded, run the job
once, then restore one file from it into `/restore`. Do not continue until they confirm. Two
things to tell them while they do it. The passphrase encrypts every file before it leaves this
box, nothing here can recover it, and losing it makes the destination unreadable to them as much
as to anyone else. And the source box wants paths inside the container, where /srv is `/source`,
while the destination is a bill from somebody: a bucket, an SFTP account, or a disk in a friend's
house.

```bash
sudo ls -lR /srv/duplicati/restore
```

Assert: the restored file is there and non-empty. Print the listing. A backup nobody has restored
is a hope, and that turns it into a fact. To restore Duplicati itself: `docker compose down`,
`sudo rm -rf /srv/duplicati/data`, recreate it as in step 2, untar the archive back into
/srv/duplicati so .env is in place before anything starts, restore the Caddy block if it was
lost, then `docker compose up -d` and re-run step 7's checks.

## 9. Updating later

Upstream publishes three channels and this install pins stable, the slowest; beta and canary
carry higher version numbers on the same day and are where changes are tried out. Backups are the
wrong place to be early. Stable releases appear at
https://github.com/duplicati/duplicati/releases with a tag ending in `_stable_`, and the image
tag ends in `-stable`. Take the step 8 archive first, then edit the image line in compose.yml:

```bash
cd /srv/duplicati
docker compose pull
docker compose up -d
docker compose logs --tail 30 duplicati
```

Duplicati migrates its settings database on the way up, and a version step can also rebuild a
job's file index on its first run, which is slow and looks like a hang. Watch the log until it
settles, then re-run step 7's checks before calling the update done.

## 10. What will probably go wrong

The page loads and then does nothing. I got the login screen over HTTPS, typed the password, and
watched a spinner turn with no error on screen; the container was healthy and the log was quiet.
Duplicati checks the Host header on every `/api/` call against a list that ships holding
localhost and nothing else, so the static files came back fine over the public hostname and every
request behind them came back `403`. The tell is the browser's network tab, not the log. Check
that the hostname in /srv/duplicati/.env matches the site block in /etc/caddy/Caddyfile, then
`docker compose up -d --force-recreate`.

## 11. Out of scope

- Do not install updates from inside the web UI. The version here is the image tag, and whatever
  an in-place update writes into the container is gone at the next recreate.
- Do not set UID and GID on the container. It runs as root so it can read files under /srv that
  other services wrote as other users.
- Do not mount /source read-write for restore in place. Restoring on top of a running service is
  how a bad afternoon becomes a bad week; /restore exists for this.
- Do not configure SMTP or the upstream reporting console. Both are separate signups.
