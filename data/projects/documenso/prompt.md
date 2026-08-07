You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Documenso 2.16.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask for both once and stop until the user
answers. The A record must already point here. In the same message ask for three more things
and stop asking: an SMTP relay hostname, its port, and their username. Do not ask for the
relay password; a `STOP:` in step 3 has the user type that in.

Tell them one thing before anything installs: nobody signs in until that account's email
address is confirmed through a link Documenso mails out. Mail here is the front door.

Documenso needs 2048 MB of RAM available and 10 GB free on /srv, on amd64 or arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If RAM is under 2048 MB or disk under 10 GB, print both and stop. Do not install and hope. If
`dig +short` prints nothing, stop: Caddy cannot certify a hostname that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/documenso /srv/documenso/backups
sudo install -d -m 700 /srv/documenso/postgres
ls -la /srv/documenso
```

Assert: `ls -la` shows `backups` owned by the login user and `postgres` at mode `700` owned by
root, which the PostgreSQL image chowns itself on first start. Everything Documenso keeps,
signed PDFs included, is a row in the database inside it.

## 3. Secrets and the signing certificate

Five secrets are generated here: three application keys, the database password, and the
passphrase on the signing certificate. Do not print any of them, repeat them in your summary,
or log them. Hex, not base64: one rides inside a connection string.

```bash
umask 077
cat > /srv/documenso/.env <<EOF
NEXT_PUBLIC_WEBAPP_URL=https://<DOMAIN>
NEXT_PRIVATE_INTERNAL_WEBAPP_URL=http://localhost:3000
NEXTAUTH_SECRET=$(openssl rand -hex 32)
NEXT_PRIVATE_ENCRYPTION_KEY=$(openssl rand -hex 32)
NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH=/opt/documenso/cert.p12
NEXT_PRIVATE_SIGNING_PASSPHRASE=$(openssl rand -hex 24)
NEXT_PRIVATE_SMTP_HOST=smtp.example.net
NEXT_PRIVATE_SMTP_PORT=587
NEXT_PRIVATE_SMTP_USERNAME=<ADMIN_EMAIL>
NEXT_PRIVATE_SMTP_FROM_NAME=Documenso
NEXT_PRIVATE_SMTP_FROM_ADDRESS=<ADMIN_EMAIL>
NEXT_PUBLIC_DISABLE_SIGNUP=false
DOCUMENSO_DISABLE_TELEMETRY=true
EOF
chmod 600 /srv/documenso/.env
ls -l /srv/documenso/.env
```

Replace `smtp.example.net`, `587` and both `<ADMIN_EMAIL>` lines with the step 1 values first.
Assert: mode `-rw-------`. Tell the user the encryption keys are how the encrypted columns are
read back, so changing either later makes stored data unreadable.

STOP: tell the user to run the block below on the server from their own terminal, so the relay
password never enters this session, and to report what the last line printed.
Do not continue until they confirm. The `read` line waits with no prompt and echoes nothing.

```bash
umask 077
printf 'NEXT_PRIVATE_SMTP_PASSWORD=' >> /srv/documenso/.env
read -rs && printf '%s\n' "$REPLY" >> /srv/documenso/.env
unset REPLY
chmod 600 /srv/documenso/.env
awk -F= '/^NEXT_PRIVATE_SMTP_PASSWORD/ {print "recorded, length " length($2)}' /srv/documenso/.env
```

Assert: a length greater than 0. Nothing printed means the line is missing.

Now the signing certificate. Documenso ships none: without one it starts, serves pages and
fails every signature. This one is self-signed and lasts ten years, because one that expires
quietly becomes failed signings nobody diagnoses.

```bash
umask 077
openssl genrsa -out /srv/documenso/private.key 2048
openssl req -new -x509 -key /srv/documenso/private.key -out /srv/documenso/certificate.crt -days 3650 -subj "/CN=<DOMAIN>/O=<DOMAIN>"
CERT_PASS=$(sed -n 's/^NEXT_PRIVATE_SIGNING_PASSPHRASE=//p' /srv/documenso/.env) openssl pkcs12 -export -out /srv/documenso/cert.p12 -inkey /srv/documenso/private.key -in /srv/documenso/certificate.crt -password env:CERT_PASS
rm -f /srv/documenso/private.key /srv/documenso/certificate.crt
sudo chown 1001:1001 /srv/documenso/cert.p12
sudo chmod 400 /srv/documenso/cert.p12
umask 022
ls -l /srv/documenso/cert.p12
```

Assert: `cert.p12` exists, is not empty, and reads `-r--------` owned by `1001`, the account
inside the image. Upstream documents both that uid and the rule that the file carry a
password.

## 4. compose.yml

```bash
cat > /srv/documenso/compose.yml <<'EOF'
# Documenso · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose deployment . https://docs.documenso.com/docs/self-hosting/deployment/docker-compose
#   signing certificate  https://docs.documenso.com/docs/self-hosting/configuration/signing-certificate/local
#
# Two services: Documenso and PostgreSQL, upstream's only supported engine, 14
# or later. Signed PDFs are rows in it, and the only state outside it is the
# signing certificate, mounted from the host because one made inside a container
# dies with it. Digests read on 2026-08-06; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: documenso-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: documenso
      POSTGRES_USER: documenso
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/documenso/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U documenso -d documenso"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  documenso:
    image: ghcr.io/documenso/documenso:v2.16.0@sha256:945bd2c04306bd5d78def0c4ceafdffb6b0a106cd6a2543db5acda9a6424b2d9
    container_name: documenso
    restart: unless-stopped
    env_file: /srv/documenso/.env
    environment:
      PORT: "3000"
      # One database, named twice: upstream wants a pooled URL and a direct URL
      # for migrations, and allows one string for both with no pooler in front.
      NEXT_PRIVATE_DATABASE_URL: postgresql://documenso:${DB_PASSWORD}@postgres:5432/documenso
      NEXT_PRIVATE_DIRECT_DATABASE_URL: postgresql://documenso:${DB_PASSWORD}@postgres:5432/documenso
    volumes:
      # The signing certificate, read-only. The image runs as uid 1001, which
      # is why step 3 hands this file to 1001 first.
      - /srv/documenso/cert.p12:/opt/documenso/cert.p12:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8142.
      - "127.0.0.1:8142:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/documenso && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Upstream's own compose publishes 3000 on every interface and
pins nothing; this one binds loopback and pins digests.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-documenso
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Documenso · the Caddy site block for this service.
#
# Authored by caniselfhostit from https://caddyserver.com/docs/automatic-https
# and https://docs.documenso.com/docs/self-hosting/deployment/docker-compose
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also NEXT_PUBLIC_WEBAPP_URL in .env, and it is the address inside every
# signing link Documenso mails out, so the two have to agree.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# No X-Frame-Options: Documenso publishes an embeddable signing view, and a
	# blanket SAMEORIGIN would break it later. No body limit either, because a
	# scanned contract is often several megabytes.
	#
	# 8142 is the loopback port compose publishes here. It is not a container
	# port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8142
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-documenso, reload, and report what it said. Caddy gets the
certificate on the first request and renews it alone. That one is for the website; step 3's
signs documents.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero already configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8142 stays closed because it is bound to 127.0.0.1, 5432 because compose publishes
no host port, and nothing opens 25, 465 or 587: this box sends through the user's relay and
accepts no mail. Assert: `ufw status verbose` prints `Status: active` with 80, 443/tcp and
443/udp, and no rule for 8142 or 5432.

## 7. Start and verify

Migrations run inside the container on the way up, so the first start is slow.

```bash
cd /srv/documenso
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health
curl -sS https://<DOMAIN>/signin | grep -c 'Sign in to your account'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/signup
```

Assert all four and print what you received. The loop ends on `200`. The health body contains
`"certificate":{"status":"ok"}`, which is step 3's certificate being read rather than merely
present; a `"warning"` there means the container cannot open that file. The `grep -c` prints
`1`: the first screen at https://<DOMAIN> is the sign-in page, heading
`Sign in to your account`. The last curl prints `200`, so registration is open, correct for one
more step. If any of the four misses, stop, run
`docker compose logs --tail 40 documenso` and `docker compose logs --tail 20 postgres`, and
name the likely earlier step: a database that never reports healthy is step 2, a `502` is step
5. A running container is not success.

STOP: tell the user to open https://<DOMAIN>/signup, create the first account with
`<ADMIN_EMAIL>`, click the link in the confirmation mail, and sign in, and wait.
Do not continue until they confirm. That proves the hostname is theirs before a stranger
finds it, and that their relay delivers. If the mail never lands, step 10 is about that.

Once they confirm, close registration and prove it closed:

```bash
sed -i 's/^NEXT_PUBLIC_DISABLE_SIGNUP=false$/NEXT_PUBLIC_DISABLE_SIGNUP=true/' /srv/documenso/.env
docker compose up -d --force-recreate documenso
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/signup
```

Assert: this prints `302`, not `200`. With signups disabled the app redirects /signup to the
sign-in page, and that redirect is the security assert here. A `200` means the container never
took the change and the hostname stands open.

## 8. First backup and restore

Two artifacts. The dump holds the accounts, the audit trail and the documents, because the
default upload transport keeps every PDF in the database. The config archive holds what
rebuilds the service around it.

```bash
cd /srv/documenso
docker compose exec -T postgres pg_dump -U documenso -d documenso | gzip > /srv/documenso/backups/documenso-db-$(date +%F).sql.gz
sudo tar -czf /srv/documenso/backups/documenso-config-$(date +%F).tar.gz -C /srv/documenso compose.yml .env cert.p12 -C /etc/caddy Caddyfile
ls -lh /srv/documenso/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing stops: `pg_dump`
snapshots a running database consistently. A backup on the same disk is not a backup, so run
this from the user's machine:

```bash
mkdir -p ~/backups/documenso
scp vps:/srv/documenso/backups/* ~/backups/documenso/
```

To restore: `docker compose down`, `sudo rm -rf /srv/documenso/postgres`, recreate it as in
step 2, untar the config archive into /srv/documenso, `docker compose up -d postgres`, wait for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U documenso -d documenso`, then `docker compose up -d`.
Say why the two travel together: the dump alone is unreadable without the keys in `.env`.

## 9. Updating later

Versions are listed at https://github.com/documenso/documenso/releases and the image tags at
https://github.com/documenso/documenso/pkgs/container/documenso. Upstream tags and builds
before writing the notes, so the newest tag can sit one ahead of that page. Back up both
artifacts, then edit the image line in compose.yml to the new tag and digest:

```bash
cd /srv/documenso
docker compose pull
docker compose up -d
docker compose logs --tail 30 documenso
```

Migrations run on the way up. Watch that log until it settles, then re-run step 7's health
check.

## 10. What will probably go wrong

The confirmation mail will not arrive, and everything else will look right while it does not.
Hetzner and DigitalOcean block outbound 25, 465 and 587 on new accounts until you ask them not
to, and a relay that refuses the credential fails the same way. I sat on the sign-in page for
ten minutes typing a password that was right, being told the account was not verified, before I
read the log. Run `docker compose logs --tail 40 documenso` and look for the connection to the
relay. Until that mail lands, nobody signs in.

## 11. Out of scope

- Do not buy or install a certificate from a Certificate Authority. Step 3's self-signed one
  proves the document has not changed since signing; making Adobe Acrobat show a green check
  is the user's purchase, not this install's.
- Do not set `NEXT_PRIVATE_DOCUMENSO_LICENSE_KEY` or configure CSC signing. Both belong to the
  paid enterprise edition and need a subscription this install does not have.
- Do not configure S3 storage, switch `NEXT_PUBLIC_UPLOAD_TRANSPORT`, or add Google, Microsoft
  or OIDC sign-in. Documents stay in the database, which is what makes one dump the whole
  backup, and email with a password is a working way in.
