You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Documenso 2.16.0, with the PostgreSQL it keeps documents in, under
~/selfhost/documenso, answering at http://localhost:8142.

## 1. Preflight

Say this to the user before step 2 runs. Every signing link here starts with
http://localhost:8142, which means "this computer" wherever it is read, and nothing here sends
mail. This is a private place to keep and sign your own documents, not a way to collect
anyone else's.

Detect the OS and measure the machine.

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print too, for step 2. Documenso plus PostgreSQL needs 2048 MB of
RAM available and 10 GB free on the home disk, on amd64 or arm64. If RAM is under 2048 MB or
disk under 10 GB, print both and stop.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they
  confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/documenso/backups
ls -la ~/selfhost/documenso
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: everything
Documenso keeps is a row in PostgreSQL, in the volume step 5 declares.

## 4. Secrets and the signing certificate

Five secrets: three application keys, the database password, and the certificate passphrase.
Print none of them, and keep them out of your summary and out of any log.

```bash
umask 077
cat > ~/selfhost/documenso/.env <<EOF
NEXT_PUBLIC_WEBAPP_URL=http://localhost:8142
NEXT_PRIVATE_INTERNAL_WEBAPP_URL=http://localhost:3000
NEXTAUTH_SECRET=$(openssl rand -hex 32)
NEXT_PRIVATE_ENCRYPTION_KEY=$(openssl rand -hex 32)
NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH=/opt/documenso/cert.p12
NEXT_PRIVATE_SIGNING_PASSPHRASE=$(openssl rand -hex 24)
NEXT_PRIVATE_SMTP_FROM_NAME=Documenso
NEXT_PRIVATE_SMTP_FROM_ADDRESS=documenso@localhost
NEXT_PUBLIC_DISABLE_SIGNUP=false
DOCUMENSO_DISABLE_TELEMETRY=true
EOF
chmod 600 ~/selfhost/documenso/.env
ls -l ~/selfhost/documenso/.env
```

Assert: mode `-rw-------`. On Windows those bits are advisory: NTFS does not enforce them, and
the real boundary is the user's own account. The encryption keys are how the encrypted
columns are read back: change either later and stored data is unreadable.

Documenso ships no signing certificate, and without one it starts, serves pages and fails every
signature. Make a self-signed one, good for ten years, because one that expires quietly becomes
failed signings.

```bash
cd ~/selfhost/documenso
umask 077
openssl genrsa -out private.key 2048
MSYS_NO_PATHCONV=1 openssl req -new -x509 -key private.key -out certificate.crt -days 3650 -subj "/CN=localhost/O=localhost"
CERT_PASS=$(sed -n 's/^NEXT_PRIVATE_SIGNING_PASSPHRASE=//p' ~/selfhost/documenso/.env) openssl pkcs12 -export -out cert.p12 -inkey private.key -in certificate.crt -password env:CERT_PASS
rm -f private.key certificate.crt
chmod 444 cert.p12
umask 022
ls -l cert.p12
```

Assert: `cert.p12` exists and is not empty. `MSYS_NO_PATHCONV=1` matters only in Git Bash,
where a subject starting with `/` is otherwise rewritten to a Windows path. The file is
world-readable on purpose: the container runs as uid 1001, and the key in it is encrypted.

## 5. compose.yml

```bash
cat > ~/selfhost/documenso/compose.yml <<'EOF'
# Documenso · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   compose deployment . https://docs.documenso.com/docs/self-hosting/deployment/docker-compose
#   signing certificate  https://docs.documenso.com/docs/self-hosting/configuration/signing-certificate/local
#
# Two services on the computer you are sitting at, every path relative to
# ~/selfhost/documenso/, which lets one file work on macOS, Linux and Windows.
# The database is a named volume, not a bind mount: PostgreSQL chowns its data
# directory to its own uid, which a home-directory bind mount cannot allow on
# Windows. The certificate is a bind mount, world-readable from step 4, because
# the image runs as uid 1001 and the key inside is encrypted anyway. No SMTP is
# configured here. Digests read on 2026-08-06; both images publish amd64 and
# arm64.
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
      - documenso-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U documenso -d documenso"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  documenso:
    image: ghcr.io/documenso/documenso:v2.16.0@sha256:945bd2c04306bd5d78def0c4ceafdffb6b0a106cd6a2543db5acda9a6424b2d9
    container_name: documenso
    restart: unless-stopped
    env_file: ./.env
    environment:
      PORT: "3000"
      # One database, named twice: upstream wants a pooled URL and a direct one.
      NEXT_PRIVATE_DATABASE_URL: postgresql://documenso:${DB_PASSWORD}@postgres:5432/documenso
      NEXT_PRIVATE_DIRECT_DATABASE_URL: postgresql://documenso:${DB_PASSWORD}@postgres:5432/documenso
    volumes:
      # The signing certificate, read-only inside the container.
      - ./cert.p12:/opt/documenso/cert.p12:ro
    ports:
      # Loopback only: no other device on the wifi can reach 8142.
      - "127.0.0.1:8142:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  documenso-pgdata:
EOF
cd ~/selfhost/documenso && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no
hostname to resolve and no public name to certify, and browsers treat http://localhost as a
secure context anyway, so pages needing crypto still work. Nothing is published past loopback:
8142 is bound to 127.0.0.1, which is not the user's phone, not a laptop on the same wifi, not
anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/documenso/compose.yml
```

Assert: that prints `1`, the published port line. PostgreSQL publishes no host port at all.

## 7. Start and verify

The container migrates the database on the way up, so the first start is slow.

```bash
cd ~/selfhost/documenso
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8142/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8142/api/health
curl -sS http://localhost:8142/signin | grep -c 'Sign in to your account'
```

Assert all three and print what you got. The loop ends on `200`. The health body contains
`"certificate":{"status":"ok"}`, step 4's certificate being read rather than merely present,
where a `"warning"` would mean the container cannot open it. The `grep -c` prints `1`: the
first
screen at http://localhost:8142 is the sign-in page, heading `Sign in to your account`. If any
of the three misses, stop, run `docker compose logs --tail 40 documenso`, and name the cause: a
database that never reports healthy is step 4, and `port is already allocated` means something
else holds 8142 (`lsof -nP -iTCP:8142 -sTCP:LISTEN`). A running container is not success.

STOP: tell the user to open http://localhost:8142/signup and create their account, and wait.
Do not continue until they confirm. They cannot sign in yet: Documenso holds a sign-in until
the address is confirmed, and it confirms by sending mail. Confirm it here instead:

```bash
docker compose exec -T postgres psql -U documenso -d documenso -c 'UPDATE "User" SET "emailVerified" = NOW() WHERE "emailVerified" IS NULL;'
```

Assert: `UPDATE 1`. `UPDATE 0` means no account was created, so go back a step.

STOP: tell the user to sign in at http://localhost:8142/signin and confirm they see the
document list, and wait. Do not continue until they confirm. Then close registration:

```bash
sed -i.bak 's/^NEXT_PUBLIC_DISABLE_SIGNUP=false$/NEXT_PUBLIC_DISABLE_SIGNUP=true/' ~/selfhost/documenso/.env
rm -f ~/selfhost/documenso/.env.bak
docker compose up -d --force-recreate documenso
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8142/signup
```

Assert: this prints `302`, not `200`. With signups disabled the app redirects /signup to the
sign-in page. `sed -i.bak` is the one form both the BSD sed on macOS and the GNU sed everywhere
else accept.

## 8. First backup and restore

Two artifacts: a dump with the accounts, the audit trail and every PDF, and a config archive
with the files that rebuild the service.

```bash
cd ~/selfhost/documenso
docker compose exec -T postgres pg_dump -U documenso -d documenso | gzip > ~/selfhost/documenso/backups/documenso-db-$(date +%F).sql.gz
tar -C ~/selfhost/documenso -czf ~/selfhost/documenso/backups/documenso-config-$(date +%F).tar.gz compose.yml .env cert.p12
ls -lh ~/selfhost/documenso/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing stops: `pg_dump` snapshots
a running database.

Both sit on the same disk as the data, and on a laptop the disk and the machine fail together.
Ask the user for a destination off this computer, a folder their sync service watches or a USB
stick, and copy both there with `cp`. Assert: the user confirms both filenames are there, and
if they have neither, say plainly that there is no backup.

To restore, in this order: untar the config archive into ~/selfhost/documenso first, so .env is
back before any container starts, because PostgreSQL takes `DB_PASSWORD` from it the moment it
initialises an empty volume. Then `docker compose down -v`, the one place `-v` belongs,
`docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T postgres psql -U documenso -d documenso`, then
`docker compose up -d`. The dump alone is unreadable without the keys in `.env`.

## 9. Updating later

Versions are listed at https://github.com/documenso/documenso/releases and the image tags at
https://github.com/documenso/documenso/pkgs/container/documenso, which can run one ahead. Back
up first, then edit the image line in compose.yml:

```bash
cd ~/selfhost/documenso
docker compose pull
docker compose up -d
docker compose logs --tail 30 documenso
```

Migrations run on the way up: watch that log until it settles, then re-run step 7's check.

## 10. What will probably go wrong

I created the account, typed the right password, and was told the account was not verified. I
assumed I had mistyped it, made a second account, and got the same answer.
Nothing was broken: Documenso confirms an address by emailing a link, and this install sends no
mail. The UPDATE in step 7 is the fix, for that account and any later one.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP. An invitation from here links to http://localhost:8142, which resolves
  on this computer only.
- Do not buy a certificate from a Certificate Authority, set
  `NEXT_PRIVATE_DOCUMENSO_LICENSE_KEY`, or move `NEXT_PUBLIC_UPLOAD_TRANSPORT` to S3. Step 4's
  certificate already proves a document has not changed, the license key is the paid edition,
  and S3 moves documents out of this backup.
