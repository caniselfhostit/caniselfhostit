This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Jitsi Meet stable-11146-1 on a VPS where Prompt Zero is done: `ssh vps`
works, Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record
already points at the box.

Read this before step 1. Jitsi is two networks, not one. The page and the signalling come
through Caddy on 443; the audio and video go from every participant's browser straight to the
video bridge on 10000/udp, and that port has to be open on the box and reachable from outside
it. Most installs that "work but have no sound" are that second network.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. That record does two jobs here, not one: Caddy needs it to get
a certificate, and step 3 copies the address out of it so the video bridge knows where to tell
browsers to send media. An IP that is not your server's means a proxying CDN is in front of the
record; turn that off for this hostname, because a CDN will not carry UDP media and the address
step 3 records would be the wrong one.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/jitsi /srv/jitsi/backups
sudo install -d -m 750 -o 1000 -g 1000 /srv/jitsi/prosody
sudo install -d -m 755 -o 1000 -g 1000 /srv/jitsi/config /srv/jitsi/config/web /srv/jitsi/config/prosody /srv/jitsi/config/jicofo /srv/jitsi/config/jvb
ls -la /srv/jitsi
```

You should see: `backups` owned by you, and `prosody` and `config` owned by `1000`, which on
many servers is also you.

If you do not: leave the `1000` there even if it is not your own id. Upstream states these
containers run as uid 1000 and check on startup that the directory they write to is writable by
it, so a directory owned by anyone else produces a Prosody container that exits immediately with
a message about a volume that is not writable. `/srv/jitsi/prosody` is the only directory in
this install that holds anything you would miss.

## 3. Secrets

Three secrets, all generated on the server: the XMPP password Jicofo signs in with, the one the
video bridge signs in with, and the password for the moderator account step 7 creates.

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

You should see: mode `-rw-------`, your own username twice, and then `1` on the last line.
Replace `<DOMAIN>` on the first line with your real hostname before you paste.

If you do not: a `0` on the last line means `dig` returned nothing and the bridge would come up
advertising no address, which is a meeting where everybody connects and nobody can hear anyone.
Fix the DNS and paste this block again. A mode of `-rw-r--r--` means `umask 077` did not take
effect, which happens when the lines are pasted separately into different shells; run
`chmod 600 /srv/jitsi/.env` and carry on.

Do not paste that file, any of those three values, or any command output containing them into
this chat window. Read your moderator password once, later, with
`grep MEET_HOST_PASSWORD /srv/jitsi/.env`, and put it straight into your password manager. It is
the only login this install has.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal; run `rm /srv/jitsi/compose.yml` and paste again in one go. A warning about
`JVB_ADVERTISE_IPS` being unset means step 3 did not finish. There is no database in this file
and that is not an omission: Jitsi stores no meetings, so there is nothing to migrate and
nothing to dump.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-jitsi /etc/caddy/Caddyfile`, reload, and
paste again. Caddy holds the certificate for this hostname, which is why `DISABLE_HTTPS` is set
in the compose file: the web container serves plain http on 8114 and generates no certificate of
its own. Nothing about media passes through this block.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 10000/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for `80/tcp`, `443/tcp`, `443/udp` and `10000/udp`,
with no rule mentioning `8114`.

If you do not: delete anything for `8114` with `sudo ufw delete allow 8114`; that port is bound
to 127.0.0.1 by the compose file and only Caddy reaches it. The rule that is different from
every other install on this site is `10000/udp`: upstream lists it as the RTP media port, and
media never passes through a reverse proxy, so this is the one place where "the proxy handles
it" is not true. One honest note about that rule: Docker installs its own iptables rules for a
published port ahead of ufw's, so removing this rule would not actually close 10000/udp.
`docker compose down` is what closes it. `Status: inactive` is a different problem, because
Prompt Zero left this firewall on: `sudo ufw enable` puts it back.

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

You should see, in order: the loop reaching `200`, then `<title>Jitsi Meet</title>`, then two
lines reading `config.hosts.anonymousdomain = 'guest.meet.jitsi';` and
`config.hosts.authdomain = 'meet.jitsi';`, then a line showing something listening on UDP
port 10000.

If you do not: a `502` from the loop means Caddy is reaching nothing on 8114, so check
`docker compose ps` and then `docker compose logs --tail 40 web`. If the loop reaches `200` but
the two `config.hosts` lines are missing, the authentication settings did not reach the web
container, so re-check step 4 and run `docker compose up -d --force-recreate web`. Those two
lines are what tell the browser to ask for a login, so an install without them is one anybody
can open meetings on. If the last command prints nothing, the bridge did not start; read
`docker compose logs --tail 40 jvb`. Connection-refused lines in `docker compose logs jicofo`
during the first minute are normal: it retries until Prosody is up.

Now create the account that is allowed to open meetings, and confirm that nobody else can:

```bash
cd /srv/jitsi
docker compose exec -T prosody sh -c 'prosodyctl --config /run/prosody/config/prosody.cfg.lua register moderator meet.jitsi "$MEET_HOST_PASSWORD"'
docker compose exec -T prosody find /var/lib/prosody -name 'moderator.dat'
docker compose exec -T prosody awk '/^VirtualHost "meet.jitsi"$/,/^VirtualHost /' /run/prosody/config/conf.d/jitsi-meet.cfg.lua | grep authentication
```

You should see: one path ending in `moderator.dat`, then `authentication = "internal_hashed"`.

If you do not: an empty `find` means the register command failed, most often because Prosody was
still starting; wait thirty seconds and paste the first line again. If the last line says
`authentication = "jitsi-anonymous"` instead, authentication is off and anyone who finds your
hostname can open a meeting on your bandwidth: stop, fix step 4, recreate the stack, and do not
leave it running in between. Note that your password never appears in either command, because
Prosody reads it from the container's own environment.

The first screen at https://<DOMAIN> is the Jitsi welcome page, with a room-name box and a
`Start meeting` button.

Now the part curl cannot do. Open https://<DOMAIN>, type a room name, start the meeting, and
sign in as `moderator` with the password from `grep MEET_HOST_PASSWORD /srv/jitsi/.env`. Allow
the camera and microphone when the browser asks. Then open the same room address in a private
window without signing in, and confirm that window is told to wait for a host rather than being
let straight in.

You should see: your own camera in the first window, and a waiting message in the second.

If you do not: a call that connects but has no audio or video is the media path, not the login.
Compare `grep JVB_ADVERTISE_IPS /srv/jitsi/.env` with `dig +short <DOMAIN>`, confirm
`ss -lun | grep ':10000'` still prints a listener, and then check whether your hosting provider
runs a firewall of its own in front of the box. A running container is not success, and neither
is a page that loads.

## 8. First backup and restore

One archive: the account file, the two config files, and the Caddy site block.

```bash
cd /srv/jitsi
sudo tar -czf /srv/jitsi/backups/jitsi-config-$(date +%F).tar.gz -C /srv/jitsi compose.yml .env prosody -C /etc/caddy Caddyfile
ls -lh /srv/jitsi/backups/
```

You should see: one file, a few kilobytes. Nothing goes offline while it runs.

If you do not: an archive of about 100 bytes means the `prosody` directory was empty, so step 7
never created the account. Go back and check the `find` output before you rely on this.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/jitsi
scp vps:/srv/jitsi/backups/*.tar.gz ~/backups/jitsi/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/jitsi/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a test account:

```bash
cd /srv/jitsi
docker compose down
sudo rm -rf /srv/jitsi/prosody
sudo tar -xzf /srv/jitsi/backups/jitsi-config-$(date +%F).tar.gz -C /srv/jitsi compose.yml .env prosody
sudo chown -R 1000:1000 /srv/jitsi/prosody
docker compose up -d
sleep 30
docker compose exec -T prosody find /var/lib/prosody -name 'moderator.dat'
```

You should see: the same path ending in `moderator.dat`, from a directory you deleted and
rebuilt.

If you do not: the `chown` line is the one people skip. Without it the directory belongs to root
and the Prosody container exits on startup rather than reading anything. The Caddy site block is
in that same archive at the top level, if `/etc/caddy` ever needs rebuilding too.

## 9. Updating later

New versions are listed at https://github.com/jitsi/docker-jitsi-meet/releases. Take the backup
first, then edit all four `image:` lines in /srv/jitsi/compose.yml to the new tag and its digest.
The four ship together and upstream does not support mixing them.

```bash
cd /srv/jitsi
docker compose pull
docker compose up -d
docker compose logs --tail 30 jicofo
```

You should see: Jicofo connecting to Prosody and finding a bridge, then no repeating restart.

If you do not: put the old tag and digest back on all four lines and run the same three commands.
Then re-run the four checks from step 7, and make one real call, because a page that loads
proves nothing about the media path.

## 10. What will probably go wrong

The install will look finished and the first call will have picture and no sound. I lost most of
an evening to that. The page comes through Caddy and the media does not: it goes to 10000/udp at
the bridge, using the address in `JVB_ADVERTISE_IPS`, and all three can be right on their own
while the call stays silent. Check in that order: `grep JVB_ADVERTISE_IPS /srv/jitsi/.env`
against `dig +short <DOMAIN>`, then `ss -lun | grep ':10000'`, then whether the hosting provider
runs a firewall of its own in front of the box, because several do and UDP is what gets
forgotten there.

## 11. Out of scope

- Do not install Jibri or configure recording. That is a separate container running a headless
  browser with a CPU budget of its own.
- Do not install Jigasi or set up dial-in numbers. That needs a SIP provider and a phone number,
  which is a purchase, not a configuration step.
- Do not enable `ENABLE_LETSENCRYPT`. Caddy holds the certificate for this hostname and a second
  ACME client on the same name collides with it.
- Do not switch `AUTH_TYPE` to `jwt` or add an identity provider. Internal accounts are the
  choice here.
