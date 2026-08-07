You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Syncthing 2.1.3 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say this first, because it is the shape of the install. Syncthing is peer to peer: the user's
own computers hold the files and sync to each other. This server is one more peer, the always
awake one, and step 7 makes it untrusted, so what lands here is ciphertext this box cannot read
and no password that opens it is stored here. Upstream calls that feature beta.

Syncthing needs 512 MB of RAM available and 5 GB free on /srv, plus room for the synced files.
The image publishes amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/syncthing /srv/syncthing/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/syncthing/data /srv/syncthing/data/config /srv/syncthing/data/sync
ls -la /srv/syncthing /srv/syncthing/data
```

Assert: `backups` is owned by the login user, and `data`, `data/config` and `data/sync` by uid
`1000`, which the image runs Syncthing as. `data/config` holds config.xml, the device
certificate and the database; `data/sync` takes the ciphertext.

## 3. Secrets

One secret: the web GUI password. Generate it here, do not print it, and keep it out of your
summary and any log line. Hex, because it goes through a pipe into a container in step 7.

```bash
umask 077
cat > /srv/syncthing/.env <<EOF
GUI_USER=admin
GUI_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/syncthing/.env
umask 022
ls -l /srv/syncthing/.env
```

Assert: the file exists with mode `-rw-------`. Tell the user the login is `admin`, the password
is in /srv/syncthing/.env, they read it with `grep -F GUI_PASSWORD /srv/syncthing/.env`, and it
goes in their password manager now. The install's other password, the one that encrypts the
folder, is typed on the user's own computer in step 7 and never reaches this box.

## 4. compose.yml

```bash
cat > /srv/syncthing/compose.yml <<'EOF'
# Syncthing · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker image ....... https://github.com/syncthing/syncthing/blob/v2.1.3/README-Docker.md
#   image build ........ https://github.com/syncthing/syncthing/blob/v2.1.3/Dockerfile
#   ports .............. https://docs.syncthing.net/users/firewall.html
#
# One service, no host networking: upstream's example uses it for LAN
# discovery, which a rented server has no use for, so 21027/udp is not
# published at all. No env_file either: the only secret is the web GUI
# password, which step 7 turns into a bcrypt hash in config.xml before the
# server listens. Digest read 2026-08-06; amd64, arm64, arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  syncthing:
    image: syncthing/syncthing:2.1.3@sha256:8c8ff37ab6aa8be23b700648a90fa9412e214852e9fd6ea8477c8334792daec0
    container_name: syncthing
    hostname: syncthing-vps
    restart: unless-stopped
    environment:
      # Image defaults; step 2 creates data/ owned by this uid.
      PUID: "1000"
      PGID: "1000"
      # config.xml, the device certificate and the database all live here.
      STHOMEDIR: /var/syncthing/config
      # Container-internal; published on loopback below. The image also ships
      # a HEALTHCHECK on /rest/noauth/health that compose inherits.
      STGUIADDRESS: 0.0.0.0:8384
    volumes:
      - /srv/syncthing/data:/var/syncthing
    ports:
      # 8139 is loopback for Caddy; 22000 is the sync protocol itself, TCP
      # and QUIC, on every interface on purpose.
      - "127.0.0.1:8139:8384"
      - "22000:22000/tcp"
      - "22000:22000/udp"
EOF
cd /srv/syncthing && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, three published ports, no database container:
Syncthing's SQLite file sits beside config.xml.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-syncthing
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Syncthing · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.syncthing.net/users/reverseproxy.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. It carries the
# web GUI only: the sync protocol on 22000 is a device-to-device TLS session
# that a reverse proxy cannot terminate.

<DOMAIN> {
	encode zstd gzip

	# Syncthing sets nosniff and SAMEORIGIN itself. HSTS and the referrer
	# policy are added here: every request carries a session cookie for a
	# device holding somebody's files.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8139 is the loopback port compose publishes. Not a container port, and
	# not open in the firewall.
	reverse_proxy 127.0.0.1:8139
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-syncthing, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it on its own.

## 6. Firewall

Five ports, and two of them are not Caddy's:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 22000/tcp
sudo ufw allow 22000/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp carries the GUI, 443/udp is
HTTP/3. 22000/tcp is upstream's sync protocol port and 22000/udp is that protocol over QUIC;
both open because a peer reaches this server directly, device certificate to device certificate,
without passing through Caddy. 21027/udp stays closed: upstream uses it for broadcast and
multicast discovery on a local segment, which this box shares with none of the user's devices.
8139 stays closed because compose binds it to loopback.

Assert: `Status: active`, rules for 80, 443/tcp, 443/udp, 22000/tcp and 22000/udp, none for 8139
or 21027. Tell the user that Docker publishes 22000 with its own iptables rules ahead of ufw's,
so `docker compose down`, not a deleted ufw rule, is what closes it.

## 7. Start and verify

Write the configuration before the server ever listens, so the GUI never answers without a
password. It reaches the container over a pipe, so it is in neither the process list nor the
shell history.

```bash
cd /srv/syncthing
docker compose pull
grep -F GUI_PASSWORD /srv/syncthing/.env | cut -d= -f2- | docker compose run --rm -T syncthing generate --gui-user admin --gui-password - --no-port-probing
sudo sed -i -E 's#<(globalAnnounceEnabled|localAnnounceEnabled|relaysEnabled|natEnabled|crashReportingEnabled)>true<#<\1>false<#; s#<urAccepted>0<#<urAccepted>-1<#' /srv/syncthing/data/config/config.xml
sudo chown 1000:1000 /srv/syncthing/data/config/config.xml
sudo grep -cE '>false</(globalAnnounce|localAnnounce|relays|nat|crashReporting)Enabled>|<urAccepted>-1<' /srv/syncthing/data/config/config.xml
```

Assert: the last command prints `6`. Those six are every connection this server would otherwise
open to infrastructure the user does not run: global discovery, LAN announcements, the community
relay pool, STUN and UPnP, crash and usage reporting. A box with a fixed public address and an
open 22000 needs none. Under 6, stop: the config is not the shape this prompt expects.

```bash
cd /srv/syncthing
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/rest/noauth/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/rest/noauth/health
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/rest/system/status
curl -sS https://<DOMAIN>/ | grep -o 'Authentication Required'
curl -sSI https://<DOMAIN>/ | grep -iE 'x-syncthing-(version|id)'
```

Assert all five and print what you received. The loop ends on `200`. The health body contains
`"status": "OK"`. The unauthenticated API call prints `403`, the security assert here: the GUI
had a password before it had a first request. The page contains `Authentication Required`, the
heading over the `User` and `Password` boxes. The last command prints two headers, lowercased
over HTTP/2: a Syncthing version that must read `v2.1.3`, proving the pinned image is running,
and a long hyphenated Device ID to keep for the next step. If any miss, stop, run
`docker compose logs --tail 40 syncthing` and name the step: a container that exits at once is
step 2, a config directory the uid cannot write.

STOP: tell the user to do three things on the computer holding the files, and wait. Do not
continue until they confirm. One: install Syncthing from https://syncthing.net/downloads/ and
open its web GUI. Two: click `Add Remote Device`, paste the Device ID from above, name it, set
the address on the `Advanced` tab to `tcp://<DOMAIN>:22000`, and tick `Untrusted` there, whose
help text reads `All folders shared with this device must be protected by a password`. Three:
log in at https://<DOMAIN> and accept the `New Device` panel there.

STOP: tell the user to share one folder, and wait. Do not continue until they confirm. On their
own computer, in that folder's edit dialog under `Sharing`, they tick this server and type an
encryption password beside it. Say this plainly: that password is created and typed on their
computer only, never entered into the GUI here or written into any file on this box, and losing
it makes this copy unreadable forever. Have them drop a test file named `selfhost-check.txt`
into the folder before saving. A `New Folder` panel then appears in the GUI here, saying the
device `wants to share folder`. They accept it, set `Folder Path` to `/var/syncthing/sync`, and
set `Folder Type` to `Receive Encrypted` before saving. That choice is permanent: upstream
disables the dropdown once a folder exists.

Once both sides read `Up to Date`:

```bash
sudo grep -c 'type="receiveencrypted"' /srv/syncthing/data/config/config.xml
sudo find /srv/syncthing/data/sync -maxdepth 1 -type d -name '*.syncthing-enc' | wc -l
sudo find /srv/syncthing/data/sync -name 'selfhost-check.txt' | wc -l
```

Assert all three: `1`, then at least `1`, then `0`. The first says this server holds the folder
as receive-encrypted. The second says the data arrived, in the encrypted-name directory tree
upstream documents. The third is the one that matters: the file the user made is on this disk
and its name is not. A running container is not success; these three are. If the third is not
`0`, stop and say the folder holds plaintext, so `Folder Type` was not set when it was added.
The fix is to remove the folder here, delete and recreate /srv/syncthing/data/sync as in step 2,
and add it again.

## 8. First backup and restore

One archive: the device identity, the configuration, the database and the live Caddy site block.

```bash
cd /srv/syncthing
docker compose stop
sudo tar -czf /srv/syncthing/backups/syncthing-$(date +%F).tar.gz -C /srv/syncthing data/config compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/syncthing/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds, and
the container is stopped on purpose, because the database is SQLite and a SQLite file copied
mid-write is not a backup. The irreplaceable file in it is `data/config/key.pem`, this server's
Device ID: restoring it lets paired devices reconnect without approving a new one.

A backup on the same disk as the data is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/syncthing
scp vps:/srv/syncthing/backups/*.tar.gz ~/backups/syncthing/
```

To restore: `docker compose down`, `sudo rm -rf /srv/syncthing/data/config`, untar the archive
back into /srv/syncthing, `sudo chown -R 1000:1000 /srv/syncthing/data`, put the Caddy block
back if that was lost, then `docker compose up -d`. Not in the archive: data/sync, already a
second copy of the user's own files and useless without the folder password.

## 9. Updating later

New versions are listed at https://github.com/syncthing/syncthing/releases. The Docker Hub tag
drops the leading `v`, so `v2.1.4` is tag `2.1.4`. Back up first, then edit the image line in
/srv/syncthing/compose.yml to the new tag and its digest:

```bash
cd /srv/syncthing
docker compose pull
docker compose up -d
docker compose logs --tail 30 syncthing
```

Syncthing migrates its own database on the way up. Watch the log until it settles, then re-run
step 7's health and header checks before calling it done.

## 10. What will probably go wrong

The first time a folder finished syncing I opened /srv/syncthing/data/sync expecting my
documents, found a directory called `S.syncthing-enc` full of two-character folders holding
names like `K3P1VJO08DEQJ1DQJE0DLOMT068JJFD857L8ODM2TAKI3CC`, and spent a few minutes sure the
transfer had corrupted something. It had not. That is what a folder looks like from the
untrusted side, and it is the point: on that box I could not read my own files, so neither can
whoever takes it. Judge this by `Up to Date` and step 7's last three asserts.

## 11. Out of scope

- Do not change the folder here to `Send & Receive`, `Send Only` or `Receive Only`. Each means
  this machine holds plaintext, the one thing the install prevents, and upstream will not let
  you switch back.
- Do not put the folder encryption password on this server: not in .env, not in the GUI, not in
  your summary. It belongs on the user's own computers.
- Do not turn global discovery, relaying or NAT traversal back on. This box has a fixed public
  address and an open 22000, so it needs none of them.
- Do not open 21027/udp or switch the container to host networking. There is no local network
  here to discover anything on.
