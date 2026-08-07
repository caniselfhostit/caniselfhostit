You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Vane v1.12.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say this to the user first. The project was called Perplexica until it was renamed Vane, and
1.12.2 exists only under the new name. Vane is an interface, not a model: it searches with
SearXNG and writes the answer with a provider key the user supplies on its setup screen,
metered per token and billed to them.

Vane with SearXNG needs 2048 MB of RAM available and 5 GB free on /srv. Both images publish
amd64 and arm64. Measure five things:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
caddy version
```

If available RAM is under 2048 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop. `caddy version` must
print 2.8 or newer, which is where `basicauth` was renamed `basic_auth`, the directive step 5
uses. If it is older, stop and tell the user to upgrade Caddy first.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/perplexica /srv/perplexica/backups
sudo install -d -m 700 /srv/perplexica/data /srv/perplexica/uploads
sudo install -d -m 755 /srv/perplexica/searxng
ls -la /srv/perplexica
```

Assert: `backups` owned by the login user, `data` and `uploads` at mode `700` owned by root
because the Vane image declares no unprivileged user, `searxng` at `755` because the one config
file in it holds no secret.

## 3. Secrets

Two secrets, both generated here. Print neither, repeat neither in your summary, and put
neither in a log line. The first replaces a session key published in the settings file every
copy of the bundled SearXNG image carries. The second is the password on the login box in step
5, the only thing between the internet and a setup screen holding the user's API key.

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

Assert: both files exist with mode `-rw-------`. Hex rather than base64, because the login value
gets typed into a browser dialog, and it is deliberately not in `.env`, which is what compose
hands a container. Neither is a provider API key: that arrives in the browser in step 7 and this
install never sees it.

## 4. Config and compose.yml

SearXNG answers in HTML only until its settings say otherwise, and Vane asks for JSON. Write
that file first:

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
  # Named in Vane's install notes.
  - name: wolframalpha
    disabled: false
EOF
sudo chmod 644 /srv/perplexica/searxng/settings.yml
```

Then the compose file:

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

Assert: that prints `compose OK`. Compose reads `.env` for `${SEARXNG_SECRET}` because it sits
beside this file, and 8148 is the only published port.

## 5. Caddy and TLS

Two files. First the credential Caddy checks: a bcrypt hash of the step 3 password, written
where the caddy user can read it and nowhere else.

```bash
umask 077
caddy hash-password < /srv/perplexica/browser-login > /srv/perplexica/vane-auth.hash
printf 'basic_auth {\n\tvane %s\n}\n' "$(cat /srv/perplexica/vane-auth.hash)" > /srv/perplexica/vane-auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/perplexica/vane-auth.conf /etc/caddy/vane-auth.conf
rm -f /srv/perplexica/vane-auth.hash /srv/perplexica/vane-auth.conf
sudo grep -c basic_auth /etc/caddy/vane-auth.conf
```

Assert: that prints `1`. The username is the literal `vane`. Reading the password from a file
keeps it off the process list.

Then the site block, with `<DOMAIN>` replaced by the real hostname. Copy the Caddyfile first: a
syntax error here takes every site on the box down.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-perplexica, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it alone.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8148 stays closed because it is bound to 127.0.0.1, and opening it would route
around the login box in step 5. SearXNG publishes no host port at all. Assert: `ufw status
verbose` prints `Status: active`, shows those three, and no rule for 8148 or 8080.

## 7. Start and verify

The Vane image is about a gigabyte, so the pull takes minutes.

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

Assert all five, and print what you received for each. The loop ends printing `200`. The grep
prints `"setupComplete":false` and the searxng URL. The first grep
prints `1`, the setup screen. The SearXNG grep prints `1`, proving JSON is enabled and step 4's
file was read; a `403` there means it was not. The last curl prints `401`, Caddy refusing an
unauthenticated request, and that is the security assert here. If any of the five misses, stop,
run `docker compose logs --tail 40 vane` and `docker compose logs --tail 20 searxng`, and name
the likely earlier step. A running container is not success.

STOP: tell the user to open https://<DOMAIN>, sign in with the username `vane` and the password
they read with `sudo cat /srv/perplexica/browser-login`, and wait. Do not continue until they
confirm. The first screen reads `Welcome to Vane` over `Web search, reimagined`, then the setup
wizard asks for a model provider. Tell them to put that password in their password manager,
paste their own provider key into the wizard, finish it, and run one search. Do not report
success until they confirm an answer came back with numbered citations under it. That key is
theirs and billed to their account; never ask them to paste it to you.

## 8. First backup and restore

One archive, and the container stops for it: past searches are a SQLite file, and a copy taken
mid-write is not a backup.

```bash
cd /srv/perplexica
docker compose stop vane
sudo tar -czf /srv/perplexica/backups/perplexica-$(date +%F).tar.gz -C /srv/perplexica data uploads searxng .env browser-login compose.yml -C /etc/caddy Caddyfile
docker compose start vane
ls -lh /srv/perplexica/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds. It
holds `data/config.json` and therefore the provider key, so it is as sensitive as a password
file. A backup on the same disk is not one, so run this from the user's machine:

```bash
mkdir -p ~/backups/perplexica
scp vps:/srv/perplexica/backups/*.tar.gz ~/backups/perplexica/
```

To restore: `docker compose down`, `sudo rm -rf /srv/perplexica/data /srv/perplexica/uploads`,
untar the archive back into /srv/perplexica, re-run the first fence of step 5 to rebuild
/etc/caddy/vane-auth.conf from the restored `browser-login`, `sudo systemctl reload caddy`,
then `docker compose up -d` and re-run step 7's five asserts. That is the whole disaster plan,
and this archive is the only copy of the key they pasted in.

## 9. Updating later

Vane releases are at https://github.com/ItzCrazyKns/Vane/releases, and a slim tag is a release
tag with `slim-` in front of it. SearXNG publishes a dated tag most days at
https://hub.docker.com/r/searxng/searxng/tags. Back up first, then edit the `image:` line you
are changing in /srv/perplexica/compose.yml to its new tag and digest:

```bash
cd /srv/perplexica
docker compose pull
docker compose up -d
docker compose logs --tail 30 vane
```

Move the two images on their own schedules. Vane migrates its database on the way up, so watch
that log until it settles. Bump the SearXNG tag when searches come back thin: that is usually
an engine upstream has already fixed.

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
  of its own, and without that box anyone who finds the hostname spends the user's money.
- Do not add Valkey, Redis or the SearXNG limiter. Those are for instances the public reaches.
