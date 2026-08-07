You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install LibreTranslate 1.9.6 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and every script or app they point here is
configured with `https://<DOMAIN>`.

LibreTranslate loads neural translation models into memory, one copy per worker. It needs 2048
MB of RAM available and 10 GB free on /srv, and publishes amd64 and arm64. Measure all four
first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope: the models in step 4 are 2.1 GB before the image, and the OOM killer
arrives in the middle of a translation rather than at start-up. If `dig +short` prints nothing,
print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/libretranslate /srv/libretranslate/backups
sudo install -d -m 750 -o 1032 -g 1032 /srv/libretranslate/db
ls -la /srv/libretranslate
```

Assert: `ls -la` shows `backups` owned by the login user and `db` owned by `1032`. That number
is not a mistake and not a user on this host: the image creates its own account with uid 1032
and runs as it, so the directory holding its key database has to belong to that uid. There is
no `data` directory and there will not be one: nothing the user translates is stored.

## 3. Secrets

One secret: the API key every translation request has to carry. Generate it here, print it
nowhere, keep it out of your summary and out of any log line. It is the whole access control
here, because step 4 sets `LT_UNDER_ATTACK` and the application refuses a keyless request
itself rather than leaning on a password box API clients could not answer.

```bash
umask 077
openssl rand -hex 24 | tr -d '\n' > /srv/libretranslate/api-key
chmod 600 /srv/libretranslate/api-key
umask 022
ls -l /srv/libretranslate/api-key
```

Assert: the file exists with mode `-rw-------`. Hex rather than base64, because this value gets
typed into settings boxes on other machines. The trailing newline is stripped on purpose so the
file can be handed to curl and to the container verbatim. Do not run the command that lists
keys at any point: it prints their values straight to the terminal, which is the one thing this
step exists to avoid.

## 4. compose.yml

```bash
cat > /srv/libretranslate/compose.yml <<'EOF'
# LibreTranslate · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   installation ....... https://docs.libretranslate.com/guides/installation/
#   quickstart ......... https://docs.libretranslate.com/
#   argument defaults .. https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/libretranslate/default_values.py
#   image build ........ https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/docker/Dockerfile
#   container start .... https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/scripts/entrypoint.sh
#
# One service and no database process. Every setting below is an LT_ variable:
# upstream reads each argument from LT_ plus the argument name in upper snake
# case, and default_values.py is the list of them.
#
# Two mounts, doing different jobs. db holds one SQLite file, the API key
# database, and it is the only thing here worth backing up. The model cache is a
# named volume because the image creates its own user with uid 1032 and chowns
# /home/libretranslate to it: a fresh named volume inherits that ownership and a
# home-directory bind mount cannot. Upstream's run.sh mounts both the same way.
#
# Tag and digest were read from Docker Hub on 2026-08-07; the image publishes
# amd64 and arm64. The -cuda tag is a separate amd64-only image this file does
# not use: the CPU image is upstream's ordinary path.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  libretranslate:
    image: libretranslate/libretranslate:v1.9.6@sha256:1de2d7056bb8ad607a412f4563d9abe324ff632b43b5be9428bcc8e213aebb32
    container_name: libretranslate
    restart: unless-stopped
    environment:
      # Eleven languages, each paired with English in both directions and
      # pivoted through English for every other combination. That is 22 model
      # packages, about 2.1 GB, downloaded during the first start. Deleting this
      # line downloads all 100 packages in the index instead, about 8.4 GB.
      LT_LOAD_ONLY: "en,es,fr,de,it,pt,nl,pl,ru,zh,ja"
      # The key database, and the mode that makes a key mandatory on every
      # translate, detect and file route. Without both of these, whatever can
      # reach this port can spend this machine's CPU.
      LT_API_KEYS: "true"
      LT_UNDER_ATTACK: "true"
      # entrypoint.sh hands this to gunicorn as --workers. Each worker loads its
      # own copy of a model the first time a pair is used, so this number
      # multiplies memory. Upstream's default is 4.
      LT_THREADS: "2"
      # One request cannot occupy a worker forever. 20000 characters is a long
      # document; upstream's default is no ceiling at all.
      LT_CHAR_LIMIT: "20000"
    volumes:
      - /srv/libretranslate/db:/app/db
      - libretranslate-models:/home/libretranslate/.local
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8154.
      - "127.0.0.1:8154:5000"
    healthcheck:
      # Upstream's own script. It exits 0 while /tmp/booting.flag exists, so the
      # container does not report unhealthy during the first model download.
      test: ["CMD-SHELL", "./venv/bin/python scripts/healthcheck.py"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 900s

volumes:
  libretranslate-models:
EOF
cd /srv/libretranslate && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. There is no `env_file` line: the secret from step 3 goes into
the application's own key database in step 7, so the service reads it from SQLite rather than
from a variable `docker inspect` would show.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-libretranslate
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# LibreTranslate · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.libretranslate.com/guides/installation/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. The application
# runs with LT_API_KEYS and LT_UNDER_ATTACK set, so it refuses a translation
# request carrying no key of its own. This block terminates TLS in front of that
# and adds no second credential: a browser password box would stop the API
# clients this install exists to serve.

<DOMAIN> {
	# The web page is HTML and the API answers JSON, and both compress well.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8154 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8154
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-libretranslate, reload, and report what it objected to. Caddy
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
443/udp is HTTP/3. 8154 stays closed because it is bound to 127.0.0.1, and opening it would put
the service on the open internet with the proxy skipped. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule for 8154.

## 7. Start and verify

The first start downloads the 22 model packages named by `LT_LOAD_ONLY`, about 2.1 GB, before
anything answers. The loop below is patient for that reason, and
`docker compose logs -f libretranslate` prints a `Downloading` line per package.

```bash
cd /srv/libretranslate
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/languages | grep -o '"code": *"es"' | head -1
docker compose exec -T libretranslate sh -c 'ltmanage keys add 120 --key "$(cat)"' < /srv/libretranslate/api-key > /dev/null
curl -sS -w '\n%{http_code}\n' --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" https://<DOMAIN>/translate
curl -sS --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" --data-urlencode "api_key@/srv/libretranslate/api-key" https://<DOMAIN>/translate
curl -sS https://<DOMAIN>/ | grep -o 'Translation API' | head -1
```

Assert, all six, and print what you received for each. The loop ends printing `200`. The health
response carries `"status"` reading `ok`. The languages grep prints `"code":"es"`. The keyless
call prints `400` and a body containing `Please contact the server operator to get an API key`,
the security assert here: an open translation endpoint on a public name is free compute for
whoever finds it. The keyed call returns JSON containing `"translatedText"` with Spanish in it.
The last command prints `Translation API`, the heading on the first screen at https://<DOMAIN>.
If any of the six misses, stop, run `docker compose logs --tail 40 libretranslate`, and name
the likely earlier step: a `502` from the loop means the models are still downloading,
`Permission denied` near `api_keys` means step 2 created `db` with the wrong owner, and a `403`
with `Invalid API key` means the registration line ran before the container was up. A running
container is not success.

The key travels on standard input in that registration line, so it is in no command line and no
process list, and `> /dev/null` discards the copy the tool echoes. `120` is its per-minute
request limit.

STOP: tell the user to read their key with `cat /srv/libretranslate/api-key`, put it in their
password manager, then open https://<DOMAIN>, click the key icon in the top bar, paste it, and
translate one sentence. Do not continue until they confirm. The banner about bot abuse on that
page is upstream's wording for the mode this install runs in, not a fault.

## 8. First backup and restore

One archive: the key, the key database, the compose file and the Caddy block. The models are
not in it on purpose: 2.1 GB of cache that downloads itself again, and a backup that takes an
hour to copy is one nobody runs twice.

```bash
cd /srv/libretranslate
sudo tar -czf /srv/libretranslate/backups/libretranslate-$(date +%F).tar.gz -C /srv/libretranslate compose.yml api-key db -C /etc/caddy Caddyfile
ls -lh /srv/libretranslate/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped: the key
database is written only when a key is added or removed. The archive carries the key twice, so
treat it as the secret it is. A backup on the same disk is not a backup, so run this from the
user's machine:

```bash
mkdir -p ~/backups/libretranslate
scp vps:/srv/libretranslate/backups/*.tar.gz ~/backups/libretranslate/
```

To restore on a fresh box: recreate the layout from step 2, untar the archive into
/srv/libretranslate as root so `db` keeps its uid 1032 owner, put `Caddyfile` back in
/etc/caddy with `<DOMAIN>` substituted, `sudo systemctl reload caddy`, then
`docker compose up -d` and re-run step 7's asserts. The models download again and take as long
as before. Tell the user the honest version: losing this archive costs the key and an hour, not
their documents, which were never stored here.

## 9. Updating later

New versions are listed at https://github.com/LibreTranslate/LibreTranslate/releases. Take the
backup first, then edit the image line in /srv/libretranslate/compose.yml to the new tag and
its digest:

```bash
cd /srv/libretranslate
docker compose pull
docker compose up -d
docker compose logs --tail 30 libretranslate
```

Watch that log until the server reports it is listening, then re-run step 7's asserts before
calling the update done. The models are versioned separately from the software and this file
does not pin them: they resolve against a package index at download time, so a rebuilt cache
can hold a newer model than the one it replaced.

## 10. What will probably go wrong

The first start looks like a broken install for several minutes. `docker compose up -d`
returned in about a second, `docker compose ps` said the container was up and healthy, and
every request to https://<DOMAIN> came back `502`. I re-read the Caddy block twice before
running `docker compose logs -f libretranslate` and watching a `Downloading translate-en_es`
line crawl past. Nothing serves until the last of the 22 packages is installed, and the health
check upstream ships reports success throughout because the container is booting on purpose. If
step 7's loop prints `502`, read the log first.

## 11. Out of scope

- Do not switch to the `-cuda` image tag. It is a separate amd64-only image needing an NVIDIA
  card and the container toolkit; the CPU image is what upstream builds for both architectures.
- Do not remove `LT_API_KEYS` or `LT_UNDER_ATTACK`. That pair is the entire access control on a
  public hostname, and there is no second lock behind it.
- Do not delete `LT_LOAD_ONLY` to get every language. That downloads all 100 packages in the
  index, about 8.4 GB, on a disk this prompt sized for 10.
- Do not set `LT_SUGGESTIONS` and do not configure SMTP. Suggestions open a write path for
  anyone holding a key, and the service sends no mail at all.
