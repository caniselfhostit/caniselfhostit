This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing LibreTranslate 1.9.6 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

One thing to know before step 1, because it decides how long you wait. LibreTranslate ships no
language models inside the image. The first start downloads them, about 2.1 GB, and nothing
answers until that finishes.

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
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of memory
is the one number here worth respecting: each worker loads its own copy of a translation model,
and the OOM killer arrives in the middle of a translation rather than at start-up, so the
failure looks random when it is not.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/libretranslate /srv/libretranslate/backups
sudo install -d -m 750 -o 1032 -g 1032 /srv/libretranslate/db
ls -la /srv/libretranslate
```

You should see: `backups` owned by you, and `db` owned by `1032` rather than by a name.

If you do not: `1032` is correct and it is not a user on this machine. The image creates its
own account with uid 1032 and runs as that account, so the directory it writes its key database
into has to belong to that uid. If you chown `db` to yourself, the container starts and then
cannot write, and the error you see later says `Permission denied` about a path you have never
heard of. There is no `data` directory here on purpose: nothing you translate is stored.

## 3. Secrets

One secret, the API key that every translation request will carry. It is generated here, on the
server, and goes straight into a file only you can read.

```bash
umask 077
openssl rand -hex 24 | tr -d '\n' > /srv/libretranslate/api-key
chmod 600 /srv/libretranslate/api-key
umask 022
ls -l /srv/libretranslate/api-key
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run
`chmod 600 /srv/libretranslate/api-key` and carry on. The trailing newline is stripped on
purpose, because step 7 hands this file straight to curl and to the container and a stray
newline would be part of the key.

Do not paste that file, the key, or any command output containing it into this chat window. And
do not run the command that lists keys while a chat window is open: it prints their values
straight to your terminal, which is exactly what step 3 exists to avoid. Read your own key when
you need it with `cat /srv/libretranslate/api-key`.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/libretranslate/compose.yml` and paste again in one go. There is no
`env_file` line and that is deliberate: the key from step 3 never enters the container's
environment, because step 7 puts it in the application's own database instead, where
`docker inspect` cannot read it back out.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-libretranslate /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and
not the other. Caddy requests the certificate on the first request to the hostname and renews
it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8154`.

If you do not: delete anything for `8154` with `sudo ufw delete allow 8154`. It is bound to
127.0.0.1 by the compose file, so a firewall rule for it would either do nothing or open a
translation service to the internet with the proxy skipped. 80/tcp redirects to HTTPS and
answers the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy
offers by default. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first start downloads the 22 model packages named by `LT_LOAD_ONLY` before anything
answers. Run the first three lines, then leave the loop alone.

```bash
cd /srv/libretranslate
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/languages | grep -o '"code": *"es"' | head -1
```

You should see: several minutes of `502` from the loop, then `200`, then a small JSON object
whose `status` field reads `ok`, then one line printing `"code":"es"`, which means the Spanish
models finished installing.

If you do not: open a second terminal and run
`ssh vps 'cd /srv/libretranslate && docker compose logs -f libretranslate'`. A `Downloading`
line per package means it is working and you are early. A container restarting in a loop with
no `Downloading` lines usually means step 2 gave `db` the wrong owner. If the loop runs out at
60 without a `200`, that is fifteen minutes, which is longer than this should take on any
normal connection: read the log before touching the Caddy block.

Now register the key from step 3 with the running service, and prove the two halves of the
access rule.

```bash
docker compose exec -T libretranslate sh -c 'ltmanage keys add 120 --key "$(cat)"' < /srv/libretranslate/api-key > /dev/null
curl -sS -w '\n%{http_code}\n' --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" https://<DOMAIN>/translate
curl -sS --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" --data-urlencode "api_key@/srv/libretranslate/api-key" https://<DOMAIN>/translate
curl -sS https://<DOMAIN>/ | grep -o 'Translation API' | head -1
```

You should see: nothing from the first line, then a body containing
`Please contact the server operator to get an API key` followed by `400`, then JSON containing
`"translatedText"` with Spanish in it, then `Translation API`.

If you do not: the `400` is the one worth understanding. It means the service is up and
refusing a call that carries no key, which is the whole security posture of this install, so
seeing it is good news. `403` with `Invalid API key` on the third line means the key in the
file and the key in the database do not match, which happens if you re-ran step 3 after
registering: run the registration line again. The first line prints nothing on purpose, because
the tool would otherwise echo your key into this terminal.

The first screen at https://<DOMAIN> is a text box under the heading `Translation API`. It also
carries a banner about bot abuse and API keys. That is upstream's own wording for the mode this
install runs in, not a fault. Click the key icon in the top bar, paste your key once, and the
box starts working. A running container is not success; the four lines above are.

## 8. First backup and restore

One archive: the key, the key database, the compose file and the Caddy block. The models are
not in it, on purpose. They are 2.1 GB of cache that downloads itself again.

```bash
cd /srv/libretranslate
sudo tar -czf /srv/libretranslate/backups/libretranslate-$(date +%F).tar.gz -C /srv/libretranslate compose.yml api-key db -C /etc/caddy Caddyfile
ls -lh /srv/libretranslate/backups/
```

You should see: one file, a few kilobytes on a fresh install. Nothing goes offline.

If you do not: `tar: db: Cannot open: Permission denied` means you dropped the `sudo`. The `db`
directory belongs to uid 1032 and your own account cannot read it.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/libretranslate
scp vps:/srv/libretranslate/backups/*.tar.gz ~/backups/libretranslate/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/libretranslate/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is a test key:

```bash
cd /srv/libretranslate
docker compose down
sudo rm -rf /srv/libretranslate/db
sudo tar -xzf /srv/libretranslate/backups/libretranslate-$(date +%F).tar.gz -C /srv/libretranslate db
docker compose up -d
sleep 60
curl -sS --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" --data-urlencode "api_key@/srv/libretranslate/api-key" https://<DOMAIN>/translate
```

You should see: JSON containing `"translatedText"` again, which means the key database came
back out of the archive and the service accepted the same key.

If you do not: `403` with `Invalid API key` means the untar did not restore `db`, so check
`ls -la /srv/libretranslate/db` for `api_keys.db` owned by `1032`. The models are untouched by
this, because they live in a Docker volume the archive never held, which is why this restore
takes a minute rather than the first start's several. Treat the archive as the secret it is: it
carries your key twice.

## 9. Updating later

New versions are listed at https://github.com/LibreTranslate/LibreTranslate/releases. Take the
backup first, then edit the `image:` line in /srv/libretranslate/compose.yml to the new tag and
its digest.

```bash
cd /srv/libretranslate
docker compose pull
docker compose up -d
docker compose logs --tail 30 libretranslate
```

You should see: the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
checks from step 7 before you call the update done. One thing the pin does not cover: the
models are versioned separately from the software and this file does not pin them, so a cache
rebuilt after an update can hold a newer model than the one it replaced, and a translation can
change without the software changing.

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
  index, about 8.4 GB, on a disk this guide sized for 10.
- Do not set `LT_SUGGESTIONS` and do not configure SMTP. Suggestions open a write path for
  anyone holding a key, and the service sends no mail at all.
