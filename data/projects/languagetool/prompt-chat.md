This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing LanguageTool 6.8 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1, because it decides whether you want this install at all. The
LanguageTool HTTP server has no accounts, no API key and no login of its own, and the image
starts it with `--public` and `--allow-origin '*'`. On a public hostname that is a free CPU
endpoint for whoever finds it, so step 5 puts a password on the door. That password is
checked by Caddy, and the LanguageTool browser add-on cannot answer it: see step 10 before
you decide this is the path you want.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
caddy version
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `5` G free, `amd64` or `arm64`, a
Caddy version of `2.8` or newer, and your server's IP on the last line.

If you do not: a Caddy older than 2.8 does not know the `basic_auth` directive step 5 uses,
because that release renamed `basicauth`, so upgrade Caddy before going on. An empty last line
means the A record does not exist yet: add it, wait a minute, run `dig +short <DOMAIN>` again,
because Caddy cannot get a certificate for a name that does not resolve and failed attempts
count against a rate limit you cannot see. Under 2048 MB of RAM is not a warning to work
around: the Java heap ceiling in step 4 is 1 GB, and the OOM killer arrives in the middle of a
check rather than at start-up, which looks like random failure and is not.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/languagetool /srv/languagetool/backups
ls -la /srv/languagetool
```

You should see: `backups`, owned by you, and nothing else.

If you do not: there is deliberately no `data` directory here. LanguageTool reads its rules
and dictionaries out of the image and keeps nothing between requests, so text arrives, is
checked, is answered, and is dropped. If you were expecting a folder your writing accumulates
in, there is not one, and that is the best thing about this install.

## 3. Secrets

One secret: the password on the login box in front of the API. It is generated here, on the
server, and goes straight into two files only you can read.

```bash
umask 077
openssl rand -hex 24 > /srv/languagetool/api-password
printf 'machine <DOMAIN> login languagetool password %s\n' "$(cat /srv/languagetool/api-password)" > /srv/languagetool/.netrc
chmod 600 /srv/languagetool/api-password /srv/languagetool/.netrc
umask 022
ls -l /srv/languagetool/api-password /srv/languagetool/.netrc
```

You should see: two files, both mode `-rw-------`, your own username twice on each line.
Replace `<DOMAIN>` on the `printf` line with your real hostname before you paste. Read the
password once with `sudo cat /srv/languagetool/api-password` and put it in your password
manager: it is the only credential this install has, and every tool you point at this server
will ask for it. The username is `languagetool`.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately into different shells. Run
`chmod 600 /srv/languagetool/api-password /srv/languagetool/.netrc` and carry on. If the files
already existed from an earlier attempt, this block has replaced the password, and step 5 has
to be run again afterwards or Caddy will keep checking the old one.

Do not paste either of those files, the password itself, or any output containing it into this
chat window. The `.netrc` exists so that curl can read the credential from a file instead of
from a command line, which keeps it out of the process list and out of your shell history;
pasting it into a chat undoes all of that at once.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page
and your terminal. Run `rm /srv/languagetool/compose.yml` and paste again in one go. There is
no `env_file` line and that is deliberate: no secret ever enters this container, because the
image's start script copies every `langtool_` variable into a config file and then prints that
file to the container log, where anyone who can run `docker compose logs` would read it.

## 5. Caddy and TLS

Two files. First the credential Caddy checks, which is a bcrypt hash of the password step 3
generated, written where the caddy user can read it and nowhere else.

```bash
umask 077
caddy hash-password < /srv/languagetool/api-password > /srv/languagetool/auth.hash
printf 'basic_auth {\n\tlanguagetool %s\n}\n' "$(cat /srv/languagetool/auth.hash)" > /srv/languagetool/auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/languagetool/auth.conf /etc/caddy/languagetool-auth.conf
rm -f /srv/languagetool/auth.hash /srv/languagetool/auth.conf
sudo grep -c basic_auth /etc/caddy/languagetool-auth.conf
```

You should see: `1`.

If you do not: `unknown command hash-password` means your Caddy predates 2.8 and step 1 was
skipped. `chown: invalid group: caddy` means Caddy was installed some way other than its own
package, so find the group its service runs as with `systemctl show -p User -p Group caddy`
and use that name instead. The password goes into `hash-password` from a file rather than as
an argument on purpose: an argument is visible in the process list to every user on the box.

Now the site block. Replace `<DOMAIN>` with your hostname before you paste. The first line
takes a copy, because a syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-languagetool /etc/caddy/Caddyfile`,
reload, and paste again. `unrecognized directive: basic_auth` inside the imported file is the
same Caddy version problem as above. Caddy requests the certificate on the first request to
the hostname and renews it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8149`.

If you do not: delete anything for 8149 with `sudo ufw delete allow 8149`. That port is bound
to 127.0.0.1 by the compose file, and opening it would route around the login box you built in
step 5, leaving an unauthenticated grammar API on the public internet. 80/tcp redirects to
HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which
Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero left this
firewall enabled, so something turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first start pulls about 430 MB and then loads dictionaries, so the loop is patient.

```bash
cd /srv/languagetool
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8149/v2/languages); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://127.0.0.1:8149/v2/languages | head -c 200
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/v2/languages
curl -sS --netrc-file /srv/languagetool/.netrc -d "language=en-US" -d "text=I has a apple." https://<DOMAIN>/v2/check
```

You should see, in order: the loop reaching `200`, a JSON list containing
`"longCode":"en-US"`, then `401`, then a JSON object containing `"name":"LanguageTool"` and a
match whose rule is `"id":"EN_A_VS_AN"`.

If you do not: the `401` is the one worth understanding. It means Caddy is refusing a request
that carried no credential, which is exactly what should happen, so seeing it is good news and
seeing `200` in its place means the `import` line is not doing its job and your server is open.
A `502` from the same command means the container is not up yet, so watch the loop again. A
Java heap message in `docker compose logs --tail 40 languagetool` means step 1 was run on a box
under the floor. A running container is not success.

There is no first screen and no web interface. https://<DOMAIN>/ answers `404` with the body
`Not found` once you are past the login box, because the server only handles paths under
`/v2/`. What you put into an editor or add-on is `https://<DOMAIN>/v2`, with the username
`languagetool` and the password from step 3.

## 8. First backup and restore

One archive, smaller than any other backup on this site because there is no user data to lose:
the credential and the four files that rebuild the service around it. Nothing goes offline,
because nothing is being written.

```bash
cd /srv/languagetool
sudo tar -czf /srv/languagetool/backups/languagetool-$(date +%F).tar.gz -C /srv/languagetool compose.yml api-password .netrc -C /etc/caddy Caddyfile languagetool-auth.conf
ls -lh /srv/languagetool/backups/
```

You should see: one file, a few kilobytes.

If you do not: `tar: Caddyfile: Cannot stat` means the second `-C` did not take, so check that
you pasted the whole line. An archive of about 100 bytes means every named file was missing,
which means one of the earlier steps did not run.

That archive contains the password in two forms, so treat it as the secret it is. A backup on
the same disk as the data is not a backup. Run this one on your own machine, not the server:

```bash
mkdir -p ~/backups/languagetool
scp vps:/srv/languagetool/backups/*.tar.gz ~/backups/languagetool/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/languagetool/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while nothing is at stake:

```bash
cd /srv/languagetool
docker compose down
rm -f /srv/languagetool/compose.yml
tar -xzf /srv/languagetool/backups/languagetool-$(date +%F).tar.gz -C /srv/languagetool compose.yml
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/v2/languages
```

You should see: `401` again from the last command, which means Caddy is up, the site block
survived, and the container came back from a compose file that came out of the archive.

If you do not: `tar: compose.yml: Not found in archive` means the archive was written before
step 4, so take it again. The honest version of this whole block is worth saying out loud:
losing this archive costs you the password and ten minutes, not your writing, because your
writing was never stored here.

## 9. Updating later

LanguageTool tags releases at https://github.com/languagetool-org/languagetool/tags and the
community image that carries them is tagged at
https://hub.docker.com/r/erikvl87/languagetool/tags. Check the second: the packaging is a
separate project, so a new upstream tag is not installable until an image is built for it.
Take the backup first, then edit the `image:` line in /srv/languagetool/compose.yml to the new
tag and digest.

```bash
cd /srv/languagetool
docker compose pull
docker compose up -d
docker compose logs --tail 30 languagetool
```

You should see: the server reporting it is listening, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
step 7's four asserts before you call the update done, including the grammar check, because a
server that answers on `/v2/languages` can still be failing to load a dictionary it needs.

## 10. What will probably go wrong

The browser add-on. I put `https://<DOMAIN>/v2` into the LanguageTool extension's own server
box, waited for my writing to start getting checked, and got nothing: no error, no underlines,
silence. The add-on sends a URL and nothing else, so it never answers the password prompt
Caddy is holding out, and a check that failed looks exactly like a sentence with no mistakes
in it. That is the trade this path makes, better said now than discovered in an hour. What
works here is every tool where you control the request: curl, scripts, CI prose checks, and an
`ssh -N -L 8149:127.0.0.1:8149 vps` tunnel from your laptop, which puts the server on your own
`http://localhost:8149/v2` where the add-on is content. For the add-on with no tunnel, the
local path on this page is the honest answer.

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
  whatever you already write in.
