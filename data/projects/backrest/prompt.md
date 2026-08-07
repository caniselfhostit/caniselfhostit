You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Backrest 1.14.1 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things to the user first. Backrest is a web UI and a scheduler over restic: it backs up
the files on the machine it runs on, so here that is /srv, the data every other service on this
box keeps, and not their laptop. And it needs somewhere to send the snapshots, a bucket or a box
that still costs money. What stops is the per-computer software fee, not the storage bill.

Backrest needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve. The 5 GB is the image plus restic's cache, which
grows with the repository index, not with the data copied.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/backrest /srv/backrest/backups
sudo install -d -m 700 -o $(id -u) -g $(id -g) /srv/backrest/config
sudo install -d -m 700 /srv/backrest/data /srv/backrest/cache /srv/backrest/restore
ls -la /srv/backrest
```

Assert: `ls -la` shows five directories, with `config` and `backups` owned by the login user and
`data`, `cache` and `restore` at mode `700` owned by root. The container runs as root, because
the files it reads under /srv were written by other services as other users. `config` is the
login user's because step 3 writes into it first.

## 3. Secrets

One secret: the password for the web login. Generate it on the server, do not print it, do not
repeat it in your summary, and keep it out of every log line. Hex rather than base64, because a
human types this one into a form.

The rest of this step is the security decision here. A Backrest that starts without a
configuration file writes itself a default one with authentication disabled, then serves every
API route to whoever asks. Writing the file first means there is never a minute where that is
true on a public hostname.

```bash
umask 077
cat > /srv/backrest/.env <<EOF
BACKREST_USERNAME=admin
BACKREST_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/backrest/.env
cat > /srv/backrest/config/config.json <<'EOF'
{
  "version": 6,
  "instance": "<DOMAIN>",
  "auth": {"disabled": false, "users": [{"name": "admin", "passwordBcrypt": "PLACEHOLDER"}]}
}
EOF
grep BACKREST_PASSWORD /srv/backrest/.env | cut -d= -f2- | caddy hash-password | base64 | tr -d '\n' > /srv/backrest/config/hash.tmp
awk 'NR==FNR{h=$0;next} {sub(/PLACEHOLDER/,h);print}' /srv/backrest/config/hash.tmp /srv/backrest/config/config.json > /srv/backrest/config/config.tmp
mv /srv/backrest/config/config.tmp /srv/backrest/config/config.json && rm /srv/backrest/config/hash.tmp
chmod 600 /srv/backrest/config/config.json
umask 022
ls -l /srv/backrest/.env /srv/backrest/config/config.json
grep -q PLACEHOLDER /srv/backrest/config/config.json && echo "substitution failed" || echo "hash in place"
```

Replace `<DOMAIN>` in that block with the real hostname before running it. Assert: both files
exist at mode `-rw-------`, and the last line prints `hash in place`. Three upstream facts hold
it together. A password is stored as a bcrypt hash that is then base64 encoded, which is what
`caddy hash-password` piped into `base64` produces. `version` is required: a file with content
and no version number is rejected at start-up, and 6 is this release's migration count.
`instance` names this install inside every snapshot and cannot be changed later.

Tell the user their password is in /srv/backrest/.env, readable with
`sudo grep BACKREST_PASSWORD /srv/backrest/.env`, and that it goes in their password manager now.
Do not print it.

## 4. compose.yml

```bash
cat > /srv/backrest/compose.yml <<'EOF'
# Backrest · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   readme and docker ... https://github.com/garethgeorge/backrest/blob/v1.14.1/README.md
#   getting started ..... https://garethgeorge.github.io/backrest/introduction/getting-started
#   entrypoint defaults . https://github.com/garethgeorge/backrest/blob/v1.14.1/cmd/docker-entrypoint/main.go
#
# One service. Backrest is a web UI and a scheduler over restic, and the image
# ships the restic it was built against at /bin/restic, so nothing is fetched
# at start-up. It runs as root because the files it reads under /srv were
# written by other services as other users. /userdata is /srv, read-only, so a
# restore cannot go home; that is what the writable /restore is for.
#
# Tag and digest read from ghcr.io on 2026-08-06; the image publishes amd64,
# arm64, arm/v6, arm/v7 and 386.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  backrest:
    image: ghcr.io/garethgeorge/backrest:v1.14.1@sha256:b852979754281026230cc69fb11428e6d57c9a97784ab4a444ffc7934c53a215
    container_name: backrest
    restart: unless-stopped
    environment:
      BACKREST_PORT: "0.0.0.0:9898"
      BACKREST_CONFIG: /config/config.json
      BACKREST_DATA: /data
      XDG_CACHE_HOME: /cache
      BACKREST_RESTIC_COMMAND: /bin/restic
      TZ: UTC
    volumes:
      # Repository URIs, schedules and the login hash, written in step 3.
      - /srv/backrest/config:/config
      # oplog.sqlite, the JWT signing secret, the per-task logs.
      - /srv/backrest/data:/data
      # restic's cache: rebuildable, and it grows with the repository index.
      - /srv/backrest/cache:/cache
      - /srv/backrest/restore:/restore
      # The data this server holds: everything in this catalogue lives in /srv.
      - /srv:/userdata:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8136.
      - "127.0.0.1:8136:9898"
EOF
cd /srv/backrest && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no database: the history is a
SQLite file under /srv/backrest/data, the settings the file step 3 wrote.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-backrest
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Backrest · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://garethgeorge.github.io/backrest/cookbooks/reverse-proxy-examples and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream's own
# example is one reverse_proxy line to 9898; the headers are ours.

<DOMAIN> {
	# Caddy's default encode matcher covers text, JSON, JavaScript and SVG
	# only, so a file downloaded from a snapshot passes through untouched.
	encode zstd gzip

	# Backrest sets no transport or frame headers of its own. HSTS is on
	# because every request here carries the token that reads this server.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8136 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8136
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-backrest, reload, and report what it objected to. Caddy asks for the
certificate on the first request and renews it alone.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8136 stays closed because compose binds it to 127.0.0.1. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8136 or 9898.

## 7. Start and verify

```bash
cd /srv/backrest
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/ | grep -o '<title>Backrest</title>'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/v1.Backrest/GetOperations -H 'Content-Type: application/json' -d '{}'
printf 'user = "admin:%s"\n' "$(sudo grep BACKREST_PASSWORD /srv/backrest/.env | cut -d= -f2-)" | curl -sS -o /dev/null -w '%{http_code}\n' -K - -X POST https://<DOMAIN>/v1.Backrest/GetOperations -H 'Content-Type: application/json' -d '{}'
```

Assert all four, and print what you received for each. The loop ends printing `200`. The second
prints `<title>Backrest</title>`. The third prints `401`, the security assert in this block: an
unauthenticated API call is refused, so step 3 took effect. The fourth prints `200`, proving the
generated password matches the hash in that file; it reads the password from a curl config on
standard input, so the value never reaches a command line or the terminal. If any of the four
misses, stop, run `docker compose logs --tail 40 backrest`, and name the likely earlier step: a
container that exits in seconds is step 3, a `200` where a `401` belongs means the configuration
file was not read, and a `401` on the fourth means the hash and the password disagree. A running
container is not success.

STOP: tell the user to read their password with
`sudo grep BACKREST_PASSWORD /srv/backrest/.env`, put it in their password manager, open
https://<DOMAIN>, and log in as `admin`. Wait. Do not continue until they confirm. The first
screen is a box headed `Login`, with `Username` and `Password` fields and a `Log in` button.

## 8. First backup and restore

Two backups here, and they are not the same thing. First this install's own configuration, the
archive below. Then the user's first snapshot, what they installed this for, which only they can
set up.

```bash
cd /srv/backrest
docker compose stop
sudo tar -czf /srv/backrest/backups/backrest-config-$(date +%F).tar.gz -C /srv/backrest config data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/backrest/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped on purpose,
because a SQLite history copied mid-write is not a backup, and it costs five seconds. The archive
holds every repository password the user is about to type, so it is as sensitive as what it
describes.

A backup on the same disk as the data is not a backup. Run this from the user's machine, not the
server:

```bash
mkdir -p ~/backups/backrest
scp vps:/srv/backrest/backups/*.tar.gz ~/backups/backrest/
```

STOP: tell the user to open https://<DOMAIN>, click `Add Repo` and set up the storage their
snapshots go to, then `Add Plan` with paths under `/userdata`, then run that plan once and
restore one file from the resulting snapshot into `/restore`. Wait.
Do not continue until they confirm. Three things to tell them while they do it. The
repository password they type is a
restic encryption password: lose it and every snapshot is unreadable, by them too, so it goes in
the password manager beside the login. The paths box wants paths inside the container, where
this server's /srv is `/userdata`, and `/userdata/backrest` belongs in the excludes because it
is this app's own cache. And the storage is a bill from somebody: a B2 or S3 bucket, an SFTP
account, or a disk in a friend's house.

```bash
sudo ls -lR /srv/backrest/restore
```

Assert: the restored file is there and non-empty. Print the listing. A backup nobody has restored
is a hope, and that command turns it into a fact. To restore Backrest itself: `docker compose
down`, `sudo rm -rf /srv/backrest/config /srv/backrest/data`, recreate the directories as in step
2, untar the archive back into /srv/backrest, put the Caddy block back if that was lost, then
`docker compose up -d`.

## 9. Updating later

New versions are listed at https://github.com/garethgeorge/backrest/releases. Take the step 8
archive first, then edit the image line in /srv/backrest/compose.yml to the new tag and digest:

```bash
cd /srv/backrest
docker compose pull
docker compose up -d
docker compose logs --tail 30 backrest
```

Backrest migrates its configuration file forward and rewrites it in place, so watch that log
until it settles, then re-run step 7's four checks before calling the update done.

## 10. What will probably go wrong

The paths. I typed `/srv/shlink` into the plan's path box, got an error, retyped it, and spent
several minutes convinced the read-only mount was broken. It was not: the box wants a path inside
the container, and this server's /srv is `/userdata` in there, so the answer was
`/userdata/shlink`. The autocomplete in that field is the tell, because it offers only paths the
container can see. If the first backup finishes in one second and stores nothing, that is the
same mistake wearing a different hat.

## 11. Out of scope

- Do not disable authentication and do not add a second user. This host answers on the public
  internet, and one account with a generated password is the access model.
- Do not configure command hooks. They run in this container as root with /srv mounted.
- Do not configure an rclone remote in the container. The image ships rclone, but its config
  directory is not mounted, so the remote dies with the next recreate.
- Do not set up multihost sync. It pairs this instance with another Backrest somewhere else,
  which this install does not have.
