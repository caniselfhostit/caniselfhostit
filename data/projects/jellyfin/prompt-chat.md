This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Jellyfin 10.10.7 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read these three before step 1, because together they decide whether you want this at all.
Jellyfin streams files you already own: there is no catalogue and nothing appears that you did
not put on a disk. A home box with the library on the same LAN is the usual shape; a VPS is a
remote front door, and every remote stream burns that provider's egress the way a Netflix bill
would. Between first start and the end of the setup wizard, anyone who can reach the hostname
may finish setup first and become the administrator, so you will create that account in the
same session you start the container.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `20` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under the RAM or disk
floor means stop: a software transcode on a starving box fails mid-stream, not at start-up.


Jellyfin needs 2048 MB free RAM and 20 GB free on /srv before any media. The 20 GB covers
the image, config, cache and a small staging area. A real movie collection lives on storage
you already own and is not counted in that floor. Software transcoding is CPU-heavy: if you
plan to convert 4K to phone formats on this box, treat the RAM floor as a minimum and prefer
more cores.


## 2. Layout

Config and cache are what Jellyfin writes. Media is a path you already own, mounted read only.

Pick an absolute path on this server to a library you already have (or will fill yourself), for
example `/mnt/media`. If you have nothing yet, use `/srv/jellyfin/media` and create it empty.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/jellyfin /srv/jellyfin/backups /srv/jellyfin/config /srv/jellyfin/cache
# Only if you chose the empty staging path:
# sudo install -d -m 755 -o $(id -u) -g $(id -g) /srv/jellyfin/media
ls -la /srv/jellyfin
test -d /mnt/media && ls -ld /mnt/media
```

Replace `/mnt/media` with your real path in the `test` line and below. If the directory is
root-owned and unreadable, fix mode so the container can read it:
`sudo chmod -R a+rX /path/to/media`. Do not invent a fresh empty `media/` under /srv and leave
your real library unmounted.


Ownership matters. The official image runs as root when no `user:` line is set, so it can
read a world-readable library. Prefer not to leave media root-owned with mode 700: the
container will start, the library scan will find zero files, and the dashboard will look empty
for a reason that is not a Jellyfin bug. `ls -ld` on the path should show that ordinary
processes can traverse and read it (`a+rX` is enough). Never create an empty `/srv/jellyfin/media`
as a substitute for mounting the folder where your files already live, unless you intend to
copy files into that empty folder yourself.


Write the path into `.env` (not a secret; compose interpolates it):

```bash
umask 077
printf 'JELLYFIN_MEDIA_PATH=%s\n' '/mnt/media' > /srv/jellyfin/.env
chmod 600 /srv/jellyfin/.env
umask 022
cat /srv/jellyfin/.env
```

You should see one line with your path. Mode of `.env` is `-rw-------`.

## 3. Secrets

No secret is generated here. The first credential is the administrator account you create in
the setup wizard in step 7. Between the container starting and that account existing, anyone
who can reach the hostname may finish the wizard first. Create the account immediately after
start.

## 4. compose.yml

Paste the whole block:

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

You should see `compose OK`. One service, one published port. Config and cache are writable
state; media is read only. Do not add a Caddy service: Caddy already runs under systemd.

## 5. Caddy and TLS

Write the site block, then append it with your hostname in place of `<DOMAIN>`. Copy the live
Caddyfile first.

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
REAL_DOMAIN='media.example.com'
sed "s|<DOMAIN>|${REAL_DOMAIN}|g" /srv/jellyfin/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Put your real hostname in `REAL_DOMAIN` before you paste. You should see validate exit 0 and
reload exit 0. If validate fails, restore `/etc/caddy/Caddyfile.before-jellyfin`, reload, and
read the error. Caddy gets the certificate on the first request and renews it on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see `Status: active`, rules for 80 and 443, and nothing for 8204 or 8096. 80 is the
ACME challenge and HTTPS redirect, 443 is the only way in, 443/udp is HTTP/3.

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

You should see: the loop ends on `200`; JSON public system info; `StartupWizardCompleted` is
`false` until you finish the wizard; a jellyfin count greater than 0 on the web shell. If the
loop never reaches 200, run `docker compose logs --tail 40 jellyfin`. A missing or unreadable
media path is step 2; a 502 with a running container is step 5.

STOP: open https://<DOMAIN> in a private window now. Complete the setup wizard: language, admin
username and password, and optionally a library at `/media` (that is your host path inside the
container). Sign in as that administrator. Do not continue until you can sign in. This is the
claim-race window.

```bash
curl -sS https://<DOMAIN>/System/Info/Public | grep -o '"StartupWizardCompleted":[^,]*'
```

You should see `"StartupWizardCompleted":true`. If it is still `false`, the wizard was not
finished; stop and finish it.


In the wizard, when you add a library, the path inside the container is `/media`. That is the
bind of `JELLYFIN_MEDIA_PATH` from `.env`, mounted read-only. If the scan finds nothing, re-check
permissions on the host path and that `.env` points at the folder that actually holds files,
not its parent with a different layout. Hardware acceleration is out of scope on this path:
software decode works without GPU devices.

After the wizard, put the admin password in a password manager. There is no second factor in
this install and no SMTP for resets. A forgotten admin password means database work or a
re-run of the wizard on a wiped config, both worse than writing it down once.


## 8. First backup and restore

One archive: config, cache, compose, `.env`, and the live Caddyfile. Media files are not in it.

```bash
cd /srv/jellyfin
docker compose stop
sudo tar -czf /srv/jellyfin/backups/jellyfin-$(date +%F).tar.gz -C /srv/jellyfin config cache compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/jellyfin/backups/
```

The archive should exist and be non-empty. Print its size. Downtime is about ten seconds; the
container is stopped so config is not copied mid-write.

A backup on the same disk is not a backup. From your own machine (not the server):

```bash
mkdir -p ~/backups/jellyfin
scp vps:/srv/jellyfin/backups/*.tar.gz ~/backups/jellyfin/
```

To restore: `docker compose down`, remove `config` and `cache`, recreate them, untar the
archive into /srv/jellyfin, put the Caddy block back if needed, then `docker compose up -d`.
`config/` is accounts and watch state. `.env` is which host path mounts as `/media`. Media
files live outside this archive. Neither half replaces the other.


What the archive is not: your movies and shows. Those stay on `JELLYFIN_MEDIA_PATH`. Back them
up with whatever already protects that disk. What the archive is: every user, every library
definition, every watch progress marker, the compose pin, the path pointer, and the live
Caddy configuration that terminates TLS. Restore without media still boots an empty server
with your accounts. Restore media without config still leaves files on disk with no server
identity.




Remote friends need enough uplink and a client they can install. Jellyfin has clients for
phones, TVs and browsers; none of them remove the need for you to own the files. Plugins are
community code you choose to trust, and this install does not enable any. Live TV guide
subscriptions and paid plugin stores are out of scope the same way vendor support is out of
scope: there is no line to call.

When you later change `JELLYFIN_MEDIA_PATH`, stop the stack, edit `.env`, run
`docker compose up -d`, and re-scan libraries in the dashboard. A path that moves without an
update to `.env` is a silent empty library after reboot.

For a cold restore on a new VPS: install Docker and Caddy (Prompt Zero), restore the archive
into /srv/jellyfin, restore the Caddyfile fragment, ensure `JELLYFIN_MEDIA_PATH` still points
at media that exists on the new box (or re-attach storage first), then start compose and sign
in with the same admin account. Order matters: `.env` before first start, media path present
before you expect scans to find files.

## 9. Updating later

New versions are at https://github.com/jellyfin/jellyfin/releases. This install pins 10.10.7,
the settled end of the 10.10 line, on purpose: the newer 10.11 series migrates the library
database, and a first install is the wrong moment for a one-way migration. Move to 10.11
deliberately, after a backup, once its release notes read as settled to you. Take a backup
first, then edit the image line in /srv/jellyfin/compose.yml to the new tag and digest:

```bash
cd /srv/jellyfin
docker compose pull
docker compose up -d
docker compose logs --tail 30 jellyfin
```

Watch the log until it settles, then re-run step 7's public info check and a signed-in browse
before calling the update done.


If a release notes page mentions a one-way database migration, read it before pulling. Jellyfin
upgrades are usually forward-only: take the backup first, then pull, then watch logs for
migration messages. If the container loops, restore config from the archive and pin the previous
digest until you understand the failure.


## 10. What will probably go wrong

You will stream a 4K file to a phone on a mobile network through this VPS and watch the
provider's egress counter climb while the CPU pegs on a software transcode. That is not a
broken box; it is the wrong place for that workload. Direct-play on the LAN, or a home box
with the library on the same switch, is the shape this product assumes. Match clients to
formats the TV can play without transcoding, or buy CPU, and treat egress as a real line item.

The other common miss is leaving the wizard open. DNS for a new hostname is quieter than it
feels. Finish the admin account before you walk away to copy files. Assert
`StartupWizardCompleted` is true before you call the install done. Config without that assert
is an unlocked front door with a media server behind it.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy is already running under systemd on
  this box, and a second one would fight it for 80 and 443.
- Do not publish 8096 or 8204 on the public interface or open them in the firewall. Caddy is
  the only way in.
- Do not download copyrighted media or point the library at someone else's content. This
  install only mounts a path you supply.
- Do not enable hardware transcoding devices in this prompt. That needs host-specific devices
  and drivers; software transcoding is the portable default.

- Do not skip the first backup after the wizard. Config without a copy is a single disk failure
  away from losing every account and every watched position.
