You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install LanguageTool 6.8 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS and a login box Caddy checks.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Every editor, plugin and add-on they point
here is configured with `https://<DOMAIN>/v2`, so that hostname goes into a settings box on
every device they write from.

LanguageTool is a Java service that loads dictionaries for every language it knows. It needs
2048 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and arm64. Measure
all five first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
caddy version
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope: the Java heap ceiling in step 4 is 1 GB, and the OOM killer arrives in
the middle of a check rather than at start-up. `caddy version` must print 2.8 or newer, which
is where the `basic_auth` directive step 5 uses was renamed from `basicauth`. If `dig +short`
prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/languagetool /srv/languagetool/backups
ls -la /srv/languagetool
```

Assert: `ls -la` shows `backups` owned by the login user. There is no `data` directory and
there will not be one. LanguageTool reads its rules and dictionaries out of the image and
keeps nothing between requests: text arrives, is checked, is answered, and is dropped. Step 8
depends on that.

## 3. Secrets

One secret: the password on the login box in front of the API. Generate it here, print it
nowhere, keep it out of your summary and out of any log line. It carries more weight than its
size suggests, because the LanguageTool HTTP server has no accounts, no API key and no login
of its own, and the image starts it with `--public` and `--allow-origin '*'`. Whatever can
reach the container gets an answer.

```bash
umask 077
openssl rand -hex 24 > /srv/languagetool/api-password
printf 'machine <DOMAIN> login languagetool password %s\n' "$(cat /srv/languagetool/api-password)" > /srv/languagetool/.netrc
chmod 600 /srv/languagetool/api-password /srv/languagetool/.netrc
umask 022
ls -l /srv/languagetool/api-password /srv/languagetool/.netrc
```

Assert: both files exist with mode `-rw-------`. Hex rather than base64, because this value
gets typed into settings boxes on other machines and hex has nothing a keyboard layout can
ruin. The `.netrc` is the same credential in the form curl reads from a file, which is how
step 7 signs in without putting it in the process list. The username is `languagetool`.

## 4. compose.yml

```bash
cat > /srv/languagetool/compose.yml <<'EOF'
# LanguageTool · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   http server ........ https://dev.languagetool.org/http-server
#   upstream readme .... https://github.com/languagetool-org/languagetool/blob/v6.8/README.md
#   image readme ....... https://github.com/Erikvl87/docker-languagetool/blob/v6.8/README.md
#   image dockerfile ... https://github.com/Erikvl87/docker-languagetool/blob/v6.8/Dockerfile
#
# One service and no database. LanguageTool loads its rules and dictionaries out
# of the image and keeps nothing between requests: no volume, nothing to
# migrate, nothing on disk to lose.
#
# The LanguageTool project publishes no Docker image. Its README names three
# community-contributed Dockerfiles and this install uses one of them,
# Erikvl87/docker-languagetool, LGPL-2.1 like LanguageTool itself. That
# Dockerfile clones the upstream v6.8 tag and builds it with Maven, so the code
# is upstream's and the packaging is somebody else's. Tag and digest were read
# from Docker Hub on 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  languagetool:
    image: erikvl87/languagetool:6.8@sha256:ef8fa12cbd485166c9ceeb7139d76d56d07707a624da6bb1fc1fbb5411750527
    container_name: languagetool
    restart: unless-stopped
    environment:
      # The image's start script reads these two and defaults to 256m and 512m.
      # 512m runs out of room once several languages load, and the RAM floor in
      # the install accounts for the larger ceiling.
      Java_Xms: 512m
      Java_Xmx: 1g
      # Every langtool_* variable becomes one line in the server's
      # config.properties. This one caps a single request so one enormous paste
      # cannot hold the whole JVM. 40000 characters is a long document.
      langtool_maxTextLength: "40000"
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8149. The
      # image starts the server with --public and --allow-origin '*', so it
      # answers whoever reaches it. Nothing else may.
      - "127.0.0.1:8149:8010"
    # The image ships a HEALTHCHECK that posts a sentence to /v2/check, so
    # `docker compose ps` reports healthy or unhealthy without help from here.
EOF
cd /srv/languagetool && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. There is no `env_file` line because no secret enters this
container: the image's start script copies every `langtool_` variable into a config file and
prints that file to the container log, where `docker compose logs` reads it.

## 5. Caddy and TLS

Two files. First the credential Caddy checks, a bcrypt hash of the password step 3 generated,
written where the caddy user can read it and nowhere else:

```bash
umask 077
caddy hash-password < /srv/languagetool/api-password > /srv/languagetool/auth.hash
printf 'basic_auth {\n\tlanguagetool %s\n}\n' "$(cat /srv/languagetool/auth.hash)" > /srv/languagetool/auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/languagetool/auth.conf /etc/caddy/languagetool-auth.conf
rm -f /srv/languagetool/auth.hash /srv/languagetool/auth.conf
sudo grep -c basic_auth /etc/caddy/languagetool-auth.conf
```

Assert: that prints `1`. Reading the password from a file rather than as an argument keeps it
out of the process list.

Then the site block, appended to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced
by the real hostname. Copy the file first: a syntax error takes down every other site here.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-languagetool
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# LanguageTool · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://dev.languagetool.org/http-server,
# https://caddyserver.com/docs/automatic-https and
# https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. The LanguageTool
# HTTP server has no accounts and no API key of its own, and the image starts it
# with --public and --allow-origin '*', so it answers whoever reaches it. This
# block is the only door on the install: Caddy checks one credential before a
# byte reaches the container. Needs Caddy 2.8, where basicauth became basic_auth.

<DOMAIN> {
	# JSON in, JSON out. A check response for a long document compresses well,
	# and there is no HTML here to frame or to sniff.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# The credential is not in this file, because this file is published. The
	# install writes /etc/caddy/languagetool-auth.conf with one basic_auth
	# block: a username and a bcrypt hash of the password generated on the
	# server. Mode 640, owned by root, readable by the caddy group.
	import /etc/caddy/languagetool-auth.conf

	# 8149 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8149
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-languagetool, reload, and report what it objected to. Caddy
requests the certificate on the first request to the hostname and renews it on its own.

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
443/udp is HTTP/3. 8149 stays closed because it is bound to 127.0.0.1, and opening it would
put an unauthenticated grammar API on the public internet, a free CPU endpoint for whoever
finds it first. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8149.

## 7. Start and verify

The first start pulls about 430 MB and then loads dictionaries, so the loop below is patient.

```bash
cd /srv/languagetool
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8149/v2/languages); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://127.0.0.1:8149/v2/languages | head -c 200
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/v2/languages
curl -sS --netrc-file /srv/languagetool/.netrc -d "language=en-US" -d "text=I has a apple." https://<DOMAIN>/v2/check
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The
languages listing contains `"longCode":"en-US"`. The unauthenticated call to the public
hostname prints `401`, Caddy refusing a request with no credential, and that is the security
assert here: an open LanguageTool on a public name is a free compute endpoint. The last
command returns JSON containing `"name":"LanguageTool"` and a match whose rule is
`"id":"EN_A_VS_AN"`, the engine finding the error in `a apple`. If any of the four misses,
stop, run `docker compose logs --tail 40 languagetool`, and name the likely earlier step: a
`502` from the public call means the container is not up yet, a Java heap message in the log
means step 1 ran on a box under the floor. A running container is not success.

There is no first screen. LanguageTool has no web interface, and https://<DOMAIN>/ answers
`404` with the body `Not found` once past the login box, because the server only handles paths
under `/v2/`. What a human puts into an editor or add-on is `https://<DOMAIN>/v2`, with the
username `languagetool` and the password below.

STOP: tell the user to read their password with
`sudo cat /srv/languagetool/api-password`, put it in their password manager, and wait.
Do not continue until they confirm. It is the only credential this install has, and the one
thing between the public internet and a machine that will check grammar for anybody.

## 8. First backup and restore

One archive, smaller than any other backup on this site because there is no user data to lose:
the credential and the four files that rebuild the service around it. Nothing is stopped,
because nothing is being written:

```bash
cd /srv/languagetool
sudo tar -czf /srv/languagetool/backups/languagetool-$(date +%F).tar.gz -C /srv/languagetool compose.yml api-password .netrc -C /etc/caddy Caddyfile languagetool-auth.conf
ls -lh /srv/languagetool/backups/
```

Assert: the archive exists and is non-empty. Print its size. It carries the password in two
forms, so treat it as the secret it is. A backup on the same disk is not a backup, so run this
from the user's machine:

```bash
mkdir -p ~/backups/languagetool
scp vps:/srv/languagetool/backups/*.tar.gz ~/backups/languagetool/
```

To restore on a fresh box: untar the archive into /srv/languagetool, move the two Caddy files
back to /etc/caddy, `sudo systemctl reload caddy`, then `docker compose up -d` and re-run
step 7's four asserts. Tell the user the honest version: losing this archive costs the
password and ten minutes, not their writing, which was never stored here.

## 9. Updating later

LanguageTool tags releases at https://github.com/languagetool-org/languagetool/tags and the
community image that carries them is tagged at
https://hub.docker.com/r/erikvl87/languagetool/tags. Check the second: the packaging is a
separate project, so a new upstream tag is not installable until an image is built for it.
Take the backup first, then edit the image line in /srv/languagetool/compose.yml to the new
tag and digest:

```bash
cd /srv/languagetool
docker compose pull
docker compose up -d
docker compose logs --tail 30 languagetool
```

Watch that log until the server reports it is listening, then re-run step 7's four asserts
before calling the update done.

## 10. What will probably go wrong

The browser add-on. I put `https://<DOMAIN>/v2` into the LanguageTool extension's own server
box, waited for my writing to start getting checked, and got nothing: no error, no underlines,
silence. The add-on sends a URL and nothing else, so it never answers the password prompt
Caddy is holding out, and a check that failed looks exactly like a sentence with no mistakes
in it. That is the trade this path makes, better said now than discovered in an hour. What
works here is every tool where the user controls the request: curl, scripts, CI prose checks,
and an `ssh -N -L 8149:127.0.0.1:8149 vps` tunnel from their laptop, which puts the server on
their own `http://localhost:8149/v2` where the add-on is content. For the add-on with no
tunnel, the local path on this page is the honest answer.

## 11. Out of scope

- Do not remove the `import /etc/caddy/languagetool-auth.conf` line and do not publish 8149.
  That line is the whole access control on this install.
- Do not download the n-gram data. It is roughly 8 GB per language, exists for four languages,
  and buys better detection of confusion pairs like `their` and `there`. This install trades
  that for a service that fits on a small VPS.
- Do not configure a LanguageTool Premium account and do not set any `langtool_premium`
  variable. Premium is a paid service of the LanguageTool company, the open-source server
  refuses those settings, and the rules it sells are not in this image.
- Do not add a second container for a web interface. LanguageTool ships none; the client is
  whatever the user already writes in.
