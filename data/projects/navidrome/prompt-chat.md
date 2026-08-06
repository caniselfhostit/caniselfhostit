This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Navidrome 0.63.2 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. Navidrome streams audio files that are already on that server. It has
no catalog, no store and no search across anything you have not copied onto the disk yourself.
Step 7 is where you copy your library up, and how long that takes is a question about your
upload speed, not about this install.

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
resolve, and failed attempts count against a rate limit you cannot see. The 5 G floor covers
the image, the database and the artwork and transcoding caches only. Your music sits on top of
that number, so check your library size now with `du -sh` on your own machine and make sure the
server has room for it before you go any further.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/navidrome
sudo install -d -m 750 -o 1000 -g 1000 /srv/navidrome/data /srv/navidrome/backups
sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/navidrome/music
ls -la /srv/navidrome
```

You should see: `data` and `backups` at mode `drwxr-x---` owned by uid `1000`, and `music` at
mode `drwxr-xr-x` owned by you.

If you do not: on most VPS images your login user is already uid 1000, so all three read as your
own name and nothing is wrong. The container runs as uid 1000 and writes only to `data` and
`backups`. `music` stays yours so you can copy files into it in step 7, and it is
world-readable so the container can read your library without owning it.

## 3. Secrets

One secret: the passphrase Navidrome uses to encrypt the passwords it stores. It is generated
here, on the server, and goes straight into a file only you can read.

```bash
umask 077
cat > /srv/navidrome/.env <<EOF
ND_PASSWORDENCRYPTIONKEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/navidrome/.env
umask 022
ls -l /srv/navidrome/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/navidrome/.env` and
carry on. Hex rather than base64 because Docker Compose reads this same file for variable
interpolation, and a `$` in the value would be expanded into something else.

Read the key once with `sudo grep ND_PASSWORDENCRYPTIONKEY /srv/navidrome/.env` and put it in
your password manager. Upstream is explicit that this value is written once: setting it
re-encrypts every stored password, and changing it afterwards locks every account out of the
server permanently. Do not paste that file, that value, or any command output containing it
into this chat window.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/navidrome/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/navidrome/compose.yml` and paste again in one go. A warning about a variable that
is not set means your `.env` value picked up a `$`, which the hex generator in step 3 cannot
produce, so regenerate it rather than editing it by hand.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-navidrome /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you forgot to replace, and Caddy
names the line it choked on. Caddy asks for the certificate the first time somebody requests
that hostname and renews it on its own, so there is nothing to schedule afterwards.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8108` or `4533`.

If you do not: delete anything for `8108` with `sudo ufw delete allow 8108`. That port is bound
to 127.0.0.1 by the compose file, so Caddy reaches it and nothing on the internet can. 80/tcp
redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp is
HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero
left this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it
back before you go any further.

## 7. Start and verify

```bash
cd /srv/navidrome
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/ping; echo
curl -sS https://<DOMAIN>/app/ | tr -d '\\' | grep -o '"firstTime":[a-z]*'
```

You should see, in order: the loop reaching `200`, a single `.` on a line of its own, then
`"firstTime":true`.

If you do not: a loop that never reaches 200 wants `docker compose logs --tail 40 navidrome`. A
container that exits within seconds is almost always step 2, where `data` ended up owned by
somebody other than uid 1000. A `502` from Caddy while `docker compose ps` shows the container
healthy is step 5 instead. The single `.` is what the health endpoint returns, and it looks
like nothing on a terminal, so read it carefully rather than assuming the command printed no
output.

`"firstTime":true` means no account exists yet, and it also means the next person to load that
URL becomes the administrator of your music server. Close that window now, before you go
looking for your music.

Open https://<DOMAIN> in a browser. The first screen reads `Thanks for installing Navidrome!`
above `To start, create an admin user`, with Username, Password and Confirm Password boxes and
a `Create Admin` button. Fill it in and submit, then come back here and run:

```bash
curl -sS https://<DOMAIN>/app/ | tr -d '\\' | grep -o '"firstTime":[a-z]*'
```

You should see: `"firstTime":false`.

If you do not: the account was not created, and the registration screen is still open to
whoever finds it. Do not carry on until this prints `false`. This is the security check in this
step, not a formality.

Now the library. Run this one on your own machine, not the server, with your own music path on
the left:

```bash
rsync -av --info=progress2 ~/Music/ vps:/srv/navidrome/music/
```

You should see: a file count and a transfer rate, then a summary line. One album is enough to
carry on; the rest can follow whenever you like, and Navidrome picks up new files about five
seconds after they stop changing.

Then, back on the server:

```bash
cd /srv/navidrome
docker compose exec -T navidrome sqlite3 /data/navidrome.db "select count(*) from media_file"
```

You should see: a number greater than 0.

If you do not: a `0` usually means the files are there but the container cannot read them. Run
`sudo chmod -R a+rX /srv/navidrome/music`, wait thirty seconds and count again. If it is still
`0`, check that the files actually landed with `ls /srv/navidrome/music`. On a large library a
scan still working is the other explanation: upstream's own timing table puts 10,000 songs at
one to five minutes and 50,000 at fifteen or more, so count twice before you change anything. A
running container is not success. The two numbers that mean success are `"firstTime":false` and
a song count above zero.

## 8. First backup and restore

One archive: the database, the encryption key, the compose file and the Caddy site block. Your
music is not in it, on purpose. It is tens of gigabytes you already own, and it belongs in
whatever backup protects your own machine.

```bash
cd /srv/navidrome
docker compose stop
sudo tar -czf /srv/navidrome/backups/navidrome-config-$(date +%F).tar.gz -C /srv/navidrome data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/navidrome/backups/
```

You should see: one `.tar.gz`, a few hundred kilobytes on a fresh install. Navidrome is offline
for about five seconds while the archive is made.

If you do not: an archive of a few hundred bytes means `tar` found nothing under `data`, which
means the container never wrote its database, which sends you back to step 7. The container is
stopped on purpose: a SQLite database copied while it is being written is not a backup, and the
copy will look fine until the day you need it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/navidrome
scp vps:/srv/navidrome/backups/*.tar.gz ~/backups/navidrome/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/navidrome/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one account and a scan you can
run again:

```bash
cd /srv/navidrome
docker compose down
sudo rm -rf /srv/navidrome/data
sudo install -d -m 750 -o 1000 -g 1000 /srv/navidrome/data
sudo tar -xzf /srv/navidrome/backups/navidrome-config-$(date +%F).tar.gz -C /srv/navidrome data .env compose.yml
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/app/ | tr -d '\\' | grep -o '"firstTime":[a-z]*'
```

You should see: `"firstTime":false`, which means your account survived a data directory that was
deleted and rebuilt from the archive.

If you do not: `"firstTime":true` means the database did not come back and Navidrome created an
empty one, so check the archive listing with `tar -tzf` before you trust it with anything. The
stakes are worth stating plainly: your accounts, play counts, playlists and ratings live in
`data/navidrome.db`, and the key that decrypts the passwords lives in `.env`. Restore one
without the other and everybody is locked out. Those two files travel together. The nightly job
the compose file configures writes a database-only snapshot into the same backups folder at
04:00 and keeps seven of them, which covers a bad delete and does nothing at all about a dead
disk.

## 9. Updating later

New versions are listed at https://github.com/navidrome/navidrome/releases. Take the backup
first, then edit the `image:` line in /srv/navidrome/compose.yml to the new tag and its digest.

```bash
cd /srv/navidrome
docker compose pull
docker compose up -d
docker compose logs --tail 30 navidrome
```

You should see: migration lines, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
`/ping` check from step 7 before you call the update done, and open the web player and start
one track as well, because a server that answers `/ping` can still be failing to stream if a
migration stopped halfway.

## 10. What will probably go wrong

The gap between `docker compose up -d` and you creating your account is the one genuinely
dangerous minute in this install. I left it open while I went to find my music folder, and for
those four minutes the first stranger to load that hostname would have been handed the
administrator account, because that is what the create-admin screen does and there is no
invitation code in front of it. Nothing bad happened to me, and nothing about a fresh DNS
record is as quiet as it feels. Create the account first, check that `"firstTime":false`, then
go looking for the music.

## 11. Out of scope

- Do not set `ND_ENABLETRANSCODINGCONFIG` to true. It opens a UI screen that edits the
  transcoding command line, which is command execution on this server wearing a settings page.
- Do not configure Last.fm, ListenBrainz or Deezer credentials. Scrobbling and artist images
  need accounts elsewhere, and you can add them later from the UI.
- Do not enable Jukebox mode. It plays audio on the server's own sound card, which a VPS does
  not have.
- Do not configure SMTP. Navidrome sends no mail, so there is nothing for it to do.
