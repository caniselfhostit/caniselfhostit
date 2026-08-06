You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Cal.com 6.2.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname becomes
`NEXT_PUBLIC_WEBAPP_URL`, the container rewrites its own compiled-in address to match it, and
every booking link the user hands out carries it.

Cal.com needs 4096 MB of RAM available and 15 GB free on /srv: the image is 1.5 GB compressed,
before PostgreSQL. Measure four things:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 15 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop. The architecture
decides one line in step 4: upstream ships no multi-architecture manifest, so amd64 and arm64
are separate tags.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/calcom /srv/calcom/backups
sudo install -d -m 700 /srv/calcom/postgres
ls -la /srv/calcom
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root. The PostgreSQL image chowns its own data directory on first start, so leave that alone.
Cal.com keeps nothing else on disk: bookings, avatars and calendar credentials are database
rows.

## 3. Secrets

Three secrets: the PostgreSQL password, the NextAuth session secret, and the encryption key over
saved calendar credentials. Generate all three on the server. Do not print any of them, do not
repeat them in your summary, and do not put them in any log line. Upstream documents
`openssl rand -base64 32` for the session secret and `openssl rand -base64 24` for the
encryption key, the 32-character key AES-256 wants; the database password is hex, so nothing in
the connection string needs escaping.

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

Assert: the file exists with mode `-rw-------`. Tell the user `CALENDSO_ENCRYPTION_KEY` is the
one value they cannot regenerate: every Google or Outlook connection they later add is encrypted
with it, and replacing it turns those rows into noise. The five `CHANGE_ME` lines are the
outbound relay, and Cal.com mails the confirmation to whoever booked, so it is not optional.

STOP: tell the user to open `nano /srv/calcom/.env`, replace every `CHANGE_ME` with the matching
value from their mail relay, correct `EMAIL_SERVER_PORT` if it is not 587, save, and confirm. Do
not continue until they do, and do not ask them to paste those values to you.

```bash
grep -c CHANGE_ME /srv/calcom/.env || true
```

Assert: that prints `0`. It counts lines, never values.

## 4. compose.yml

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

That pins the amd64 build. If step 1 printed `arm64`, switch the image line to the release's
arm64 tag. On amd64 this changes nothing:

```bash
if [ "$(dpkg --print-architecture)" = "arm64" ]; then
  sed 's|:v6.2.0@sha256:[a-f0-9]*|:v6.2.0-arm@sha256:4b0fa72eec13bd3ddb608a6d13f05bf0ebc136e73832abfe1a8ec145db9e4651|' /srv/calcom/compose.yml > /srv/calcom/compose.arm && mv /srv/calcom/compose.arm /srv/calcom/compose.yml
fi
grep -n 'image:' /srv/calcom/compose.yml
cd /srv/calcom && docker compose config >/dev/null && echo "compose OK"
```

Assert: `grep` prints two image lines, the Cal.com one carrying `-arm` only on an arm64 host,
and the last command prints `compose OK`. No password is in this file: compose reads
`${POSTGRES_PASSWORD}` from /srv/calcom/.env to build the connection strings.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-calcom, reload, and report what it objected to. Caddy asks for the
certificate on the first request and renews it itself.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box nothing changes:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects, 443/tcp is the only way in, 443/udp is HTTP/3.
8094 stays closed because compose binds it to 127.0.0.1, and 5432 because compose never
publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8094 or 5432.

## 7. Start and verify

On a fresh container the entrypoint rewrites every compiled-in copy of the built URL, waits for
PostgreSQL, migrates and seeds the app store before Next.js listens. Budget fifteen minutes and
touch nothing while the loop runs.

```bash
cd /srv/calcom
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' "https://<DOMAIN>/auth/setup?step=1"); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS "https://<DOMAIN>/auth/setup?step=1" | grep -o '<title>[^<]*</title>'
curl -sS -o /dev/null -w '%{http_code}\n' "https://<DOMAIN>/signup"
```

Assert all three, and print what you received for each. The loop ends printing `200`. The title
line reads exactly `<title>Setup | Cal.com</title>`. The last prints `200`, because registration
is open on a fresh install and the next step closes it. If any of the three misses, stop, run
`docker compose logs --tail 60 calcom` and `docker compose logs --tail 20 postgres`, and name
the likely cause: a database that never reports healthy points at step 2; a `502` after the loop
expires means the container is still migrating; `CLIENT_FETCH_ERROR` means
`NEXT_PUBLIC_WEBAPP_URL` from step 3 does not match the hostname Caddy serves. A running
container is not success.

The first screen at https://<DOMAIN>/auth/setup?step=1 is a wizard headed `Administrator user`,
with `Let's create the first administrator user.` under it.

STOP: tell the user to open https://<DOMAIN>/auth/setup?step=1, create that first account, and
wait. Do not continue until they confirm. Upstream's password rule is strict: 15 characters at
least, one number, both cases. Step 2 asks them to pick a licence, and the free AGPLv3 option is
the one this install runs under.

Once they confirm, close registration and prove it is closed:

```bash
printf 'NEXT_PUBLIC_DISABLE_SIGNUP=true\n' >> /srv/calcom/.env
cd /srv/calcom
docker compose up -d --force-recreate calcom
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' "https://<DOMAIN>/auth/login"); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://<DOMAIN>/signup"
```

Assert: the last line is a 3xx status whose redirect URL contains `/auth/error`. Recreating
rewrites the built URL again, so this loop is slow too. Tell the user the `Create an account`
link stays on the login page, because it is drawn by JavaScript compiled into the image, while
the page behind it now refuses. If the assert still returns `200`, sign in and turn on
`disable-signup` at https://<DOMAIN>/settings/admin/flags.

## 8. First backup and restore

Two artifacts: the database holds every event type, booking and encrypted calendar credential;
the config archive holds what rebuilds the service around it.

```bash
cd /srv/calcom
docker compose exec -T postgres pg_dump -U calcom -d calcom | gzip > /srv/calcom/backups/calcom-db-$(date +%F).sql.gz
sudo tar -C /srv/calcom -czf /srv/calcom/backups/calcom-config-$(date +%F).tar.gz compose.yml .env
ls -lh /srv/calcom/backups/
```

Assert: both files exist and are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. A backup on the same disk is not a backup, so run
this from the user's machine:

```bash
mkdir -p ~/backups/calcom
scp vps:/srv/calcom/backups/* ~/backups/calcom/
```

To restore: `docker compose down`, `sudo rm -rf /srv/calcom/postgres`, recreate that directory
as in step 2, untar the config archive into /srv/calcom so .env is back before anything starts,
`docker compose up -d postgres`, wait for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U calcom -d calcom`, then `docker compose up -d`. Tell
the user why the archive matters as much as the dump: `CALENDSO_ENCRYPTION_KEY` lives in .env,
the calendar credentials are encrypted with it, and a dump restored beside a new key is a table
of unreadable tokens.

## 9. Updating later

New versions are listed at https://github.com/calcom/cal.diy/releases. Take both backups first,
then edit the image line in /srv/calcom/compose.yml to the new tag and digest, keeping the
`-arm` suffix on an arm64 host:

```bash
cd /srv/calcom
docker compose pull
docker compose up -d
docker compose logs --tail 40 calcom
```

Cal.com migrates on the way up, so watch that log until it settles, then re-run step 7's health
check before calling the update done. The project renamed its repository to cal.diy after 6.2.0
and has cut no release under that name yet.

## 10. What will probably go wrong

The first boot looks like a failed install for a long time. The entrypoint rewrites every file
in the compiled Next.js output, waits for PostgreSQL, migrates, seeds the app store, and only
then does anything listen on 3000. I watched Caddy return `502` for nine minutes on a 4 GB box
and went looking for what I had broken. Nothing was. Run `docker compose logs -f calcom` and
read it instead of restarting: while `Replacing all statically built instances` or a Prisma
migration name is on screen, it is working. Restarting begins that sequence again.

## 11. Out of scope

- Do not configure Google Calendar or Outlook sync. Both need an OAuth client the user registers
  in their own Google Cloud or Azure tenant, a separate sitting.
- Do not enable organizations. `ORGANIZATIONS_ENABLED` wants a wildcard subdomain and a second
  hostname, and this install serves one domain.
- Do not add the API v2 container or Prisma Studio from upstream's compose file.
- Do not set `CALCOM_LICENSE_KEY`. That is the commercial licence for the enterprise features,
  and this install runs the free one the wizard offers in step 7.
