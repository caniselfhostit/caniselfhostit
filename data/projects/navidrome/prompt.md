You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Navidrome 0.63.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Tell the user one thing before anything installs, because it decides whether they want this at
all: Navidrome streams audio files that are already on this server. It has no catalog, no
store, and nothing to search that they have not copied onto the disk themselves. Step 7 asks
them for that library.

Navidrome needs 512 MB of RAM available and 5 GB free on /srv before any music. The image
publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve. The 5 GB covers the image, the database and the
artwork and transcoding caches. The music library is on top of it, and only the user knows how
big that is.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/navidrome
sudo install -d -m 750 -o 1000 -g 1000 /srv/navidrome/data /srv/navidrome/backups
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/navidrome/music
ls -la /srv/navidrome
```

Assert: `ls -la` shows four entries, with `data` and `backups` owned by uid `1000` at mode
`750`, and `music` owned by the login user at mode `755`. The container runs as uid 1000 and
writes only to the first two. `music` stays the login user's so they can copy files into it in
step 7, and it is world-readable so uid 1000 can read it without owning it. On most VPS images
the login user is already uid 1000 and all four names look the same.

## 3. Secrets

One secret: the passphrase Navidrome uses to encrypt stored passwords. Generate it on the
server. Do not print it, do not repeat it in your summary, and do not put it in any log line.

```bash
umask 077
cat > /srv/navidrome/.env <<EOF
ND_PASSWORDENCRYPTIONKEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/navidrome/.env
umask 022
ls -l /srv/navidrome/.env
```

Assert: the file exists with mode `-rw-------`. Hex rather than base64 because Docker Compose
reads this same file for variable interpolation and a `$` in the value would be expanded.
Upstream is explicit that this key is written once: setting it re-encrypts every stored
password, and changing it afterwards locks every account out of the server for good. Tell the
user it lives in /srv/navidrome/.env, that they can read it with
`sudo grep ND_PASSWORDENCRYPTIONKEY /srv/navidrome/.env`, and that it belongs in their password
manager next to the account they are about to create.

## 4. compose.yml

```bash
cat > /srv/navidrome/compose.yml <<'EOF'
# Navidrome · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ...... https://www.navidrome.org/docs/installation/docker/
#   config options ...... https://www.navidrome.org/docs/usage/configuration/options/
#   security ............ https://www.navidrome.org/docs/usage/admin/security/
#   automated backup .... https://www.navidrome.org/docs/usage/admin/backup/
#
# One service. Navidrome keeps its whole state in a SQLite database under /data
# and never writes to the music library, so the library is mounted read-only,
# which is what upstream asks for. The container runs as uid 1000, not root,
# and ND_ENFORCENONROOTUSER makes it exit rather than start as root by
# accident; read_only plus a tmpfs for /tmp follows upstream's own
# contrib/docker-compose sample. Tag and digest read from Docker Hub on
# 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  navidrome:
    image: deluan/navidrome:0.63.2@sha256:9012939114fbb1bb641b81cf96dec5ded15f0aafefe8d47a511d7cb919658e40
    container_name: navidrome
    restart: unless-stopped
    # The uid and gid owning /srv/navidrome/data and /srv/navidrome/backups.
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp
    env_file: /srv/navidrome/.env
    environment:
      ND_MUSICFOLDER: /music
      ND_DATAFOLDER: /data
      ND_PORT: "4533"
      # Refuse to start as root on a Unix host.
      ND_ENFORCENONROOTUSER: "true"
      # Upstream disables the transcoding-config UI by default: it edits a
      # command line that this server then runs. Leave it off.
      ND_ENABLETRANSCODINGCONFIG: "false"
      # No anonymous usage reports leave this box.
      ND_ENABLEINSIGHTSCOLLECTOR: "false"
      # Nightly database snapshot at 04:00, seven kept. No music in it.
      ND_BACKUP_PATH: /backups
      ND_BACKUP_SCHEDULE: "0 4 * * *"
      ND_BACKUP_COUNT: "7"
    volumes:
      - /srv/navidrome/data:/data
      - /srv/navidrome/backups:/backups
      # Read-only. Nothing Navidrome does needs write access to your library.
      - /srv/navidrome/music:/music:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8108.
      - "127.0.0.1:8108:4533"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:4533/ping"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s
EOF
cd /srv/navidrome && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, one database file. Nothing
here reaches the internet on its own.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-navidrome
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Navidrome · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.navidrome.org/docs/usage/admin/security/,
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream ships an
# HTTP server inside Navidrome and still asks you to put a reverse proxy in
# front of it that terminates TLS. This is that proxy.

<DOMAIN> {
	# The UI bundle and the JSON API compress well. Audio does not, and Caddy's
	# default encode matcher covers text, JSON, JavaScript and SVG only, so the
	# audio streams pass through untouched.
	encode zstd gzip

	# Navidrome sets its own X-Frame-Options: DENY, so this block does not
	# repeat it. HSTS is here because every request to this host carries a
	# session cookie or a Subsonic credential.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8108 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. Server-sent events on
	# /api/events need no extra configuration: Caddy flushes text/event-stream
	# responses immediately whatever flush_interval says.
	reverse_proxy 127.0.0.1:8108
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-navidrome, reload, and report what it objected to. Caddy requests
the certificate on the first request to the hostname and renews it on its own, so there is
nothing to schedule.

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
443/udp is HTTP/3. 8108 stays closed because compose binds it to 127.0.0.1 and Caddy is the
only thing that speaks to it. Assert: `ufw status verbose` prints `Status: active`, shows 80,
443/tcp and 443/udp, and no rule mentioning 8108 or 4533.

## 7. Start and verify

```bash
cd /srv/navidrome
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/ping; echo
curl -sS https://<DOMAIN>/app/ | tr -d '\\' | grep -o '"firstTime":[a-z]*'
```

Assert all three, and print what you received for each: the loop ends printing `200`; the
health endpoint answers with a single `.`; and the last line prints `"firstTime":true`, which
means no account exists yet. If the loop never reaches 200, stop, run
`docker compose logs --tail 40 navidrome`, and say which earlier step is the likely cause: a
container that exits immediately usually means step 2 left `data` owned by somebody other than
uid 1000, and a 502 from Caddy with a healthy container means step 5. A running container is
not success.

`"firstTime":true` also means the next person to load that URL becomes the administrator, so
close that window now rather than after the music arrives.

STOP: tell the user to open https://<DOMAIN> and create their account, and wait. Do not
continue until they confirm. The first screen reads `Thanks for installing Navidrome!` above
`To start, create an admin user`, with Username, Password and Confirm Password boxes and a
`Create Admin` button.

```bash
curl -sS https://<DOMAIN>/app/ | tr -d '\\' | grep -o '"firstTime":[a-z]*'
```

Assert: `"firstTime":false`. That is the registration window closed, and it is the security
assert in this block. If it still prints `true`, the account was not created; do not go on.

STOP: tell the user to copy at least one album into /srv/navidrome/music, from their own
machine, not the server, and wait. Do not continue until they confirm. This is the command,
with their own path on the left:

```bash
rsync -av --info=progress2 ~/Music/ vps:/srv/navidrome/music/
```

The rest of the library can follow at any time. Navidrome watches the folder and picks up new
files about five seconds after they stop changing. Once they confirm, count what it found:

```bash
sleep 30
docker compose exec -T navidrome sqlite3 /data/navidrome.db "select count(*) from media_file"
```

Assert: a number greater than 0. Print it. A 0 means either the scan is still working or the
files are unreadable by uid 1000: run `sudo chmod -R a+rX /srv/navidrome/music`, wait 30
seconds, and count again. Upstream's own timing table puts 10,000 songs at one to five minutes,
so on a large library count twice before deciding anything is wrong.

## 8. First backup and restore

One archive: the database, the encryption key, the compose file and the Caddy site block. The
music is not in it, and that is deliberate: it is tens of gigabytes the user already owns, and
it belongs in whatever backup already protects their own machine.

```bash
cd /srv/navidrome
docker compose stop
sudo tar -czf /srv/navidrome/backups/navidrome-config-$(date +%F).tar.gz -C /srv/navidrome data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/navidrome/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds,
and the container is stopped on purpose because a SQLite database copied mid-write is not a
backup. The nightly job compose already configured writes a database-only snapshot into the
same folder at 04:00 and keeps seven, which covers a bad delete but not a dead disk.

A backup on the same disk as the data is not a backup. Run this one from the user's machine,
not the server:

```bash
mkdir -p ~/backups/navidrome
scp vps:/srv/navidrome/backups/*.tar.gz ~/backups/navidrome/
```

To restore: `docker compose down`, `sudo rm -rf /srv/navidrome/data`, recreate it as in step 2,
untar the archive back into /srv/navidrome, put the Caddy block back if that is what was lost,
then `docker compose up -d`. The accounts, play counts, playlists and ratings are in
`data/navidrome.db`; the key that decrypts the passwords is in `.env`, and restoring the
database without it locks everyone out. Tell the user those two files travel together or not at
all.

## 9. Updating later

New versions are listed at https://github.com/navidrome/navidrome/releases. Take the backup
first, then edit the image line in /srv/navidrome/compose.yml to the new tag and its digest:

```bash
cd /srv/navidrome
docker compose pull
docker compose up -d
docker compose logs --tail 30 navidrome
```

Navidrome migrates its own database on the way up. Watch that log until it settles, then re-run
the `/ping` check from step 7 before calling the update done.

## 10. What will probably go wrong

The gap between `docker compose up -d` and the user creating their account is the one genuinely
dangerous minute in this install. I left it open while I went to find my music folder, and for
those four minutes the first stranger to load that hostname would have been handed the
administrator account, because that is what the create-admin screen does and there is no
invitation code in front of it. Nothing bad happened to me, and nothing about a fresh DNS
record is as quiet as it feels. Create the account first, assert `"firstTime":false`, then go
looking for the music.

## 11. Out of scope

- Do not set `ND_ENABLETRANSCODINGCONFIG` to true. It opens a UI screen that edits the
  transcoding command line, which is command execution on this server wearing a settings page.
- Do not configure Last.fm, ListenBrainz or Deezer credentials. Scrobbling and artist images
  need accounts elsewhere, and the user can add them later from the UI.
- Do not enable Jukebox mode. It plays audio on the server's own sound card, which a VPS does
  not have.
- Do not configure SMTP. Navidrome sends no mail, so there is nothing for it to do.
