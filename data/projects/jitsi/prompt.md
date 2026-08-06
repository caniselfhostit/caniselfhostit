You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Jitsi Meet stable-11146-1 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server: step 3 reads that record to tell the video
bridge where participants send media, so a wrong one fails silently later, not loudly now.

Jitsi Meet needs 2048 MB of RAM available and 10 GB free on /srv. All four images publish amd64
and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop.

## 2. Layout

Upstream states the containers run as uid 1000 and refuse to start when a directory they write
to is not writable by it, so these have two owners on purpose:

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/jitsi /srv/jitsi/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/jitsi/prosody
sudo install -d -m 755 -o 1000 -g 1000 /srv/jitsi/config /srv/jitsi/config/web /srv/jitsi/config/prosody /srv/jitsi/config/jicofo /srv/jitsi/config/jvb
ls -la /srv/jitsi
```

Assert: `backups` is owned by the login user and `prosody` is mode `750` owned by uid `1000`.
That directory is the entire persistent state here: the Prosody account file, which after step
7 is all that stands between a stranger and opening meetings on this hostname. The `config`
tree is rewritten at every start.

## 3. Secrets

Three: the XMPP password Jicofo signs in with, the one the video bridge signs in with, and the
moderator password step 7 registers. Generate all three on the server. Do not print them,
do not repeat them in your summary, do not put them in a log line.

```bash
umask 077
cat > /srv/jitsi/.env <<EOF
PUBLIC_URL=https://<DOMAIN>
JICOFO_AUTH_PASSWORD=$(openssl rand -hex 32)
JVB_AUTH_PASSWORD=$(openssl rand -hex 32)
MEET_HOST_PASSWORD=$(openssl rand -base64 24)
EOF
printf 'JVB_ADVERTISE_IPS=%s\n' "$(dig +short <DOMAIN> | tail -1)" >> /srv/jitsi/.env
chmod 600 /srv/jitsi/.env
umask 022
ls -l /srv/jitsi/.env
grep -c '^JVB_ADVERTISE_IPS=[0-9]' /srv/jitsi/.env
```

Assert: mode `-rw-------`, and the last command prints `1`. A `0` means the A record resolved to
nothing and the bridge would advertise no address, which is a meeting where everyone connects
and nobody hears anyone. Fix the DNS and rerun this block.

Tell the user the moderator password is in /srv/jitsi/.env, readable with
`grep MEET_HOST_PASSWORD /srv/jitsi/.env`, and that it belongs in their password manager now:
it is the only login here.

## 4. compose.yml

```bash
cat > /srv/jitsi/compose.yml <<'EOF'
# Jitsi Meet · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   self-hosting guide . https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker/
#   variable reference . https://github.com/jitsi/docker-jitsi-meet/blob/stable-11146-1/env.example
#   upstream compose ... https://github.com/jitsi/docker-jitsi-meet/blob/stable-11146-1/docker-compose.yml
#
# Four services and no database. Prosody carries the signalling, Jicofo decides
# who is in which conference, the videobridge forwards media, the web container
# is nginx plus the browser app. Meetings are never stored, so the only state
# that outlives a restart is the Prosody account file under /srv/jitsi/prosody,
# which upstream requires to be writable by uid 1000.
#
# Tags and digests read from ghcr.io on 2026-08-06; all four publish amd64 and
# arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: jitsi

services:
  prosody:
    image: ghcr.io/jitsi/prosody:stable-11146-1@sha256:0e3d9ada40c03e6eef151348e0872dce7b4b1c16c173ff4a67afeae60aba2404
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - /srv/jitsi/config/prosody:/config
      - /srv/jitsi/prosody:/var/lib/prosody
    environment:
      # Rooms open only for an account registered in step 7; guests wait.
      ENABLE_AUTH: "1"
      AUTH_TYPE: internal
      ENABLE_GUESTS: "1"
      JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}
      JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}
      # Read by step 7's register command inside this container.
      MEET_HOST_PASSWORD: ${MEET_HOST_PASSWORD}
      PUBLIC_URL: ${PUBLIC_URL}
    # No `ports:`: 5222 and 5280 are reachable only from the other containers.

  jicofo:
    image: ghcr.io/jitsi/jicofo:stable-11146-1@sha256:a5da296923010dcc2daf6a02e6a183181906cb969a088ae90b97516bdeb9737f
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - /srv/jitsi/config/jicofo:/config
    environment:
      ENABLE_AUTH: "1"
      AUTH_TYPE: internal
      JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD}
      # Upstream's default heap ceiling is 3072m, larger than the whole box.
      JICOFO_MAX_MEMORY: 512m
      XMPP_SERVER: prosody
    depends_on:
      - prosody

  jvb:
    image: ghcr.io/jitsi/jvb:stable-11146-1@sha256:6a7cec66c6a2fdd8ffd3a90101a0f8e3297aff29494f258caf1bcfbd418a17f3
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - /srv/jitsi/config/jvb:/config
    environment:
      JVB_AUTH_PASSWORD: ${JVB_AUTH_PASSWORD}
      # Behind Docker's NAT. Step 3 writes the address to advertise.
      JVB_ADVERTISE_IPS: ${JVB_ADVERTISE_IPS}
      VIDEOBRIDGE_MAX_MEMORY: 1024m
      XMPP_SERVER: prosody
    ports:
      # Media, not web: browsers send RTP straight here.
      - "10000:10000/udp"
    depends_on:
      - prosody

  web:
    image: ghcr.io/jitsi/web:stable-11146-1@sha256:ff81559621732d3dfc4815f261d41fd826566833016ea772f4d43a77aa88fe9a
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run:size=16M,mode=1750,exec
      - /tmp:size=16M,mode=1777,noexec
    volumes:
      - /srv/jitsi/config/web:/config
    environment:
      PUBLIC_URL: ${PUBLIC_URL}
      # Caddy holds the certificate, so nginx here serves plain http on 8000.
      DISABLE_HTTPS: "1"
      ENABLE_AUTH: "1"
      ENABLE_GUESTS: "1"
      XMPP_BOSH_URL_BASE: http://prosody:5280
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8114.
      - "127.0.0.1:8114:8000"
    depends_on:
      - jvb
EOF
cd /srv/jitsi && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No database anywhere, so nothing to migrate or dump. Both heap ceilings are deliberate cuts from upstream's 3072m defaults.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-jitsi
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Jitsi Meet · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also PUBLIC_URL in .env, and the browser app builds its signalling URL from
# it, so the two have to agree.

<DOMAIN> {
	# The signalling WebSocket is upgraded by reverse_proxy on its own.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8114 is the loopback port compose publishes. No media comes through here.
	reverse_proxy 127.0.0.1:8114
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-jitsi, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own. It carries the page and the
signalling WebSocket, and no media.

## 6. Firewall

Four ports, and one of them is not Caddy's:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 10000/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp carries the page and the
signalling, 443/udp is HTTP/3. 10000/udp is the different one: upstream lists it as the RTP
media port, and media goes from each browser straight to the video bridge without touching
Caddy, so no reverse proxy can stand in for it the way one does for 8114, which stays closed on
127.0.0.1.

Assert: `Status: active`, rules for 80, 443/tcp, 443/udp and 10000/udp, none for 8114. Tell the
user one thing about that fourth rule: Docker writes its own iptables rules for a published port
ahead of ufw's, so deleting it would not close 10000/udp. `docker compose down` does.

## 7. Start and verify

```bash
cd /srv/jitsi
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/ | grep -o '<title>Jitsi Meet</title>'
curl -sS https://<DOMAIN>/config.js | grep -E "config.hosts.(auth|anonymous)domain"
ss -lun | grep ':10000'
```

Assert all four and print what you received. The loop ends on `200`. The second prints
`<title>Jitsi Meet</title>`. The third prints
`config.hosts.anonymousdomain = 'guest.meet.jitsi';` and
`config.hosts.authdomain = 'meet.jitsi';`, two lines that appear only when authenticated room
creation is on. The fourth prints a UDP listener on 10000. If any miss, stop, run
`docker compose logs --tail 40 web` and `docker compose logs --tail 40 prosody`, and name the
likely step: a `502` means Caddy reaches nothing on 8114; missing `config.hosts` lines mean step
4 was edited. A running container is not success.

Register the account that can open meetings, and prove nobody else can:

```bash
cd /srv/jitsi
docker compose exec -T prosody sh -c 'prosodyctl --config /run/prosody/config/prosody.cfg.lua register moderator meet.jitsi "$MEET_HOST_PASSWORD"'
docker compose exec -T prosody find /var/lib/prosody -name 'moderator.dat'
docker compose exec -T prosody awk '/^VirtualHost "meet.jitsi"$/,/^VirtualHost /' /run/prosody/config/conf.d/jitsi-meet.cfg.lua | grep authentication
```

Assert both. The `find` prints one path ending in `moderator.dat`. The `awk` prints
`authentication = "internal_hashed"`, the security assert here: that domain takes registered
accounts only, so a visitor without one can wait in a room but cannot open one. The password
reached prosodyctl from the container's own environment, so it is in neither the host process
list nor the shell history. If the `find` prints nothing, Prosody was likely still
starting: wait 30 seconds and rerun the register line. On any other miss, stop.

The first screen at https://<DOMAIN> is the Jitsi welcome page, with a room-name box and a
`Start meeting` button.

STOP: tell the user to open https://<DOMAIN>, type a room name, start the meeting, and sign in
as `moderator` with the password from `grep MEET_HOST_PASSWORD /srv/jitsi/.env`. Then have them
open the same room in a private window without signing in and confirm it is told to wait for a
host. Wait for both. Do not continue until they confirm. Only a browser proves a camera and a
microphone reach the bridge.

## 8. First backup and restore

One archive. There is no database and meetings never existed as data, so what is worth
keeping is small: the account file, the two config files, the Caddy site block.

```bash
cd /srv/jitsi
sudo tar -czf /srv/jitsi/backups/jitsi-config-$(date +%F).tar.gz -C /srv/jitsi compose.yml .env prosody -C /etc/caddy Caddyfile
ls -lh /srv/jitsi/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped.

A backup on the same disk as the data is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/jitsi
scp vps:/srv/jitsi/backups/*.tar.gz ~/backups/jitsi/
```

To restore: `docker compose down`, `sudo rm -rf /srv/jitsi/prosody`,
`sudo tar -xzf <archive> -C /srv/jitsi compose.yml .env prosody`,
`sudo chown -R 1000:1000 /srv/jitsi/prosody` because the container user has to own it again,
then `docker compose up -d`. The Caddy site block is in the same archive if /etc/caddy ever
needs rebuilding. Losing this costs no history, there is none, but it costs the moderator
account and the two service passwords: a stack that starts and refuses every login until steps
3 and 7 are redone.

## 9. Updating later

New versions are listed at https://github.com/jitsi/docker-jitsi-meet/releases. Take the backup
first, then edit all four image lines in /srv/jitsi/compose.yml to the new tag and its digest.
The four ship together and upstream does not support mixing them.

```bash
cd /srv/jitsi
docker compose pull
docker compose up -d
docker compose logs --tail 30 jicofo
```

Watch that log until it settles, then re-run the four checks from step 7.

## 10. What will probably go wrong

The install will look finished and the first call will have picture and no sound. I lost most of
an evening to that. The page comes through Caddy and the media does not: it goes to 10000/udp at
the bridge, using the address in `JVB_ADVERTISE_IPS`, and all three can be right on their own
while the call stays silent. Check in that order: `grep JVB_ADVERTISE_IPS /srv/jitsi/.env`
against `dig +short <DOMAIN>`, then `ss -lun | grep ':10000'`, then whether the hosting provider
runs a firewall of its own in front of the box, because several do and UDP is what gets forgotten
there.

## 11. Out of scope

- Do not install Jibri or configure recording. That is a separate container running a headless
  browser with a CPU budget of its own.
- Do not install Jigasi or set up dial-in numbers. That needs a SIP provider and a phone number,
  which is a purchase, not a configuration step.
- Do not enable `ENABLE_LETSENCRYPT`. Caddy holds the certificate for this hostname and a second
  ACME client on the same name collides with it.
- Do not switch `AUTH_TYPE` to `jwt` or add an identity provider. Internal accounts are the
  choice here.
