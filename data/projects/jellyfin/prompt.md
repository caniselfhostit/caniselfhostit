You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Jellyfin 10.10.7 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say three things before anything installs, because they decide whether this is the right box.
One: Jellyfin streams files the user already owns. There is no catalogue, no store, and nothing
to search that they have not copied onto a disk. Two: a home box with the library on the same
LAN is the usual shape; a VPS is a remote front door, and every remote stream burns that
provider's egress quota the way a Netflix bill would. Three: between first start and the end of
the setup wizard, anyone who can reach the hostname may finish setup first and become the
administrator.

Jellyfin needs 2048 MB of RAM available and 20 GB free on /srv before any media. The image
publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a hostname that does not resolve. The 20 GB covers the image, config, cache and a small library
staging area; a real movie collection lives on storage the user already has and is not counted
here.

## 2. Layout

Config and cache are what Jellyfin writes. Media is a path the user already owns, mounted read
only, not an empty directory this install invents and never fills.

STOP: ask the user for the absolute path on this server to a media library they already have
(or will fill themselves), for example `/mnt/media` or `/home/them/videos`. Do not continue until they confirm. If they have no library yet, they may give `/srv/jellyfin/media` and you
will create that empty directory, with the understanding that playback stays empty until they
copy files in.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/jellyfin /srv/jellyfin/backups /srv/jellyfin/config /srv/jellyfin/cache
# If the user chose /srv/jellyfin/media as the library path, create it owned by them:
# sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/jellyfin/media
ls -la /srv/jellyfin
test -d "<MEDIA_PATH>" && ls -ld "<MEDIA_PATH>"
```

Replace `<MEDIA_PATH>` with the path they gave. Assert: config, cache and backups exist and are
owned by the login user. The media path exists as a directory (create it only if they chose
`/srv/jellyfin/media`). If the media path is owned by root and unreadable by other users, fix
ownership or mode so the container can read it: `sudo chmod -R a+rX <MEDIA_PATH>` is enough
when the image runs as root (the default when no `user:` line is set). Do not leave a
root-owned empty `media/` that nothing ever mounts from their real library.

Write the path into `.env` so compose can interpolate it. This is not a secret:

```bash
umask 077
printf 'JELLYFIN_MEDIA_PATH=%s\n' '<MEDIA_PATH>' > /srv/jellyfin/.env
chmod 600 /srv/jellyfin/.env
umask 022
ls -la /srv/jellyfin/.env
cat /srv/jellyfin/.env
```

Assert: `.env` is mode 600 and prints one line with the path they chose, not a placeholder.

## 3. Secrets

No secret is generated for this install and there is no application password in `.env`. The
first credential is the administrator account the user creates in the setup wizard in step 7.
Between the container starting and that account existing, anyone who can reach the hostname may
finish the wizard first. Step 7 is a hard stop for that reason: create the account immediately,
then assert the wizard is closed.

## 4. compose.yml

```bash
cat > /srv/jellyfin/compose.yml <<'EOF'
# Jellyfin · the deterministic fallback. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   container install ... https://jellyfin.org/docs/general/installation/container
#   setup wizard ........ https://jellyfin.org/docs/general/post-install/setup-wizard/
#   backup .............. https://jellyfin.org/docs/general/administration/backup-and-restore
#
# One container. Config and cache are the server state (users, library metadata,
# watch progress). Media is a bind mount of a path the user already owns, read
# only, supplied via JELLYFIN_MEDIA_PATH in .env (not a secret; compose
# interpolates it). This file never downloads content. Tag and digest are the
# 10.10.7 release read from Docker Hub on 2026-08-07; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  jellyfin:
    image: jellyfin/jellyfin:10.10.7@sha256:7ae36aab93ef9b6aaff02b37f8bb23df84bb2d7a3f6054ec8fc466072a648ce2
    container_name: jellyfin
    restart: unless-stopped
    volumes:
      # Database, users, library metadata, watch state. The thing to back up.
      - /srv/jellyfin/config:/config
      # Transcode and image cache. Safe to lose; rebuilds itself.
      - /srv/jellyfin/cache:/cache
      # The user's own library. Path comes from .env (JELLYFIN_MEDIA_PATH).
      # Read only: Jellyfin does not need to write into the media tree.
      - ${JELLYFIN_MEDIA_PATH}:/media:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8204.
      - "127.0.0.1:8204:8096"
EOF
cd /srv/jellyfin && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port. Config and cache are the
writable state; media is read only. Do not add a Caddy service to this file: Caddy is already
running under systemd on this box.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
cat > /srv/jellyfin/Caddyfile <<'EOF'
# Jellyfin · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://jellyfin.org/docs/general/networking/caddy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8204 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8204
}
EOF
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-jellyfin
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sed "s|<DOMAIN>|${REAL_DOMAIN}|g" /srv/jellyfin/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `REAL_DOMAIN` to the hostname the user gave in step 1 before running sed (for example
`REAL_DOMAIN=media.example.com`). Do not wrap the value in extra quotes inside the sed
replacement. Assert: validate and reload exit 0. If validate fails, restore
`/etc/caddy/Caddyfile.before-jellyfin`, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own.

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
443/udp is HTTP/3. 8204 stays closed because compose binds it to 127.0.0.1. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8204 or 8096.

## 7. Start and verify

```bash
cd /srv/jellyfin
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/System/Info/Public); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/System/Info/Public
curl -sS https://<DOMAIN>/System/Info/Public | grep -o '"StartupWizardCompleted":[^,]*'
curl -sSL https://<DOMAIN>/web/ | grep -ci 'jellyfin'
```

Assert all four, and print what you received for each. The loop ends printing `200`. The public
system info is JSON that names the product. Before the wizard finishes,
`StartupWizardCompleted` is `false`. The web shell mentions jellyfin (case insensitive count
greater than 0). If any of the four misses, stop, run `docker compose logs --tail 40 jellyfin`,
and name the likely earlier step: a container that exits on a volume error is usually step 2
(the media path does not exist or is not readable), and a 502 from Caddy with a running
container is step 5. A running container is not success.

STOP: tell the user to open https://<DOMAIN> in a private window now, complete the setup
wizard (language, administrator username and password, and optionally add a library pointing at
`/media` inside the container, which is their host path), and confirm back to you that they can
sign in as that administrator. Do not continue until they confirm. This is the claim-race
window: whoever finishes the wizard first owns the box.

```bash
curl -sS https://<DOMAIN>/System/Info/Public | grep -o '"StartupWizardCompleted":[^,]*'
```

Assert: that prints `"StartupWizardCompleted":true`. That is the security assert in this block.
If it still prints `false`, the wizard was not completed; do not go on.

## 8. First backup and restore

One archive: config (users, library metadata, watch state), cache, compose, the media path
pointer in `.env`, and the live Caddy site block. Media files are not in it. That is deliberate:
they are large, already owned by the user, and belong in whatever backup protects the machine
they came from.

```bash
cd /srv/jellyfin
docker compose stop
sudo tar -czf /srv/jellyfin/backups/jellyfin-$(date +%F).tar.gz -C /srv/jellyfin config cache compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/jellyfin/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds, and
the container is stopped on purpose so SQLite under config is not copied mid-write.

A backup on the same disk as the data is not a backup. Run this from the user's machine, not
the server:

```bash
mkdir -p ~/backups/jellyfin
scp vps:/srv/jellyfin/backups/*.tar.gz ~/backups/jellyfin/
```

To restore: `docker compose down`, `sudo rm -rf /srv/jellyfin/config /srv/jellyfin/cache`,
recreate those directories as in step 2, untar the archive back into /srv/jellyfin (which
restores config, cache, compose.yml and `.env`), put the Caddy block back if that is what was
lost, then `docker compose up -d`. Tell the user which half matters: `config/` is every account
and every watched progress, `.env` is which host path is mounted as `/media`, and the media
files themselves are outside this archive. Losing config loses the server identity. Losing media
loses the library. Neither half replaces the other.

## 9. Updating later

New versions are listed at https://github.com/jellyfin/jellyfin/releases. The release tag and
the image tag are the same string, so release `10.10.8` is image tag `10.10.8`. This install
pins 10.10.7, the settled end of the 10.10 line, rather than the newer 10.11 series: 10.11 is
the release that migrates the library database, and a first install is the wrong moment to
take a one-way migration. Move to 10.11 deliberately, after a backup, once its release notes
read as settled to you. Take a backup first, then edit the image line in
/srv/jellyfin/compose.yml to the new tag and its digest:

```bash
cd /srv/jellyfin
docker compose pull
docker compose up -d
docker compose logs --tail 30 jellyfin
```

Watch that log until it settles, then re-run step 7's public info check and a signed-in browse
before calling the update done.

## 10. What will probably go wrong

You will stream a 4K file to a phone on a mobile network through this VPS and watch the
provider's egress counter climb while the CPU pegs on a software transcode. I did that on a
two-core cloud instance and called the box broken. It was not broken; it was the wrong place
for that workload. Direct-play on the LAN, or a home box with the library on the same switch,
is the shape this product assumes. The VPS path is for when the library already lives near a
good uplink and you still want HTTPS and remote friends. Match clients to formats the TV can
play without transcoding, or buy CPU, and treat egress as a real line item.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy is already running under systemd on
  this box, and a second one would fight it for 80 and 443.
- Do not publish 8096 or 8204 on the public interface or open them in the firewall. Caddy is
  the only way in.
- Do not download copyrighted media or point the library at someone else's content. This
  install only mounts a path the user supplies.
- Do not enable hardware transcoding devices in this prompt. That needs host-specific devices
  and drivers; software transcoding is the portable default.
