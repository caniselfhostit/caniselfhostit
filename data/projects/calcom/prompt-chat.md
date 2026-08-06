This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Cal.com 6.2.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` becomes `NEXT_PUBLIC_WEBAPP_URL`, and the container rewrites
the URL compiled into its own image to match it every time a fresh container starts. Every
booking link you hand out carries that hostname, so pick the one you intend to keep. Set aside
an afternoon: two of the steps below wait fifteen minutes each, and that is normal rather than a
fault.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `15` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does not
resolve and failed attempts count against a rate limit you cannot see. Under 4096 MB of RAM is
the one to take seriously here: this is a Next.js server with a full node_modules tree beside a
PostgreSQL, and a 2 GB box will get through the migrations and then be killed during the first
real page render. Note whether the architecture line said `amd64` or `arm64`, because step 4
needs it: upstream ships no multi-architecture manifest, so the two are separate tags.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/calcom /srv/calcom/backups
sudo install -d -m 700 /srv/calcom/postgres
ls -la /srv/calcom
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. There is no directory for Cal.com itself, because bookings, avatars and
calendar credentials are all rows in the database.

## 3. Secrets

Three secrets: the PostgreSQL password, the NextAuth session secret, and the encryption key that
protects saved calendar credentials. All three are generated here, on the server, and all three
go straight into a file only you can read. Upstream documents `openssl rand -base64 32` for the
session secret and `openssl rand -base64 24` for the encryption key, which is the 32-character
key AES-256 wants. Replace `<DOMAIN>` on the first two lines with your real hostname before you
paste.

```bash
umask 077
cat > /srv/calcom/.env <<EOF
NEXT_PUBLIC_WEBAPP_URL=https://<DOMAIN>
NEXT_PUBLIC_WEBSITE_URL=https://<DOMAIN>
CALCOM_TELEMETRY_DISABLED=1
POSTGRES_PASSWORD=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -base64 32)
CALENDSO_ENCRYPTION_KEY=$(openssl rand -base64 24)
EMAIL_FROM=CHANGE_ME
EMAIL_FROM_NAME=CHANGE_ME
EMAIL_SERVER_HOST=CHANGE_ME
EMAIL_SERVER_PORT=587
EMAIL_SERVER_USER=CHANGE_ME
EMAIL_SERVER_PASSWORD=CHANGE_ME
EOF
chmod 600 /srv/calcom/.env
umask 022
ls -l /srv/calcom/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/calcom/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all
three secrets, which is fine before the database exists and a problem afterwards: PostgreSQL
keeps the password it was created with, so a changed `POSTGRES_PASSWORD` against an existing
volume shows up as an authentication failure in the Cal.com log rather than as anything about
passwords.

Do not paste that file, any of the three secrets, or any command output containing them into
this chat window. `CALENDSO_ENCRYPTION_KEY` deserves one extra sentence: every Google or Outlook
connection you later add is encrypted with it, so it cannot be rotated and it cannot be lost.

Now the mail relay. Cal.com sends the confirmation to the person who booked, so an install with
no relay tells nobody anything. Open the file and replace the five `CHANGE_ME` values:

```bash
nano /srv/calcom/.env
grep -c CHANGE_ME /srv/calcom/.env || true
```

You should see: `0` from the second command. Set `EMAIL_FROM` to the address your relay is
allowed to send from, `EMAIL_FROM_NAME` to whatever you want invitees to read, and the three
`EMAIL_SERVER_` values from the relay's own dashboard. Correct `EMAIL_SERVER_PORT` if it is not
587.

If you do not: any number above `0` means a `CHANGE_ME` is still sitting there. That `grep`
counts lines and prints no value, which is why it is safe to run with this chat window open. Do
not paste your relay password here.

## 4. compose.yml

Paste the whole block at once, including the last line.

```bash
cat > /srv/calcom/compose.yml <<'EOF'
# Cal.com · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository. Read at tag v6.2.0 of
# https://github.com/calcom/cal.diy : docs/self-hosting/docker.mdx, .env.example,
# Dockerfile and scripts/start.sh.
#
# Two services: the Cal.com web app and the PostgreSQL holding every event type,
# booking and calendar credential. Upstream's compose file builds from source
# beside an API container and a Prisma Studio; this one pulls the published
# image. Its entrypoint rewrites the URL baked into the build to
# NEXT_PUBLIC_WEBAPP_URL and migrates on every fresh container, so a first boot
# takes minutes and the health check below adds a start period.
#
# Digests read on 2026-08-05. The v6.2.0 tag is amd64 only; arm64 ships as the
# separate v6.2.0-arm tag, not one multi-architecture manifest.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: calcom-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: calcom
      POSTGRES_USER: calcom
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/calcom/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U calcom -d calcom"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  calcom:
    image: calcom/cal.com:v6.2.0@sha256:ace3bb1219fb7306585ab9f4d94d41af7ee064c343db0498173436bbe857bd49
    container_name: calcom
    restart: unless-stopped
    env_file: /srv/calcom/.env
    environment:
      # start.sh waits on this host:port pair before migrating.
      DATABASE_HOST: postgres:5432
      DATABASE_URL: postgresql://calcom:${POSTGRES_PASSWORD}@postgres:5432/calcom
      # Prisma migrates over the direct URL. No pooler, so the same address.
      DATABASE_DIRECT_URL: postgresql://calcom:${POSTGRES_PASSWORD}@postgres:5432/calcom
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:3000 || exit 1"]
      interval: 30s
      timeout: 30s
      retries: 5
      start_period: 900s
    ports:
      # Loopback only: the host's Caddy is all that reaches 8094.
      - "127.0.0.1:8094:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
```

Then, only if step 1 printed `arm64`, switch the image line. On amd64 this changes nothing:

```bash
if [ "$(dpkg --print-architecture)" = "arm64" ]; then
  sed 's|:v6.2.0@sha256:[a-f0-9]*|:v6.2.0-arm@sha256:4b0fa72eec13bd3ddb608a6d13f05bf0ebc136e73832abfe1a8ec145db9e4651|' /srv/calcom/compose.yml > /srv/calcom/compose.arm && mv /srv/calcom/compose.arm /srv/calcom/compose.yml
fi
grep -n 'image:' /srv/calcom/compose.yml
cd /srv/calcom && docker compose config >/dev/null && echo "compose OK"
```

You should see: two `image:` lines, the Cal.com one ending in `-arm` only if you are on arm64,
then `compose OK` and nothing else.

If you do not: `env file /srv/calcom/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/calcom/compose.yml` and paste again in one go. There is no password in this file,
which is deliberate: compose reads `${POSTGRES_PASSWORD}` out of /srv/calcom/.env when it builds
the two connection strings, so the file stays safe to show somebody.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-calcom
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Cal.com · the Caddy site block for this service. Authored by caniselfhostit
# from https://github.com/calcom/cal.diy/blob/v6.2.0/docs/self-hosting/docker.mdx
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# NEXT_PUBLIC_WEBAPP_URL in .env: the container rewrites its own built-in URL to
# match on every fresh start, so the two have to agree exactly.

<DOMAIN> {
	# Every invitee lands on a page from here, so a downgrade has a real
	# audience. No X-Frame-Options on purpose: booking pages are meant to be
	# embedded in other people's sites.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8094 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8094
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-calcom /etc/caddy/Caddyfile`, reload, and
paste again. The hostname in this block and `NEXT_PUBLIC_WEBAPP_URL` in .env have to be the same
string, because the container rewrites its compiled-in URL to whatever .env says and Caddy is
what answers on that name.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8094` or `5432`.

If you do not: delete anything for `8094` or `5432` with `sudo ufw delete allow 8094`. 8094 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has
no host port a firewall rule could apply to. `Status: inactive` is a different problem: Prompt
Zero left this firewall enabled, so something has turned it off since, and `sudo ufw enable`
puts it back before you go any further.

## 7. Start and verify

This is the long one. On a fresh container the entrypoint rewrites every compiled-in copy of the
built URL, waits for PostgreSQL, applies the database migrations and seeds the app store before
Next.js listens on anything. Start it and leave it alone.

```bash
cd /srv/calcom
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' "https://<DOMAIN>/auth/setup?step=1"); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS "https://<DOMAIN>/auth/setup?step=1" | grep -o '<title>[^<]*</title>'
curl -sS -o /dev/null -w '%{http_code}\n' "https://<DOMAIN>/signup"
```

You should see, in order: several minutes of `502`, then the loop reaching `200`, then the line
`<title>Setup | Cal.com</title>`, then `200`. That last `200` means registration is open, which
is correct for now and closed at the end of this step.

If you do not: run `docker compose logs --tail 60 calcom`. `Replacing all statically built
instances` means it is rewriting the URL and has not finished. Migration names scrolling past
mean the database is being built. Either way it is working and needs more time. A loop that
expires with `502` and a log that is not moving is different: check
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy is
step 2 done wrong. `CLIENT_FETCH_ERROR` in the Cal.com log means `NEXT_PUBLIC_WEBAPP_URL` from
step 3 is not the hostname Caddy is serving.

Now open https://<DOMAIN>/auth/setup?step=1 in a browser. The first screen is a wizard headed
`Administrator user`, with `Let's create the first administrator user.` under it. Create that
account. The password rule is upstream's and it is strict: at least 15 characters, one number,
and both cases. Step 2 of the wizard asks you to choose a licence, and the free AGPLv3 option is
the one this install runs under. Step 3 offers to enable apps; you can skip it.

With the account made, close registration so nobody else can create one:

```bash
printf 'NEXT_PUBLIC_DISABLE_SIGNUP=true\n' >> /srv/calcom/.env
cd /srv/calcom
docker compose up -d --force-recreate calcom
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' "https://<DOMAIN>/auth/login"); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://<DOMAIN>/signup"
```

You should see: another slow loop, because a recreated container rewrites the built URL again,
and then a 3xx status whose redirect URL contains `/auth/error`.

If you do not: a `200` from that last command means the variable did not take. Sign in and turn
on the `disable-signup` flag at https://<DOMAIN>/settings/admin/flags instead, then run the last
command again. One thing that is not a fault: the `Create an account` link stays visible on the
login page, because that link is drawn by JavaScript compiled into the image, while the page
behind it now refuses. A green `docker compose ps` is not success; that redirect to `/auth/error`
is.

## 8. First backup and restore

Two artifacts. The database holds every event type, booking and encrypted calendar credential.
The config archive holds what rebuilds the service around it.

```bash
cd /srv/calcom
docker compose exec -T postgres pg_dump -U calcom -d calcom | gzip > /srv/calcom/backups/calcom-db-$(date +%F).sql.gz
sudo tar -C /srv/calcom -czf /srv/calcom/backups/calcom-config-$(date +%F).tar.gz compose.yml .env
ls -lh /srv/calcom/backups/
```

You should see: two files, the dump a few hundred kilobytes on a fresh install and the config
archive a couple of kilobytes. Nothing goes offline: `pg_dump` snapshots a running database
consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/calcom
scp vps:/srv/calcom/backups/* ~/backups/calcom/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/calcom/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one empty account:

```bash
cd /srv/calcom
docker compose down
sudo rm -rf /srv/calcom/postgres
sudo install -d -m 700 /srv/calcom/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/calcom/backups/calcom-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U calcom -d calcom
docker compose up -d
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then the containers coming back. Wait
for the slow first boot again, then sign in with the account you made in step 7. If it lets you
in, the restore worked.

If you do not: `role "calcom" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the config archive
is for before you skip it: `CALENDSO_ENCRYPTION_KEY` lives in .env, every calendar credential in
that dump is encrypted with it, and a database restored beside a newly generated key is a table
of unreadable tokens.

## 9. Updating later

New versions are listed at https://github.com/calcom/cal.diy/releases. Take both backup
artifacts first, then edit the `image:` line in /srv/calcom/compose.yml to the new tag and its
digest, keeping the `-arm` suffix if you are on arm64.

```bash
cd /srv/calcom
docker compose pull
docker compose up -d
docker compose logs --tail 40 calcom
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done. One thing to know about this project's
release cadence: the repository was renamed to cal.diy after 6.2.0 and no release has been cut
under the new name, so there may be nothing to update to for a while.

## 10. What will probably go wrong

The first boot looks like a failed install for a long time. The entrypoint greps and rewrites
every file in the compiled Next.js output before doing anything else, then waits for PostgreSQL,
then runs the migrations, then seeds the app store, and only then does anything listen on 3000.
I watched Caddy return `502` for nine minutes on a 4 GB box and went looking for what I had
broken. Nothing was. Run `docker compose logs -f calcom` and read it instead of restarting:
while `Replacing all statically built instances` or a Prisma migration name is on screen, it is
working. Restarting begins that sequence again.

## 11. Out of scope

- Do not configure Google Calendar or Outlook sync. Both need an OAuth client you register in
  your own Google Cloud or Azure tenant, a separate sitting.
- Do not enable organizations. `ORGANIZATIONS_ENABLED` wants a wildcard subdomain and a second
  hostname, and this install serves one domain.
- Do not add the API v2 container or Prisma Studio from upstream's compose file.
- Do not set `CALCOM_LICENSE_KEY`. That is the commercial licence for the enterprise features,
  and this install runs the free one the wizard offers in step 7.
