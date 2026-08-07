This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing HeyForm v3.0.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` becomes `APP_HOMEPAGE_URL`, and every form you publish is
that hostname plus `/form/` and an id. Change the hostname later and every link you have sent
out stops working, so pick the one you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
grep -c -w avx /proc/cpuinfo || true
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, a
non-zero AVX count, and your server's IP on the last line.

If you do not: an AVX count of `0` on `amd64` is a hard stop, because MongoDB 7 exits during
start-up on a CPU without it and no setting changes that; move to a box with a newer processor.
An empty last line means the A record does not exist yet: add it, wait a minute, run
`dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that does
not resolve and failed attempts count against a rate limit you cannot see. Under 2048 MB of
RAM is the case where the install looks like it worked and then the OOM killer takes MongoDB
out during your first busy hour.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/heyform /srv/heyform/backups /srv/heyform/uploads
ls -la /srv/heyform
```

You should see: `backups` and `uploads`, both owned by you, and nothing else.

If you do not: there is deliberately no database directory here. The mongo image chowns
/data/db to its own uid, so both databases live in named volumes that step 8 dumps rather than
copies. `uploads` is a real directory because it holds the files respondents attach to a
submission, and those are the one thing a database dump does not contain.

## 3. Secrets

Four secrets: the session key, the form-token key, the MongoDB password and the Valkey
password. All four are generated here, on the server, and all four go straight into a file only
you can read. Hex rather than base64, because two of them travel inside connection strings.

```bash
umask 077
cat > /srv/heyform/.env <<EOF
APP_HOMEPAGE_URL=https://<DOMAIN>
SESSION_KEY=$(openssl rand -hex 32)
FORM_ENCRYPTION_KEY=$(openssl rand -hex 32)
MONGO_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/heyform/.env
umask 022
ls -l /srv/heyform/.env
```

Replace `<DOMAIN>` on the first line with your real hostname before you paste.

You should see: mode `-rw-------`, your own username twice, and the path.

Do not paste that file, any of those four values, or any command output containing them into
this chat window. The agent path never sees them; this one hands them to a third party unless
you keep them out.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/heyform/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all four
secrets, which is fine before the databases exist and a problem afterwards: MongoDB keeps the
password it was created with, so a changed `MONGO_PASSWORD` against an existing volume shows up
as `"mongo":"down"` in step 7 rather than as anything about passwords.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/heyform/compose.yml <<'EOF'
# HeyForm · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   self-hosting ... https://docs.heyform.net/open-source/self-hosting
#   image and port . https://github.com/heyform/heyform/blob/v3.0.0/Dockerfile
#   variables ...... https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/environments/index.ts
#   health ......... https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/controller/health.controller.ts
#
# Three services: HeyForm, the MongoDB holding every form and answer, and the
# Valkey carrying sessions and the job queue. Upstream's compose names
# percona/percona-server-mongodb:4.4 and eqalpha/keydb; this file pins mongo
# 7.0, because MongoDB 4.4 left support on 2024-02-29 and HeyForm's Mongoose
# 7.8.7 covers server 7.x, and Valkey, because KeyDB ships no multi-arch
# versioned tag and last released in 2023. Both databases are named volumes:
# the mongo image chowns /data/db to its own uid. Digests read on 2026-08-07;
# all three images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mongo:
    image: mongo:7.0.39@sha256:35a5926f71f8b6cb19206bee928c5a85f241a8be99f20c81abe35ae78a73415d
    restart: unless-stopped
    command: ["mongod", "--bind_ip_all", "--quiet"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: heyform
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD}
    volumes:
      - heyform-mongo:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "quit(db.adminCommand({ping:1}).ok === 1 ? 0 : 1)"]
      interval: 10s
      retries: 30
      start_period: 20s
    # No `ports:` on either database: both stay on the compose network.

  valkey:
    image: valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328
    restart: unless-stopped
    environment:
      VALKEY_PASSWORD: ${REDIS_PASSWORD}
    command: ["sh", "-c", "exec valkey-server --appendonly yes --requirepass \"$$VALKEY_PASSWORD\""]
    volumes:
      - heyform-valkey:/data
    healthcheck:
      test: ["CMD-SHELL", 'valkey-cli -a "$$VALKEY_PASSWORD" --no-auth-warning ping | grep -q PONG']
      interval: 10s
      retries: 30

  heyform:
    image: heyform/community-edition:v3.0.0@sha256:27507032eb39ddb23dcadb4490ad383a104d1a32a6b368ad0f2e78538a187877
    restart: unless-stopped
    env_file: /srv/heyform/.env
    environment:
      # authSource=admin: the credential is the root user mongo makes there.
      MONGO_URI: mongodb://mongo:27017/heyform?authSource=admin
      MONGO_USER: heyform
      REDIS_HOST: valkey
      REDIS_PORT: 6379
      ENABLE_GOOGLE_FONTS: "false"
    volumes:
      - /srv/heyform/uploads:/app/packages/server/static/upload
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8170.
      - "127.0.0.1:8170:9157"
    depends_on:
      mongo:
        condition: service_healthy
      valkey:
        condition: service_healthy

volumes:
  heyform-mongo:
  heyform-valkey:
EOF
cd /srv/heyform && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/heyform/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/heyform/compose.yml` and paste again in one go. A warning about `MONGO_PASSWORD`
not being set means Compose is not reading the `.env` next to the compose file, which happens
if you ran the command from a different directory than /srv/heyform.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-heyform
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# HeyForm · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.heyform.net/open-source/self-hosting and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_HOMEPAGE_URL in .env, and HeyForm builds its cookie domain and its
# CORS allowlist from that one value, so the two have to match or the dashboard
# signs you straight back out.

<DOMAIN> {
	# No X-Frame-Options on purpose: HeyForm ships an embed library and turns
	# frameguard off itself, so a form is meant to run inside another page.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8170 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. HeyForm sets Express
	# trust-proxy to 1, so it reads the visitor address Caddy forwards.
	reverse_proxy 127.0.0.1:8170
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-heyform /etc/caddy/Caddyfile`, reload,
and paste again. The hostname in this block and the hostname in `APP_HOMEPAGE_URL` have to be
the same string: HeyForm builds its cookie domain and its credentialed-CORS allowlist from that
one value, and a mismatch gives you a sign-in page that works and a session that never sticks.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8170`, `27017` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8170`. 8170 is bound
to 127.0.0.1 by the compose file, and neither database publishes a host port at all, so no
firewall rule could apply to them. 80/tcp is there to redirect to HTTPS and to answer the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

MongoDB creates its root user the first time it initialises an empty volume, and HeyForm waits
for both databases to report healthy before it starts, so the first boot is slower than the
ones after it.

```bash
cd /srv/heyform
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health/ready); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health/ready
curl -sS https://<DOMAIN>/login | grep -o '<title>HeyForm</title>'
```

You should see, in order: the loop reaching `200`, a JSON object containing
`"checks":{"mongo":"up","redis":"up"}`, then `<title>HeyForm</title>`.

If you do not: the readiness body is the one worth reading. It reports the two databases
separately, so `"mongo":"down"` with `"redis":"up"` is an authentication problem rather than a
container that never started, and it points back at step 3. A `502` from Caddy with healthy
containers means the reverse-proxy line is pointing somewhere other than 8170. If the loop
never reaches `200` at all, run `docker compose logs --tail 40 heyform` and
`docker compose logs --tail 20 mongo` in that order. A running container is not success.

The first screen at https://<DOMAIN>/login is a sign-in form with an `Email address` field and
a `create an account` link under the heading. Registration is open to anyone who reaches your
hostname until the next block closes it, so do this now rather than tomorrow.

Open https://<DOMAIN>/sign-up in a browser and create your account with a real email address.
HeyForm refuses disposable-address domains, and no confirmation mail will arrive, because this
install has no mail server and the account works without one. You land on a screen that asks
you to create a workspace.

Then close registration:

```bash
cd /srv/heyform
echo 'APP_DISABLE_REGISTRATION=true' >> /srv/heyform/.env
docker compose up -d --force-recreate heyform
sleep 20
curl -sS https://<DOMAIN>/api/config | grep -o '"appDisableRegistration":true'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/sign-up
```

You should see: `"appDisableRegistration":true`, then `302`. Reload https://<DOMAIN>/login in
your browser and confirm the `create an account` link is gone.

If you do not: an empty first line means the container did not pick up the new variable, so
check that the line landed in /srv/heyform/.env and run the recreate again. A `200` instead of
`302` means the same thing. This setting is enforced in the sign-up mutation as well as in the
page, so once both asserts pass, a stranger who guesses the URL cannot make an account.

## 8. First backup and restore

Two artifacts. The database holds every form, every submission and your account. The config
archive holds the files that rebuild the service around it, plus the uploads a dump does not
contain.

```bash
cd /srv/heyform
docker compose exec -T mongo sh -c 'mongodump --quiet --archive --gzip --db=heyform -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > /srv/heyform/backups/heyform-db-$(date +%F).archive.gz
sudo tar -czf /srv/heyform/backups/heyform-config-$(date +%F).tar.gz -C /srv/heyform compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/heyform/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline, and
neither credential is printed, because the shell that expands them runs inside the container.

If you do not: an `.archive.gz` of about 20 bytes is an empty dump, which means `mongodump`
failed and the shell created the file anyway. Re-run the line without the redirect to read the
error. `Authentication failed` there means the password in .env and the password in the volume
disagree, which is the same problem step 7 reports as `"mongo":"down"`.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/heyform
scp vps:/srv/heyform/backups/* ~/backups/heyform/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/heyform/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one empty workspace:

```bash
cd /srv/heyform
docker compose down -v
docker compose up -d mongo
sleep 30
gunzip -c /srv/heyform/backups/heyform-db-$(date +%F).archive.gz | docker compose exec -T mongo sh -c 'mongorestore --archive --drop -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/health/ready
```

You should see: restore lines naming the `heyform` database, then a readiness body with both
checks `up`, and your account still works when you sign in.

If you do not: `Authentication failed` means the fresh volume had not finished initialising, so
wait longer and run the `gunzip` line again. `docker compose down -v` drops the database volume
on purpose, which is the whole point of the drill, and it is also why `-v` belongs on no other
command in this file. Understand the stakes before you skip this: every answer anyone ever
sends you is a row in that dump, and a form whose responses nobody copied off the box dies with
the disk.

## 9. Updating later

New versions are listed at https://github.com/heyform/heyform/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/heyform/compose.yml to the new tag and its
digest.

```bash
cd /srv/heyform
docker compose pull
docker compose up -d
docker compose logs --tail 30 heyform
```

You should see: the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
readiness check from step 7 before you call the update done. Leave the mongo line alone: a
database major version is a separate migration with its own dump and restore.

## 10. What will probably go wrong

`APP_HOMEPAGE_URL`. I wrote the hostname in without the scheme, the sign-in page rendered
perfectly over https, and I believed the install had worked. Then every login bounced back to
the sign-in screen with nothing in any log. HeyForm builds the cookie domain and the
credentialed-CORS allowlist from that string, so a value the browser does not read as the
origin it is talking to means the session cookie is set and then ignored. If sign-in loops, run
`docker compose exec -T heyform printenv APP_HOMEPAGE_URL` first. It must read `https://` and
the hostname, no trailing slash, no port.

## 11. Out of scope

- Do not configure SMTP. HeyForm creates the account, signs you in and records submissions with
  no mail server. Mail adds verification, password reset and response notifications, and
  outbound mail from a fresh VPS is a fight for another day.
- Do not set `GOOGLE_LOGIN_CLIENT_ID` or the Apple login variables. Each is an account
  somewhere else and a second failure mode; this install has a working sign-in.
- Do not set the `S3_` variables. Attachments belong in /srv/heyform/uploads, which step 8
  already puts in the backup archive.
- Do not set `OPENAI_API_KEY`, `AKISMET_KEY` or the reCAPTCHA keys. Each is a third-party
  subscription, and the builder, the logic and storage work without them.
