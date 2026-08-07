This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Vane v1.12.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Two facts before step 1. The project was called Perplexica until it was renamed Vane, so the
repository, the images and the docs all say Vane now, and 1.12.2 exists only under that name.
And Vane is an interface, not a model: it searches with SearXNG and writes the answer with a
provider key you supply on its setup screen, metered per token by Anthropic, OpenAI or Google
and billed to you. Nothing here caps that.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
caddy version
```

You should see: at least `2048` MB available, at least `5` G free, `amd64` or `arm64`, your
server's IP, and a Caddy version of `2.8` or newer.

If you do not: an empty `dig` line means the A record does not exist yet. Add it, wait a
minute, run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname
that does not resolve and failed attempts count against a rate limit you cannot see. A Caddy
older than 2.8 is a hard stop: step 5 uses the `basic_auth` directive, which 2.8 renamed from
`basicauth`, and on an older build the config will not validate. Upgrade Caddy first.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/perplexica /srv/perplexica/backups
sudo install -d -m 700 /srv/perplexica/data /srv/perplexica/uploads
sudo install -d -m 755 /srv/perplexica/searxng
ls -la /srv/perplexica
```

You should see: `backups` owned by you, `data` and `uploads` at `drwx------` owned by root, and
`searxng` at `drwxr-xr-x`.

If you do not: leave `data` and `uploads` owned by root on purpose. The Vane image declares no
unprivileged user and writes as root, so a directory you have chowned to yourself is a
permission error at first start. `searxng` is deliberately readable, because the one file in it
holds no secret.

## 3. Secrets

Two secrets, both generated here on the server and never typed by you. The first replaces a
SearXNG session key whose value is published in the settings file every copy of the bundled
image carries. The second is the password on the login box in step 5.

```bash
umask 077
cat > /srv/perplexica/.env <<EOF
SEARXNG_SECRET=$(openssl rand -hex 32)
EOF
openssl rand -hex 24 > /srv/perplexica/browser-login
chmod 600 /srv/perplexica/.env /srv/perplexica/browser-login
umask 022
ls -l /srv/perplexica/.env /srv/perplexica/browser-login
```

You should see: two files at mode `-rw-------`, your own username twice on each line. Read the
login password once with `sudo cat /srv/perplexica/browser-login` and put it in your password
manager: with the username `vane` it is how you get into this install.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run
`chmod 600 /srv/perplexica/.env /srv/perplexica/browser-login` and carry on.

Do not paste either file, either value, or any output containing them into this chat window.
Neither of them is your provider API key: that one you type into Vane's own setup screen in
step 7, and it never passes through here either.

## 4. Config and compose.yml

SearXNG answers in HTML only until its settings say otherwise, and Vane asks for JSON. Paste
this whole block at once, including the last line.

```bash
sudo tee /srv/perplexica/searxng/settings.yml >/dev/null <<'EOF'
# SearXNG · the search backend here. Authored by caniselfhostit from
# https://docs.searxng.org/admin/settings/ and Vane's own install notes.
# No secret_key here. SEARXNG_SECRET in compose.yml overwrites it with the
# value generated in step 3, so nothing in this file is confidential.
use_default_settings: true

search:
  # SearXNG answers 403 to a format it was not told to serve, and ships html
  # only, so without json every Vane search fails.
  formats:
    - html
    - json

server:
  # The shipped default, stated so an upstream change cannot turn it on.
  limiter: false

engines:
  - name: wolframalpha
    disabled: false
EOF
sudo chmod 644 /srv/perplexica/searxng/settings.yml
```

You should see: no output at all, which is what `>/dev/null` is for.

If you do not: an error mentioning `No such file or directory` means step 2 did not run. Go
back and create the tree first.

Now the compose file. Paste the whole block at once, including the last two lines.

```bash
cat > /srv/perplexica/compose.yml <<'EOF'
# Vane · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   install and images . https://github.com/ItzCrazyKns/Vane/blob/v1.12.2/README.md
#   searxng in docker .. https://docs.searxng.org/admin/installation-docker.html
#   searxng settings ... https://docs.searxng.org/admin/settings/settings_server.html
#
# Perplexica was renamed Vane; 1.12.2 exists only under the new name. Two
# services: the app, and the SearXNG it searches through. The slim image has no
# search engine in it; the full one bundles SearXNG and ships a fixed
# secret_key every copy of it shares. Apart, the key is generated and SearXNG
# updates on its own schedule. No provider API key is here: Vane asks for one
# on its setup screen and writes it to data/config.json, so that file is as
# sensitive as a password. Digests read 2026-08-06, both images multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  searxng:
    image: searxng/searxng:2026.8.4-c63835bd2@sha256:f4c8e59de166ed71f6380c0847c312ca51f0d41996e31d0559163b6b09ecde52
    container_name: vane-searxng
    restart: unless-stopped
    environment:
      # Overwrites server.secret_key in settings.yml with the generated value.
      SEARXNG_SECRET: ${SEARXNG_SECRET}
    volumes:
      # Read only. The image owns /etc/searxng, so nothing is chowned here.
      - /srv/perplexica/searxng/settings.yml:/etc/searxng/settings.yml:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/healthz"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 8080 is reachable only from the other container.

  vane:
    image: itzcrazykns1337/vane:slim-v1.12.2@sha256:d2878cf9c91962aa3fc053b59bc9b89adcbdcaeb7ee36b54906e853464b2c190
    container_name: vane
    restart: unless-stopped
    environment:
      # Vane appends /search?format=json to this address on every query.
      SEARXNG_API_URL: http://searxng:8080
    volumes:
      # config.json, the SQLite database of searches, and uploaded files.
      - /srv/perplexica/data:/home/vane/data
      - /srv/perplexica/uploads:/home/vane/uploads
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8148.
      - "127.0.0.1:8148:3000"
    depends_on:
      searxng:
        condition: service_healthy
EOF
cd /srv/perplexica && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal, so run `rm /srv/perplexica/compose.yml` and paste again in one go. A warning
about `SEARXNG_SECRET` being unset means step 3's `.env` is missing or is not in
/srv/perplexica, which is where compose looks for it.

## 5. Caddy and TLS

Two files. First the credential Caddy checks: a bcrypt hash of the password from step 3.
Reading it from a file rather than typing it as an argument keeps it off the process list.

```bash
umask 077
caddy hash-password < /srv/perplexica/browser-login > /srv/perplexica/vane-auth.hash
printf 'basic_auth {\n\tvane %s\n}\n' "$(cat /srv/perplexica/vane-auth.hash)" > /srv/perplexica/vane-auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/perplexica/vane-auth.conf /etc/caddy/vane-auth.conf
rm -f /srv/perplexica/vane-auth.hash /srv/perplexica/vane-auth.conf
sudo grep -c basic_auth /etc/caddy/vane-auth.conf
```

You should see: `1`.

If you do not: `chown: invalid group: 'caddy'` means Caddy was installed some other way and its
service user has a different name. Run `systemctl show -p User caddy` to find it and use that
name in the `install` line. A `0` means the printf did not run, usually because the hash file
was empty; check that `sudo cat /srv/perplexica/browser-login` prints 48 hex characters.

Now the site block. Replace `<DOMAIN>` with your hostname before you paste. The first line takes
a copy, because a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-perplexica
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Vane · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/ItzCrazyKns/Vane/blob/v1.12.2/README.md,
# https://caddyserver.com/docs/automatic-https and
# https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Vane has no
# sign-in of its own, so this block is the login: the setup screen behind it
# holds the API key every answer is billed to. Needs Caddy 2.8 or newer, where
# the directive is spelled basic_auth.

<DOMAIN> {
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# The credential is not in this file, because this file is published. The
	# install writes /etc/caddy/vane-auth.conf: one basic_auth block with the
	# username `vane` and a bcrypt hash of the generated password.
	import /etc/caddy/vane-auth.conf

	# 8148 is the loopback port compose publishes on this host. Not a container
	# port, and not open in the firewall.
	reverse_proxy 127.0.0.1:8148 {
		# Answers arrive one piece at a time: no `encode` line anywhere here,
		# and a proxy that flushes every write instead of buffering them.
		flush_interval -1
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-perplexica /etc/caddy/Caddyfile`,
reload, and paste again. `unrecognized directive: basic_auth` inside the imported file means
your Caddy predates 2.8, which step 1 was checking for.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8148` or `8080`.

If you do not: delete anything for `8148` with `sudo ufw delete allow 8148`. That port is bound
to 127.0.0.1 by the compose file, and opening it would let anyone reach Vane without passing
the login box you built in step 5. SearXNG never publishes a host port at all. `Status:
inactive` is a different problem: Prompt Zero left this firewall on, so something has turned it
off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The Vane image is around a gigabyte, so the first pull takes a few minutes.

```bash
cd /srv/perplexica
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8148/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://127.0.0.1:8148/api/config | grep -oE '"setupComplete":[a-z]*|"searxngURL":"[^"]*"'
curl -sS http://127.0.0.1:8148/ | grep -c 'Welcome to'
docker compose exec -T searxng wget -qO- 'http://127.0.0.1:8080/search?q=self+hosting&format=json' | grep -c '"query"'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see, in order: the loop reaching `200`; JSON containing `"setupComplete":false` and
`"searxngURL":"http://searxng:8080"`; then `1`; then `1`; then `401`.

If you do not: the `401` is the one worth understanding. It means Caddy is up and refusing a
request with no credentials, which is exactly what you want on a public hostname, so seeing it
is good news. A `200` in its place means the `import` line is not being read and your install
is open to the internet: fix that before anything else. If the SearXNG grep prints `0`, run the
same wget without the grep; a `403` body means /srv/perplexica/searxng/settings.yml was not
picked up, so check the mount path in step 4. If the loop never reaches `200`, run
`docker compose logs --tail 40 vane` and `docker compose logs --tail 20 searxng`.

Open https://<DOMAIN> in a browser. The username is `vane` and the password is the one you read
in step 3. The first screen reads `Welcome to Vane` over `Web search, reimagined`, then a setup
wizard asks for a model provider. Paste your own provider API key into it, finish the wizard,
and run one search. You are done when an answer comes back with numbered citations under it,
not when the containers are running.

## 8. First backup and restore

The container stops for this: past searches are a SQLite file, and a copy taken mid-write is
not a backup.

```bash
cd /srv/perplexica
docker compose stop vane
sudo tar -czf /srv/perplexica/backups/perplexica-$(date +%F).tar.gz -C /srv/perplexica data uploads searxng .env browser-login compose.yml -C /etc/caddy Caddyfile
docker compose start vane
ls -lh /srv/perplexica/backups/
```

You should see: one archive, tens of kilobytes on a fresh install, and about ten seconds of
downtime.

If you do not: `tar: data: Cannot stat` means step 2 never made the directory. An archive of
about 100 bytes means everything it was asked for was missing, so read the `tar` output rather
than the size.

That archive holds `data/config.json`, and therefore your provider API key, so treat it like a
password file. A backup on the same disk is not a backup. Run this on your own machine, not the
server:

```bash
mkdir -p ~/backups/perplexica
scp vps:/srv/perplexica/backups/*.tar.gz ~/backups/perplexica/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/perplexica/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a test search:

```bash
cd /srv/perplexica
docker compose down
sudo rm -rf /srv/perplexica/data /srv/perplexica/uploads
sudo tar -xzf /srv/perplexica/backups/perplexica-$(date +%F).tar.gz -C /srv/perplexica data uploads
docker compose up -d
sleep 20
curl -sS http://127.0.0.1:8148/api/config | grep -oE '"setupComplete":[a-z]*|"searxngURL":"[^"]*"'
```

You should see: the config JSON again, this time with `"setupComplete":true`, which means the
setup you did in step 7 survived deleting and rebuilding the data directory.

If you do not: `"setupComplete":false` means the untar put the files somewhere else. Run
`sudo tar -tzf` on the archive to see the paths it actually contains. Understand the stakes
before you skip this step: the key you pasted into the setup screen lives in that archive and
nowhere else you control.

## 9. Updating later

Vane releases are at https://github.com/ItzCrazyKns/Vane/releases, and a slim tag is a release
tag with `slim-` in front of it. SearXNG publishes a dated tag most days at
https://hub.docker.com/r/searxng/searxng/tags. Take the backup first, then edit the `image:`
line you are changing in /srv/perplexica/compose.yml to its new tag and digest.

```bash
cd /srv/perplexica
docker compose pull
docker compose up -d
docker compose logs --tail 30 vane
```

You should see: migration lines, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Move the two
images on their own schedules rather than together, and bump the SearXNG tag whenever searches
start coming back thin, because that is usually an engine upstream has already fixed.

## 10. What will probably go wrong

Searches will work in a browser and come back half empty here, and it looks like a broken
install. It is not. SearXNG asks the real engines on your behalf and the real engines block
datacenter addresses: Google in particular blocks fresh instances within a handful of searches,
SearXNG suspends that engine for an hour, and the answer gets written from whatever survived. I
read thin, oddly-sourced answers for a day before I understood this is the deal rather than a
fault, and it is the honest difference between this and the product it replaces, which pays for
an index. Run
`docker compose exec -T searxng wget -qO- 'http://127.0.0.1:8080/stats/errors'` first.

## 11. Out of scope

- Do not switch to the full Vane image for its bundled SearXNG. That image carries a fixed key
  every copy of it shares, and its SearXNG only moves when Vane cuts a release.
- Do not put a provider API key in `.env` or compose.yml. It belongs on the setup screen.
- Do not remove the `import` line from the Caddy block and do not open 8148. Vane has no login
  of its own, and without that box anyone who finds the hostname spends your money.
- Do not add Valkey, Redis or the SearXNG limiter. Those are for instances the public reaches.
