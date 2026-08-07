This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Collabora Online Development Edition 26.04.2.4.1 on a VPS where Prompt Zero
is done: `ssh vps` works, Docker and Caddy are installed, the firewall is default-deny. Run
everything over `ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname
whose A record already points at the box.

Read this before step 1, because it decides whether you want the install at all. Collabora
Online is the editing engine, not a place to keep files. On its own it edits nothing: it opens,
renders and saves documents that another application hands to it. It is worth installing if you
already run Nextcloud, or another application with a Collabora connector, or are about to. If
you have none of those, what you will have at the end is a correctly running server with
nothing pointed at it.

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
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that
does not resolve and failed attempts count against a rate limit you cannot see. Under 2048 MB
of memory, resize the box before you go on: every open document here is a separate process, so
a machine that is short of memory does not fail at startup, it fails on the third document,
which looks like a bug in the editor rather than a bug in the shopping. That hostname also has
to resolve for the other application's own server, not only for your browser, so a split-horizon
DNS setup that answers differently inside your network will bite you at step 7.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/collabora /srv/collabora/backups
ls -la /srv/collabora
```

You should see: one directory, `backups`, owned by you.

If you do not: `Permission denied` means you are not in the sudoers group, which Prompt Zero
set up. There is no `data` directory here and no volume in step 4, because there is nothing to
keep: coolwsd builds its chroot jails and its cache inside the container, and the upstream
source turns fsync off there with the comment that this is a state-less container. Two files
under this directory are the whole install.

## 3. Secrets

One secret: the admin console password. It is generated here, on the server, straight into a
file only you can read. Hex rather than base64, because you type this into a browser login box
and hex has no characters that invite a typo.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the third line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/collabora/.env` and
carry on. If the file already existed from an earlier attempt, this block has now replaced the
password, and the admin console will only accept the new one.

Do not paste that file, the password, or any output containing it into this chat window. Read
it once at step 7 with `sudo grep password /srv/collabora/.env`, put it in your password
manager, and keep it out of anything you are typing to a chatbot.

Those four names are lowercase because coolwsd reads them from the environment exactly as
written. `username` and `password` become the admin console credentials. `server_name` is what
upstream documents for a server behind a reverse proxy, so the editor stops guessing its own
address from each request. `aliasgroup1` is deliberately empty and step 7 fills it in: set at
all, it switches the WOPI host list into group mode, and with no group in it upstream's own log
line for that state reads `all WOPI hosts will be denied`. That is the right way round. The
alternative default lets the first application that connects claim your server, which is a
race, not a policy.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/collabora/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/collabora/compose.yml` and paste again in one go. The container listens on plain
http port 9980 inside and is published only on 127.0.0.1:8165, because Caddy on the host
terminates TLS. There is no volume in that file and that is not an omission: your documents
live in the application that hands them over, and this container keeps nothing of its own.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-collabora /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and
not the other. Caddy requests the certificate on the first request and renews it on its own, so
there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8165`.

If you do not: delete anything for `8165` with `sudo ufw delete allow 8165`. That port is bound
to 127.0.0.1 by the compose file, so Caddy reaches it over loopback and nothing else can reach
it at all. 80/tcp is there to redirect to HTTPS and to answer the ACME challenge, 443/tcp is
the only way in, and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a
different problem: Prompt Zero left this firewall enabled, so something has turned it off
since, and `sudo ufw enable` puts it back before you go any further.

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

You should see, in order: the loop reaching `OK`, then `200`, then a count of at least `1`,
then `401`.

If you do not: the `401` is the one worth understanding. The admin console is reachable and
refusing a request that carries no credentials, which means the password from step 3 reached
the container and is in force. A `200` in its place is the opposite result and a
stop-everything one: it means the console is open to anyone who finds your hostname. Check that
`.env` reached the container with `docker compose config`. If the loop never reaches `OK`, give
it the full thirty attempts before doing anything: a `502` from Caddy in the first few minutes
is a container that is still starting, not a broken install. After that,
`docker compose logs --tail 40 collabora` is the place to look.

The first screen is https://<DOMAIN>/hosting/discovery, an XML document whose opening element
reads `<wopi-discovery>`. That is the file every connector fetches first. The admin console at
https://<DOMAIN>/browser/dist/admin/admin.html asks for the username `admin` and the password
from step 3, and its dashboard heading then reads `Dashboard`. A running container is not
success; those four asserts are.

Now read the password once and put it in your password manager:

```bash
sudo grep password /srv/collabora/.env
```

You should see: one line, the variable name followed by 48 characters of hex. Do not paste that
line into this chat.

Nothing is editing a document yet, and one line still has to be filled in. Decide the address
of the application that will use this editor, then:

```bash
sed -i 's|^aliasgroup1=$|aliasgroup1=https://cloud.example.com:443|' /srv/collabora/.env
cd /srv/collabora && docker compose up -d --force-recreate
sleep 20
grep -c '^aliasgroup1=https' /srv/collabora/.env
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/hosting/discovery
```

You should see: `1`, then `200`. Replace `cloud.example.com` with your own hostname, keeping
the scheme and the `:443`.

If you do not: a `0` from the grep means the pattern did not match, usually because the line
already had a value from an earlier attempt; open the file and set it by hand. Until that line
holds a real address this server denies every application that asks it for a document, which is
a safe state to be left in rather than a fault. To connect Nextcloud: install the app named
`Collabora Online` from Apps, open the admin page at `/settings/admin/richdocuments`, put
`https://<DOMAIN>` in the Collabora Online server field, and save. Nextcloud keeps that as the
`wopi_url` setting and fetches `/hosting/discovery` from it straight away.

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

You should see: one file, a few kilobytes. Nothing goes offline.

If you do not: run `tar -tzf` on the finished archive to list what is inside it. `compose.yml`,
`.env` and `Caddyfile` should all be there, and if `Caddyfile` is missing then tar never
reached the second `-C` because the first path was wrong.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/collabora
scp vps:/srv/collabora/backups/*.tar.gz ~/backups/collabora/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/collabora/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while nothing is at stake:

```bash
cd /srv/collabora
docker compose down
sudo rm -f /srv/collabora/compose.yml /srv/collabora/.env
sudo tar -xzf /srv/collabora/backups/collabora-config-$(date +%F).tar.gz -C /srv/collabora --exclude Caddyfile
docker compose up -d
for i in $(seq 1 30); do body=$(curl -sS https://<DOMAIN>/ || true); echo "$i $body"; [ "$body" = "OK" ] && break; sleep 10; done
```

You should see: the loop reaching `OK` again, which means two deleted files came back and the
service came back with them.

If you do not: the archive also contains a `Caddyfile` member, and `--exclude Caddyfile` keeps
it out of /srv/collabora where it would do nothing. On a genuinely fresh box you would put that
member at /etc/caddy/Caddyfile instead, with `<DOMAIN>` already replaced, and reload Caddy.
That is the whole disaster plan: two files back in place and one `docker compose up -d`. The
member that matters is `.env`, because losing it means a new password and a connector that has
to be told about it.

## 9. Updating later

New tags are listed at https://hub.docker.com/r/collabora/code/tags and what changed is at
https://www.collaboraonline.com/code-26-04-release-notes/. Take the backup first, then edit the
`image:` line in /srv/collabora/compose.yml to the new tag and its digest.

```bash
cd /srv/collabora
docker compose pull
docker compose up -d
docker compose logs --tail 30 collabora
```

You should see: the start-up sequence, then no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
four asserts from step 7 before you call the update done, and open one real document in the
connected application as well, because a major version changes the editor bundle that
application loads and a server that answers `OK` can still be serving a bundle the connector
does not understand.

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
