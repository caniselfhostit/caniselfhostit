This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Documenso 2.16.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. Documenso will not let anyone sign in, you included, until that
account's email address has been confirmed by clicking a link it emails. So you need an SMTP
relay you can already send through, with its hostname, its port and your username on it, before
you start. `<ADMIN_EMAIL>` below is the address your first account will use.

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
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of
available RAM is the number to take seriously here: Next.js and PostgreSQL in the same box on a
1 GB plan will pass this install and then meet the OOM killer during the first upload.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/documenso /srv/documenso/backups
sudo install -d -m 700 /srv/documenso/postgres
ls -la /srv/documenso
```

You should see: `backups` owned by you, and `postgres` at mode `drwx------` owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. There is no `data` directory in this install: accounts, the audit trail
and the signed PDFs themselves are all rows in that database.

## 3. Secrets and the signing certificate

Five secrets are generated here, on the server: three application keys, the database password
and the passphrase on the signing certificate. Hex rather than base64, because one of them
rides inside a PostgreSQL connection string. Replace `smtp.example.net`, `587` and both
`<ADMIN_EMAIL>` lines with your own values before you paste.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/documenso/.env` and
carry on.

Do not paste that file, any of those five values, or any command output containing them into
this chat window. The agent path never sees them; this path hands them to a third party unless
you keep them out yourself.

Two of those keys deserve a warning of their own. `NEXT_PRIVATE_ENCRYPTION_KEY` and
`NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY` are what the encrypted columns in the database are read
back with. Change either one later and the stored data stops being readable, which is why step
8 backs `.env` up beside the database dump and treats the two as one artifact.

Now add the relay password. It is the one secret here you already own, and it is typed rather
than generated. The third line waits with no prompt and echoes nothing:

```bash
umask 077
printf 'NEXT_PRIVATE_SMTP_PASSWORD=' >> /srv/documenso/.env
read -rs && printf '%s\n' "$REPLY" >> /srv/documenso/.env
unset REPLY
chmod 600 /srv/documenso/.env
awk -F= '/^NEXT_PRIVATE_SMTP_PASSWORD/ {print "recorded, length " length($2)}' /srv/documenso/.env
```

You should see: `recorded, length` and a number greater than zero. The number is the only thing
about that password that ever appears on your screen.

If you do not: no output at all means the line never landed, so run the block again. A length of
0 means you pressed Return before typing anything.

Documenso ships no signing certificate, and without one it starts, serves pages, and fails every
signature. Make a self-signed one now. Ten years rather than the one year upstream's example
uses, because a signing certificate that expires quietly turns into failed signings nobody
diagnoses:

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

You should see: one file, a couple of kilobytes, mode `-r--------`, owner and group `1001`.

If you do not: `unable to load Private Key` means the `genrsa` line did not run, so start the
block again from the top. `1001` is the account inside the image, and upstream documents both
that ownership and the rule that the certificate must carry a password at all. What this
certificate is, plainly: it proves a completed document has not been altered since signing, and
it carries the name you put in the subject. What it is not: a certificate Adobe Acrobat
recognises. Acrobat will show a warning that the signature cannot be verified, and only a
certificate bought from an authority on Adobe's trust list changes that.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/documenso/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/documenso/compose.yml` and paste again in one go. Upstream's own compose file
publishes 3000 on every interface and pins nothing; this one binds loopback and pins digests.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-documenso /etc/caddy/Caddyfile`, reload,
and paste again. Caddy asks for the certificate on the first request and renews it on its own,
so there is nothing to schedule. Two certificates now exist in this install and they do
different jobs: this one proves the website is yours, the one from step 3 signs the documents.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8142` or `5432`.

If you do not: delete anything for those two with `sudo ufw delete allow 8142`. 8142 is bound to
127.0.0.1 by the compose file and 5432 is never published, so the database has no host port a
rule could apply to. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the
only way in, 443/udp is HTTP/3. Nothing here opens 25, 465 or 587: this box sends through your
relay and accepts no mail. `Status: inactive` is a different problem, because Prompt Zero left
this firewall enabled, so `sudo ufw enable` before you go any further.

## 7. Start and verify

The container runs the database migrations on the way up, so the first start is the slow one.

```bash
cd /srv/documenso
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health
curl -sS https://<DOMAIN>/signin | grep -c 'Sign in to your account'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/signup
```

You should see, in order: the loop reaching `200`, a JSON object containing
`"certificate":{"status":"ok"}`, then `1`, then `200`.

If you do not: `"certificate":{"status":"warning"}` is the interesting failure. It means the app
is running and cannot read your certificate, so signing would fail silently later; check the
ownership line in step 3, then run `docker compose logs --tail 20 documenso` and look for the
line about the certificate file. A loop that never reaches `200` usually means the database:
run `docker compose logs --tail 20 postgres` first and `docker compose logs --tail 40 documenso`
second. `502` from Caddy means the container is not up yet, and the first migration can take a
few minutes. A running container is not success.

The first screen at https://<DOMAIN> is the sign-in page, with the heading
`Sign in to your account`.

Now open https://<DOMAIN>/signup in a browser, create your account with `<ADMIN_EMAIL>`, open
the confirmation email Documenso sends you, click the link in it, and sign in. Do this before
the next block: until you do, anyone who finds the hostname can create the first account
instead of you.

Once you are signed in, close registration and prove it closed:

```bash
sed -i 's/^NEXT_PUBLIC_DISABLE_SIGNUP=false$/NEXT_PUBLIC_DISABLE_SIGNUP=true/' /srv/documenso/.env
docker compose up -d --force-recreate documenso
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/signup
```

You should see: `302`, not `200`. With signups disabled the app redirects /signup to the sign-in
page, and that redirect is the security check in this step.

If you do not: a `200` means the container kept its old environment, so run
`docker compose up -d --force-recreate documenso` again and re-check. Leaving it at `200` leaves
your hostname open to anyone who finds it.

## 8. First backup and restore

Two artifacts. The dump holds the accounts, the audit trail and the documents themselves,
because the default upload transport keeps every PDF in the database. The config archive holds
what rebuilds the service around it, certificate included.

```bash
cd /srv/documenso
docker compose exec -T postgres pg_dump -U documenso -d documenso | gzip > /srv/documenso/backups/documenso-db-$(date +%F).sql.gz
sudo tar -czf /srv/documenso/backups/documenso-config-$(date +%F).tar.gz -C /srv/documenso compose.yml .env cert.p12 -C /etc/caddy Caddyfile
ls -lh /srv/documenso/backups/
```

You should see: two files, the dump a few tens of kilobytes on a fresh install and the config
archive a few kilobytes. Nothing goes offline: `pg_dump` snapshots a running database
consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/documenso
scp vps:/srv/documenso/backups/* ~/backups/documenso/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/documenso/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one empty account:

```bash
cd /srv/documenso
docker compose down
sudo rm -rf /srv/documenso/postgres
sudo install -d -m 700 /srv/documenso/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/documenso/backups/documenso-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U documenso -d documenso
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/signin
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command, and
your account still works when you sign in again.

If you do not: `role "documenso" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand what the pairing means
before you skip this: the dump on its own restores nothing readable, because the encrypted
columns are read with the keys in `.env`, and a document signed by a certificate you no longer
hold cannot be signed again by the same identity.

## 9. Updating later

Versions are listed at https://github.com/documenso/documenso/releases and the image tags at
https://github.com/documenso/documenso/pkgs/container/documenso. Upstream tags and builds before
writing the notes, so the newest tag can sit one ahead of that page. Back up both artifacts,
then edit the image line in /srv/documenso/compose.yml to the new tag and digest.

```bash
cd /srv/documenso
docker compose pull
docker compose up -d
docker compose logs --tail 30 documenso
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one existing document as
well, because an instance that answers `"status":"ok"` can still have stopped rendering
signatures if a migration halted halfway.

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
  is your purchase, not this install's.
- Do not set `NEXT_PRIVATE_DOCUMENSO_LICENSE_KEY` or configure CSC signing. Both belong to the
  paid enterprise edition and need a subscription this install does not have.
- Do not configure S3 storage, switch `NEXT_PUBLIC_UPLOAD_TRANSPORT`, or add Google, Microsoft
  or OIDC sign-in. Documents stay in the database, which is what makes one dump the whole
  backup, and email with a password is a working way in.
