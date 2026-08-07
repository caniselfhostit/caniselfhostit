This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Syncthing 2.1.3 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1, because it is the shape of the whole install. Syncthing is peer to
peer: your own computers hold the files and sync to each other directly. This server is one more
peer, the always awake one, and step 7 configures it as an untrusted peer, so what lands on its
disk is ciphertext it cannot read. The password that opens that ciphertext is typed on your own
computer and never reaches this server, which means if you lose it nobody can recover the copy
here. Upstream calls the untrusted-device feature beta.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line. Syncthing itself is small; the disk figure is the floor before the
files you sync, which sit on top of it.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for this
hostname, because the sync protocol on 22000 does not go through Caddy or a CDN at all and a
proxied A record will confuse the certificate rather than help it.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/syncthing /srv/syncthing/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/syncthing/data /srv/syncthing/data/config /srv/syncthing/data/sync
ls -la /srv/syncthing /srv/syncthing/data
```

You should see: `backups` owned by you, and `data`, `config` and `sync` owned by uid `1000`,
which `ls` prints as a bare number if no account on the box has that id.

If you do not: leave those three owned by 1000 on purpose. The image runs Syncthing as uid 1000
and hands the mount root to that uid on every start, so a directory owned by you would be one
Syncthing cannot write into. `data/config` will hold config.xml, the device certificate and the
database; `data/sync` is where the encrypted copy of your files lands in step 7.

## 3. Secrets

One secret is generated here, on the server: the web interface password. It goes straight into a
file only you can read. Hex rather than base64, because it travels through a pipe into a
container in step 7 and hex holds nothing a shell treats as special.

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

You should see: mode `-rw-------`, your own username twice, and the path. Your login is `admin`.
Read the password once with `grep -F GUI_PASSWORD /srv/syncthing/.env` and put it in your
password manager.

Do not paste that file, the password, or any command output containing it into this chat window.
That applies twice over to the other password in this install: the folder encryption password
you will create in step 7 on your own computer. It never reaches this server, and it must never
reach a chat window either, because it is the only thing standing between the ciphertext on that
disk and your files.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/syncthing/.env` and
carry on. If the file already existed from an earlier attempt this block has overwritten the
password, which is harmless before step 7 runs and means a locked-out login afterwards; in that
case re-run the `syncthing generate` line in step 7 and restart the container.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/syncthing/compose.yml` and paste again in one go. `port is already
allocated` at step 7 rather than here means something else on the box holds 22000; find it with
`sudo ss -ltnp | grep 22000` before changing anything. There is no database container in this
file: Syncthing keeps its own SQLite database beside config.xml under data/config.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-syncthing /etc/caddy/Caddyfile`, reload,
and paste again. This site block carries the web interface only. The sync protocol on 22000 is a
device-to-device TLS session authenticated by device certificates, so it does not pass through
Caddy and there is no second site block to write for it.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 22000/tcp
sudo ufw allow 22000/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp`, `443/udp`, `22000/tcp` and
`22000/udp`, and no rule mentioning `8139` or `21027`.

If you do not: delete anything for `8139` with `sudo ufw delete allow 8139`. 8139 is bound to
127.0.0.1 by the compose file, so it has no business in the firewall. The two 22000 rules are
the ones worth understanding: that is upstream's sync protocol port, TCP and the same protocol
over QUIC on UDP, and a peer connects to this server on it directly, without passing through
Caddy, so no reverse proxy can stand in for it. 21027/udp stays closed because upstream uses it
for broadcast and multicast discovery on a local segment, which this server shares with none of
your devices. One more thing about the 22000 rules: Docker writes its own iptables rules for a
published port ahead of ufw's, so deleting them would not close the port. `docker compose down`
does. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The configuration is written before the server ever listens, so the web interface never answers
without a password. The password reaches the container over a pipe, so it lands in neither the
process list nor your shell history.

```bash
cd /srv/syncthing
docker compose pull
grep -F GUI_PASSWORD /srv/syncthing/.env | cut -d= -f2- | docker compose run --rm -T syncthing generate --gui-user admin --gui-password - --no-port-probing
sudo sed -i -E 's#<(globalAnnounceEnabled|localAnnounceEnabled|relaysEnabled|natEnabled|crashReportingEnabled)>true<#<\1>false<#; s#<urAccepted>0<#<urAccepted>-1<#' /srv/syncthing/data/config/config.xml
sudo chown 1000:1000 /srv/syncthing/data/config/config.xml
sudo grep -cE '>false</(globalAnnounce|localAnnounce|relays|nat|crashReporting)Enabled>|<urAccepted>-1<' /srv/syncthing/data/config/config.xml
```

You should see: a line about a generated key and calculated device id from the first command,
then `6` from the last.

If you do not: `6` under-counting means the generated config is not the shape this prompt
expects, and you should stop rather than start it. Those six lines are every connection this
server would otherwise open to infrastructure you do not run: global discovery, LAN
announcements, the community relay pool, STUN and UPnP, crash reporting and anonymous usage
reporting. A box with a fixed public address and an open 22000 needs none of them, and the
laptop you pair in a moment gets the address typed in by hand instead. The `chown` line is
there because `sudo sed` can leave the file owned by root, and a config.xml Syncthing cannot
write is a container that starts and then cannot save anything.

```bash
cd /srv/syncthing
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/rest/noauth/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/rest/noauth/health
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/rest/system/status
curl -sS https://<DOMAIN>/ | grep -o 'Authentication Required'
curl -sSI https://<DOMAIN>/ | grep -iE 'x-syncthing-(version|id)'
```

You should see, in order: the loop reaching `200`; a small JSON object containing
`"status": "OK"`; then `403`; then the literal `Authentication Required`; then two headers, a
Syncthing version reading `v2.1.3` and a Syncthing id followed by a long hyphenated Device ID.
Header names arrive lowercased over HTTP/2, which is why that last grep is case-insensitive.
Copy the Device ID somewhere; the next step needs it.

If you do not: the `403` is the one worth understanding. It means the API is up and refusing a
call with no credentials, which is what you want to see, because the password existed before the
first request ever arrived. A `200` there instead would mean the interface is open to anyone who
finds the hostname, and you should stop. `Authentication Required` is the heading above the
`User` and `Password` boxes on the first screen at https://<DOMAIN>. If the loop never reaches
`200`, run `docker compose logs --tail 40 syncthing`: a container that exits immediately is
usually step 2, a config directory uid 1000 cannot write, and a `502` from Caddy with a healthy
container is step 5. A running container is not success.

Now pair the computer that holds the files you want synced. This part happens in two places, and
you have to finish it before the asserts at the end of this step mean anything.

On that computer: install Syncthing from https://syncthing.net/downloads/ and open its web
interface. Click `Add Remote Device` and paste the Device ID from the header above. Give it a
name. On the `Advanced` tab of that dialog, set the address to `tcp://<DOMAIN>:22000` and tick
`Untrusted`, whose help text reads `All folders shared with this device must be protected by a
password, such that all sent data is unreadable without the given password.`

Then, in the interface at https://<DOMAIN>, log in as `admin` with the password from step 3. A
`New Device` panel appears saying the device `wants to connect`. Accept it with `Add Device`.

You should see: both sides showing the other as `Connected` within a minute or so.

If you do not: check `sudo ufw status verbose` again, because a device that never connects is
almost always 22000 closed. The address you typed is the reason global discovery is off on the
server: nothing announces this box anywhere, so the laptop reaches it because you told it where.

Now share the folder, and read this before you do. On your own computer, open the folder's edit
dialog, go to `Sharing`, tick this server, and type an encryption password in the field beside
it. That password is created and typed on your computer only. Do not enter it into the interface
on the server, do not put it in any file on the server, and do not paste it into this chat
window. Losing it makes the copy on that server unreadable forever, so it goes in your password
manager first. Drop a test file named `selfhost-check.txt` into the folder, then save.

In the interface at https://<DOMAIN> a `New Folder` panel now appears saying the device
`wants to share folder`. Accept it, set `Folder Path` to `/var/syncthing/sync`, and set
`Folder Type` to `Receive Encrypted` before you save. That last choice is permanent: upstream
disables the dropdown once a folder exists, and the only way back is to remove the folder and
add it again.

Once both sides read `Up to Date`:

```bash
sudo grep -c 'type="receiveencrypted"' /srv/syncthing/data/config/config.xml
sudo find /srv/syncthing/data/sync -maxdepth 1 -type d -name '*.syncthing-enc' | wc -l
sudo find /srv/syncthing/data/sync -name 'selfhost-check.txt' | wc -l
```

You should see: `1`, then at least `1`, then `0`.

If you do not: the third number is the one that matters, and anything but `0` means the server
is holding your files in the clear. That happens when `Folder Type` was left at `Send & Receive`
in the accept dialog. Remove the folder in the server interface, then
`sudo rm -rf /srv/syncthing/data/sync`, recreate it exactly as in step 2, and add the folder
again with the type set this time. The second number being `0` while the first is `1` usually
means nothing has synced yet, so give it a minute. A running container is not success; these
three numbers are.

## 8. First backup and restore

One archive: the device identity, the configuration, the database and the live Caddy site block.

```bash
cd /srv/syncthing
docker compose stop
sudo tar -czf /srv/syncthing/backups/syncthing-$(date +%F).tar.gz -C /srv/syncthing data/config compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/syncthing/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install. The container goes down for
about five seconds on purpose, because the database is SQLite and a SQLite file copied mid-write
is not a backup.

If you do not: an archive under a kilobyte means `data/config` was empty, so step 7 never ran.
The irreplaceable file inside is `data/config/key.pem`. That is this server's Device ID, and
restoring it is what lets every paired device reconnect without approving a new device.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/syncthing
scp vps:/srv/syncthing/backups/*.tar.gz ~/backups/syncthing/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/syncthing/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a test file:

```bash
cd /srv/syncthing
docker compose down
sudo rm -rf /srv/syncthing/data/config
sudo tar -xzf /srv/syncthing/backups/syncthing-$(date +%F).tar.gz -C /srv/syncthing data/config
sudo chown -R 1000:1000 /srv/syncthing/data
docker compose up -d
sleep 15
curl -sSI https://<DOMAIN>/ | grep -i x-syncthing-id
```

You should see: the same Device ID the earlier command printed. Same identity, same paired
devices, nothing to approve again.

If you do not: a different Device ID means the archive did not contain `data/config/key.pem` and
Syncthing generated a fresh identity, which every peer will treat as a stranger. Stop and take a
new backup before going any further. What is not in that archive is /srv/syncthing/data/sync,
because it is already a second copy of what is on your own devices, and it is ciphertext only
the folder password opens. Upstream ships `syncthing decrypt` for reading it back on a trusted
computer if it ever becomes the last copy you have.

## 9. Updating later

New versions are listed at https://github.com/syncthing/syncthing/releases. The Docker Hub tag
drops the leading `v`, so release `v2.1.4` is image tag `2.1.4`. Take a backup first, then edit
the `image:` line in /srv/syncthing/compose.yml to the new tag and its digest.

```bash
cd /srv/syncthing
docker compose pull
docker compose up -d
docker compose logs --tail 30 syncthing
```

You should see: a startup line naming the new version, then the folder going to `Up to Date`,
and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Syncthing
migrates its own database on the way up, so a first start after an update can take longer than
usual. Re-run the health and header checks from step 7 before you call the update done, and
check that the folder still reads `Up to Date` on both sides.

## 10. What will probably go wrong

The first time a folder finished syncing I opened /srv/syncthing/data/sync expecting my
documents, found a directory called `S.syncthing-enc` full of two-character folders holding
names like `K3P1VJO08DEQJ1DQJE0DLOMT068JJFD857L8ODM2TAKI3CC`, and spent a few minutes sure the
transfer had corrupted something. It had not. That is what a folder looks like from the
untrusted side, and it is the point: on that box I could not read my own files, so neither can
whoever takes it. Judge this by `Up to Date` in the interface and step 7's last three asserts.

## 11. Out of scope

- Do not change the folder on this server to `Send & Receive`, `Send Only` or `Receive Only`.
  Each means this machine holds plaintext, the one thing the install prevents, and upstream will
  not let you switch back.
- Do not put the folder encryption password on this server: not in .env, not in the interface,
  not in this chat window. It belongs on your own computers.
- Do not turn global discovery, relaying or NAT traversal back on. This box has a fixed public
  address and an open 22000, so it needs none of them.
- Do not open 21027/udp or switch the container to host networking. There is no local network
  here to discover anything on.
