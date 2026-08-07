You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Collabora Online Development Edition 26.04.2.4.1 on that server, reachable at
https://<DOMAIN>, behind the existing Caddy with automatic TLS.

## 1. Preflight

Say this to the user before anything installs, because it decides whether they want this at
all. Collabora Online is the editing engine, not a place to keep files. On its own it edits
nothing: it opens, renders and saves documents another application hands it. Install it if the
user already runs Nextcloud, or another application with a Collabora connector, or is about to.
Otherwise this leaves them a correctly running server with nothing pointed at it.

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and it has to resolve for the other
application's own server as well as for every user's browser, because both talk to it.

This install needs 2048 MB of RAM available and 10 GB free on /srv. The image is about 470 MB
compressed and unpacks to several times that: it carries a whole office suite, every dictionary
and forty language packs. It publishes amd64 and arm64. Measure everything first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope: each open document is a separate process here, so a machine short of
memory fails on the third document, not at startup. If `dig +short` prints nothing, print that
and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/collabora /srv/collabora/backups
ls -la /srv/collabora
```

Assert: `ls -la` shows `backups` owned by the login user. There is no `data` directory and no
volume in step 4, because there is nothing here to keep: coolwsd builds its chroot jails and
its cache inside the container, and the upstream source turns fsync off there with the comment
that this is a state-less container. Two files are the whole install.

## 3. Secrets

One secret: the admin console password. Generate it on the server. Do not print it, do not
repeat it in your summary, and do not put it in any log line. Hex rather than base64, because
the user types this into a browser login box and hex has no characters that invite a typo.

```bash
umask 077
cat > /srv/collabora/.env <<EOF
username=admin
password=$(openssl rand -hex 24)
server_name=<DOMAIN>:443
aliasgroup1=
EOF
chmod 600 /srv/collabora/.env
umask 022
ls -l /srv/collabora/.env
```

Assert: the file exists with mode `-rw-------`. The four names are lowercase because coolwsd
reads them from the environment exactly as written. `username` and `password` become the admin
console credentials. `server_name` is what upstream documents for a server behind a reverse
proxy, so the editor stops guessing its own address from each request. `aliasgroup1` is
deliberately empty and step 7 fills it in: set at all, it switches the WOPI host list into
group mode, and with no group in it upstream's own log line reads
`all WOPI hosts will be denied`. That is the right way round, because the alternative default
lets the first application that connects claim the server, which is a race, not a policy. Tell
the user they can read the password with `sudo grep password /srv/collabora/.env`, and that
step 7 needs it.

## 4. compose.yml

```bash
cat > /srv/collabora/compose.yml <<'EOF'
# Collabora Online (CODE) · the deterministic fallback. Authored by
# caniselfhostit from the upstream sources, not copied from a repository:
#   image build ........ https://github.com/CollaboraOnline/online.mirror/blob/main/docker/from-packages/Dockerfile
#   env var handling ... https://github.com/CollaboraOnline/online.mirror/blob/main/wsd/COOLWSD.cpp
#   config reference ... https://github.com/CollaboraOnline/online.mirror/blob/main/coolwsd.xml.in
#
# One service, and no second one hiding inside it. No database, no message
# broker, and no volume: coolwsd builds its jails and its cache inside the
# container, and the source turns fsync off there with the comment that this is
# a state-less container. Your documents live in whichever application hands
# them to this server, not here.
#
# No healthcheck is declared here, on purpose. The 26.04 image is built on a
# distroless base with no shell, so a CMD-SHELL probe of ours would have
# nothing to run it. It ships `coolwsd --probe --use-env-vars` instead.
#
# Tag and digest read from the registry on 2026-08-07; amd64 and arm64 both
# published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  collabora:
    image: collabora/code:26.04.2.4.1@sha256:1f864ce3f0c49e867787b6dd303bd6ba989542d3023f6809df558eafd04c1b97
    container_name: collabora
    restart: unless-stopped
    env_file: /srv/collabora/.env
    environment:
      # Caddy terminates TLS on this box, so coolwsd serves plain http on its
      # own socket and is told the client reached it over https. With
      # ssl.enable false the self-signed certificate branch never runs at all.
      extra_params: "--o:ssl.enable=false --o:ssl.termination=true"
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8165.
      - "127.0.0.1:8165:9980"
    # SIGTERM has to leave coolwsd time to save and upload whatever is still
    # open in an editor. Upstream's own deployment allows the same 60 seconds.
    stop_grace_period: 60s
EOF
cd /srv/collabora && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. The container listens on plain http 9980 inside, published
only on 127.0.0.1:8165.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-collabora
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Collabora Online (CODE) · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/CollaboraOnline/online.mirror/blob/main/coolwsd.xml.in and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also server_name in .env, and it is the address you type into the application
# that uses this editor, so it must resolve for that application's server too.

<DOMAIN> {
	# The editors are tens of megabytes of JavaScript, served by coolwsd's
	# own file server rather than by anybody's CDN.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		-Server
	}

	# There is deliberately no X-Frame-Options and no frame-ancestors rule.
	# This whole product is an iframe: the application that owns the document
	# embeds the editor inside its own page, and a frame-blocking header
	# would leave the user looking at an empty box. The WOPI alias group in
	# .env, not the browser, decides which application may load a document.

	# reverse_proxy sets X-Forwarded-Proto and X-Forwarded-Host on the way
	# through, which is how coolwsd builds https URLs while speaking plain
	# http here, and it upgrades WebSocket connections with no extra
	# configuration. Every keystroke in a shared document is a WebSocket
	# frame. 8165 is the loopback port compose publishes; it is not open in
	# the firewall.
	reverse_proxy 127.0.0.1:8165
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-collabora, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it itself, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp
is HTTP/3. 8165 stays closed: it is bound to 127.0.0.1 and Caddy reaches it over loopback.
Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no
rule mentioning 8165.

## 7. Start and verify

The image is about 470 MB compressed, so the pull takes a few minutes, and the first start
scans the fonts and dictionaries before anything answers.

```bash
cd /srv/collabora
docker compose pull
docker compose up -d
for i in $(seq 1 30); do body=$(curl -sS https://<DOMAIN>/ || true); echo "$i $body"; [ "$body" = "OK" ] && break; sleep 10; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/hosting/discovery
curl -sS https://<DOMAIN>/hosting/discovery | grep -c 'wopi-discovery'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/browser/dist/admin/admin.html
```

Assert, all four, and print what you received for each. The loop ends printing `OK`, the plain
text body upstream's own readiness probe reads from `/`. The discovery request returns `200`.
The grep prints at least `1`. The admin console returns `401`, and that is the security assert:
the console is reachable and refuses anyone without the password from step 3. If any of the
four misses, stop, run `docker compose logs --tail 40 collabora`, and name the likely earlier
step. A `502` from Caddy in the first minutes is a container still starting; a `200` from the
admin console means .env never reached it and the console is open to the internet, which is a
stop-everything result.

The first screen is https://<DOMAIN>/hosting/discovery, an XML document whose opening element
reads `<wopi-discovery>`. The admin console at
https://<DOMAIN>/browser/dist/admin/admin.html asks for the username `admin` and the password
from step 3, and its dashboard heading then reads `Dashboard`. A running container is not
success.

STOP: tell the user nothing is editing a document yet, ask them for the address of the
application that will use this editor, and wait. Do not continue until they answer, or say they
will connect it later. If they answer, put that address in the alias group and restart:

```bash
sed -i 's|^aliasgroup1=$|aliasgroup1=https://cloud.example.com:443|' /srv/collabora/.env
cd /srv/collabora && docker compose up -d --force-recreate
sleep 20
grep -c '^aliasgroup1=https' /srv/collabora/.env
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/hosting/discovery
```

Replace `cloud.example.com` with the hostname the user gave, keeping the scheme and the `:443`.
Assert: the grep prints `1` and the discovery request prints `200`. Until that line is filled
in, this server denies every application that asks it for a document, which is a safe state
rather than a fault. Then hand the user these steps for Nextcloud: install the app named
`Collabora Online` from Apps, open `/settings/admin/richdocuments`, put `https://<DOMAIN>` in
the Collabora Online server field, and save. Nextcloud keeps that as the `wopi_url` setting and
fetches `/hosting/discovery` from it at once.

## 8. First backup and restore

One archive, and it is small, because there is no data here: the documents are in the other
application and the container keeps nothing. What is irreplaceable is the pair of files that
rebuild this service, the password and alias group in `.env` and the pinned digest in
`compose.yml`.

```bash
cd /srv/collabora
sudo tar -czf /srv/collabora/backups/collabora-config-$(date +%F).tar.gz -C /srv/collabora compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/collabora/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped. A backup on
the same disk as the data is not a backup, so run this from the user's machine, not the server:

```bash
mkdir -p ~/backups/collabora
scp vps:/srv/collabora/backups/*.tar.gz ~/backups/collabora/
```

To restore on a fresh box: recreate the directories as in step 2, untar the archive into
/srv/collabora, put the `Caddyfile` member at /etc/caddy with `<DOMAIN>` substituted, reload
Caddy, then `docker compose up -d` and re-run step 7's four asserts. Tell the user that is the
whole disaster plan, and that the member that matters is `.env`.

## 9. Updating later

New tags are listed at https://hub.docker.com/r/collabora/code/tags and what changed is at
https://www.collaboraonline.com/code-26-04-release-notes/. Back up first, then edit the image
line in /srv/collabora/compose.yml to the new tag and its digest:

```bash
cd /srv/collabora
docker compose pull
docker compose up -d
docker compose logs --tail 30 collabora
```

Watch that log until it settles, then re-run step 7's four asserts before calling the update
done. A major version changes the editor bundle the connected application loads, so open one
real document afterwards as well.

## 10. What will probably go wrong

The connection to Nextcloud will fail with a message that says nothing useful. I saved the
server address there, got `Collabora Online is not reachable`, and spent twenty minutes on
Caddy and DNS, both of which were fine. The editor was refusing on purpose: the alias group in
`.env` was still empty, so every WOPI host was denied, and that refusal happens deep enough
that the connector only reports a generic failure. If a connector cannot reach a server whose
`/hosting/discovery` answers `200` in your own browser, read
`docker compose logs --tail 40 collabora` and look for the alias-group line first.

## 11. Out of scope

- Do not set `DONT_GEN_SSL_CERT` or `cert_domain`. This install runs with `ssl.enable=false`
  behind Caddy, so the self-signed certificate branch never runs and neither variable has
  anything to do.
- Do not delete the `aliasgroup1` line to make a connector work. Removing it hands the server
  to whichever application connects first, and on a public hostname that is a race with
  strangers.
- Do not set `remoteconfigurl`. It points this server at a URL it fetches configuration from on
  every restart, which hands the install to whoever controls that URL.
- Do not install Nextcloud here. This prompt installs the editor; the application in front of
  it is a separate install with its own hostname.
