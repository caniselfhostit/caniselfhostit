You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Linkwarden 2.16.0 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they
answer. Its A record must already point at this server. Linkwarden needs 2048 MB of RAM
available and 20 GB free on /srv, because preserving a page runs a headless Chromium and
each saved link can leave a screenshot, a PDF and an HTML copy behind. Both images publish
amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 20 GB, print both numbers and
stop: the failure mode here is the OOM killer arriving mid-import, which looks random and
is not. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/linkwarden /srv/linkwarden/backups /srv/linkwarden/data
sudo install -d -m 700 /srv/linkwarden/postgres
ls -la /srv/linkwarden
```

Assert: `ls -la` shows `backups`, `data` and `postgres` at mode `700`. The PostgreSQL
image chowns its own data directory on first start, so leave that one owned by root.

## 3. Secrets

Two secrets: the PostgreSQL password and the NextAuth signing secret. Generate both on the
server. Do not print either, do not repeat them in your summary, and do not put them in
any log line. Hex rather than base64, because the database password ends up inside a
connection URL where the base64 alphabet would need escaping.

```bash
umask 077
cat > /srv/linkwarden/.env <<EOF
NEXTAUTH_URL=https://<DOMAIN>/api/v1/auth
NEXT_PUBLIC_DISABLE_REGISTRATION=false
NEXTAUTH_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/linkwarden/.env
umask 022
ls -l /srv/linkwarden/.env
```

Assert: the file exists with mode `-rw-------`. `NEXTAUTH_URL` has to carry the
`/api/v1/auth` suffix, which upstream documents as a requirement, and registration is open
on purpose until step 7 closes it. Tell the user
`sudo grep -E 'POSTGRES_PASSWORD|NEXTAUTH_SECRET' /srv/linkwarden/.env` reads both values
and that they belong in a password manager now.

## 4. compose.yml

```bash
cat > /srv/linkwarden/compose.yml <<'EOF'
# Linkwarden · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   setup and env vars . https://docs.linkwarden.app/self-hosting/setup
#   variable reference . https://docs.linkwarden.app/self-hosting/environment-variables
#   reverse proxy ...... https://docs.linkwarden.app/self-hosting/reverse-proxy
#
# Two services: the app, and the PostgreSQL it needs. MeiliSearch is deliberately
# absent, because Linkwarden only starts its search client when MEILI_MASTER_KEY
# is set, so leaving it out costs a container and a secret. Tags and digests were
# read from the registries on 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: linkwarden-db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/linkwarden/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  linkwarden:
    image: ghcr.io/linkwarden/linkwarden:v2.16.0@sha256:d805877fb707d160b809027c302f84cfba11a248d7fdc12de90b4791f98e6b55
    container_name: linkwarden
    restart: unless-stopped
    env_file: /srv/linkwarden/.env
    environment:
      # Built here, not in .env: compose expands ${...} in this file.
      DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
    volumes:
      # Archives, screenshots, PDFs, uploads. STORAGE_FOLDER defaults to `data`
      # and the image's working directory is /data, hence /data/data.
      - /srv/linkwarden/data:/data/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8085.
      - "127.0.0.1:8085:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/linkwarden && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, and only the app publishes a port: 8085 on
loopback. MeiliSearch is absent on purpose, because Linkwarden only starts its search
client when `MEILI_MASTER_KEY` is set.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by
the real hostname. Copy the file first: a syntax error here takes down every other site on
the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-linkwarden
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Linkwarden · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.linkwarden.app/self-hosting/reverse-proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Upstream documents nginx
# only, and every forwarding header their example sets by hand is one Caddy sets
# on its own, which is why there is no header_up line below.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8085 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8085
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-linkwarden, reload, and report what it objected to. Caddy
requests the certificate on the first request and renews it without a cron job.

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
443/udp is HTTP/3. 8085 stays closed because it is bound to 127.0.0.1, and 5432 stays
closed because compose never publishes it: the database has no host port to firewall.
Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and
no rule for 8085 or 5432.

## 7. Start and verify

The first boot is slow: Prisma applies the whole schema before Next.js answers anything,
so a 502 for the first few minutes is normal.

```bash
cd /srv/linkwarden
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL https://<DOMAIN>/ | grep -ci 'linkwarden'
```

Assert: the loop ends printing `200`, and the second command prints a number greater than
`0`, because `Linkwarden` appears in the served document. Print what you actually received
for both. If the loop runs out, stop, run `docker compose logs --tail 50 linkwarden` and
`docker compose logs --tail 20 postgres`, and say which earlier step is the likely cause:
a database container that never reports healthy points at step 2, and a 502 that never
clears points at the migration in the app log. The first screen at https://<DOMAIN> is a
login form with fields for a username and a password, and a link to create an account.

STOP: tell the user to open https://<DOMAIN>/register, create their account, and wait. Do
not continue until they confirm they can sign in.

Once they confirm, close registration. A restart is not enough: upstream documents that
containers have to be recreated for a changed `.env` to take effect.

```bash
cd /srv/linkwarden
sed -i 's/^NEXT_PUBLIC_DISABLE_REGISTRATION=false$/NEXT_PUBLIC_DISABLE_REGISTRATION=true/' /srv/linkwarden/.env
grep NEXT_PUBLIC_DISABLE_REGISTRATION /srv/linkwarden/.env
docker compose down
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
```

STOP: tell the user to sign out, try to create a second account at
https://<DOMAIN>/register, and confirm it is refused. Do not continue until they confirm
the refusal.

Assert: the grep printed `true`, the loop printed `200`, and the user confirmed the second
registration was refused. All three. A running container is not success.

## 8. First backup and restore

Two artifacts, because there are two kinds of state: the database holds the links, tags
and account, and the data directory holds archived copies no dump contains.

```bash
cd /srv/linkwarden
docker compose exec -T postgres pg_dump -U postgres -d postgres | gzip > /srv/linkwarden/backups/linkwarden-db-$(date +%F).sql.gz
sudo tar -C /srv/linkwarden -czf /srv/linkwarden/backups/linkwarden-files-$(date +%F).tar.gz data .env
ls -lh /srv/linkwarden/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped,
because `pg_dump` snapshots a running database consistently, which is why it is dumped
rather than copied off disk. A backup on the same disk is not a backup, so run this from
the user's machine:

```bash
mkdir -p ~/backups/linkwarden
scp vps:/srv/linkwarden/backups/* ~/backups/linkwarden/
```

To restore: `docker compose down`,
`sudo rm -rf /srv/linkwarden/data /srv/linkwarden/postgres`, recreate both as in step 2,
`docker compose up -d postgres`, feed the dump back by piping `gunzip -c` on the `.sql.gz`
into `docker compose exec -T postgres psql -U postgres -d postgres`, untar the file
archive into /srv/linkwarden, then `docker compose up -d`. Tell the user the dump alone
gives links with dead previews and the archive alone gives files nothing points at. Both
or neither.

## 9. Updating later

New versions are listed at https://github.com/linkwarden/linkwarden/releases. Take both
backup artifacts first, then edit the image line in /srv/linkwarden/compose.yml to the new
tag and its digest:

```bash
cd /srv/linkwarden
docker compose pull
docker compose up -d
docker compose logs --tail 30 linkwarden
```

Prisma runs new migrations on the way up, so watch that log until it stops moving. A
database from a newer version will not load into an older image, which is why the backup
goes first.

## 10. What will probably go wrong

The first four minutes. `docker compose up -d` returned straight away, both containers
showed as running, and the hostname answered 502 for long enough that I reached for the
rollback. Nothing was broken: Prisma was applying the schema, and Next.js answers nothing
until that finishes. The tell is `docker compose logs -f linkwarden`, where the migration
lines visibly progress. If the log is moving, wait. If it has been silent for two minutes
and the answer is still 502, look at the database container.

## 11. Out of scope

- Do not add MeiliSearch. It is a third container and a third secret, and search over the
  text of archived pages is not what this prompt installs.
- Do not configure SMTP. Email verification and password reset stay off, which is
  survivable on a single-user install.
- Do not wire up an SSO or OAuth provider. Credentials login is on, and it is the only
  path here.
- Do not set an AI tagging key. Automatic tagging sends page text to a third party, and
  that is the user's decision.
