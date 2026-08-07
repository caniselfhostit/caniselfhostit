You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Keila 0.30.2 and the PostgreSQL it keeps contacts in, under ~/selfhost/keila, answering
at http://localhost:8145.

## 1. Preflight

Say this before step 2 runs. Keila here can
still hand campaigns to a relay, but every unsubscribe and confirmation link it writes begins
with http://localhost:8145, which to a recipient means their own computer. The honest use
here is a list the user builds and drafts against plus campaigns sent to themselves; mailing
anyone else hands them a message they cannot unsubscribe from.

Ask this too: do they have an SMTP relay account, with a host, port, username, password and a
from-address on a domain they control? Keila delivers nothing itself and will not start without
one: upstream reads those three at boot and halts when any is missing.

Detect the OS and measure:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. Keila plus
PostgreSQL needs 1024 MB of RAM available and 5 GB free on the home disk; under either floor,
print both numbers and stop. The Keila image is published for linux/amd64 only: on an Apple
Silicon Mac, where `uname -m` prints `arm64`, Docker Desktop emulates it, slower but working,
and on an arm64 Linux machine there is no emulation layer by default, so print the architecture
and stop.

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
mkdir -p ~/selfhost/keila/uploads ~/selfhost/keila/backups
ls -la ~/selfhost/keila
```

Assert: `ls -la` shows `uploads` and `backups`, both owned by the user. There is no `data`
folder: contacts, campaigns and forms are rows in PostgreSQL, in a Docker-managed volume.

## 4. Secrets

Three secrets, generated here: the PostgreSQL password, the Phoenix secret key base and the root
password. Print none of them, and keep all three out of your summary and any log.

```bash
umask 077
cat > ~/selfhost/keila/.env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 48)
URL_HOST=localhost
KEILA_USER=root@localhost
KEILA_PASSWORD=$(openssl rand -base64 30)
MAILER_SMTP_PORT=587
MAILER_ENABLE_STARTTLS=true
MAILER_SMTP_HOST=
MAILER_SMTP_USER=
MAILER_SMTP_FROM_EMAIL=
MAILER_SMTP_PASSWORD=
# the four blank lines above are the relay account, filled in by hand
EOF
chmod 600 ~/selfhost/keila/.env
umask 022
ls -l ~/selfhost/keila/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these run the same
everywhere. The seed creating the root account reads `KEILA_USER` and `KEILA_PASSWORD` on the
first start against an empty database; left unset it invents one and writes it into the
container log in clear text. On Windows those mode bits are advisory: NTFS does not enforce
them, and the user's own account is the real boundary.

STOP: tell the user to fill the relay settings in themselves and wait. Do not continue until
they confirm. Tell them to open ~/selfhost/keila/.env in a text editor and fill in the four
blank lines at the bottom: the relay hostname on `MAILER_SMTP_HOST`, the account name on
`MAILER_SMTP_USER`, a sending address on a domain they control on `MAILER_SMTP_FROM_EMAIL`, and
the password on `MAILER_SMTP_PASSWORD`. Port 587 with STARTTLS is set already; a relay
documenting 465 wants that port, `MAILER_ENABLE_STARTTLS=false` and `MAILER_ENABLE_SSL=true`.

## 5. compose.yml

```bash
cat > ~/selfhost/keila/compose.yml <<'EOF'
# Keila · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   installation ....... https://www.keila.io/docs/installation
#   configuration ...... https://www.keila.io/docs/configuration
#   root user seed ..... https://github.com/pentacent/keila/blob/v0.30.2/priv/repo/seeds.exs
#
# Two services, every path relative to ~/selfhost/keila/. The database is a
# named volume, not a bind mount: the PostgreSQL image chowns its data
# directory to its own uid, which a home-directory bind mount cannot allow on
# Windows. The SMTP relay is not optional: upstream reads the relay host,
# from-address and password at boot and halts when one is missing. Digests read
# 2026-08-06; Keila is amd64 only.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: keila-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: keila
      POSTGRES_USER: keila
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - keila-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keila -d keila"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  keila:
    image: pentacent/keila:0.30.2@sha256:b2fdb45228c94a0df0d7d1597009edaa663ff455999ddcf1dc1483d06631762b
    container_name: keila
    restart: unless-stopped
    env_file: ./.env
    environment:
      DB_URL: postgres://keila:${POSTGRES_PASSWORD}@db:5432/keila
      PORT: "4000"
      # Nothing terminates TLS; the browser address is localhost:8145, and the
      # links Keila writes have to say exactly that.
      URL_SCHEMA: http
      URL_PORT: "8145"
      # No sign-up form; .env's root user is the only account.
      DISABLE_REGISTRATION: "true"
      # HOME here is /opt/app; uploads default under it.
      USER_CONTENT_DIR: /opt/app/uploads
      # The digest above is the pin; this check has nothing to act on.
      DISABLE_UPDATE_CHECKS: "true"
    volumes:
      # Root-owned on Linux: the image declares no USER.
      - ./uploads:/opt/app/uploads
    ports:
      # Loopback only: no other device on the wifi can reach 8145.
      - "127.0.0.1:8145:4000"
    depends_on:
      db:
        condition: service_healthy

volumes:
  keila-pgdata:
EOF
cd ~/selfhost/keila && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS, because there is no hostname, and no firewall rule, because nothing is published
  beyond loopback.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.

8145 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not the internet.
Mail still leaves, since that connection is outbound: step 1's problem is the links. Confirm
the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/keila/compose.yml
```

Assert: that prints `1`, the single published port `- "127.0.0.1:8145:4000"`. PostgreSQL
publishes no host port at all.

## 7. Start and verify

Check first that step 4's relay lines were filled in. A blank one does not stop the release, it
starts a Keila that cannot send. This prints key names, never a value:

```bash
awk -F= '/^MAILER_SMTP_(HOST|USER|PASSWORD|FROM_EMAIL)=/ {print $1 "=" (length($2) ? "set" : "EMPTY")}' ~/selfhost/keila/.env
```

Assert: four lines, all reading `set`. If any reads `EMPTY`, stop and send the user back to step
4. Then start:

```bash
cd ~/selfhost/keila
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8145/auth/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8145/auth/login | grep -o 'Sign in with your email address and password here.'
curl -sS http://localhost:8145/auth/register | grep -o 'Registration disabled.'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8145/api/v1/contacts
```

Assert all four and print what you received for each. The loop ends printing `200`. The first
grep prints `Sign in with your email address and password here.`, the line under the heading on
the first screen. The second prints `Registration disabled.`: the sign-up form is shut, so the
root account is the only one. The last prints `403`, what upstream's API authorization plug
returns to a caller with no bearer token. If any miss, stop, run
`docker compose logs --tail 40 keila` and `--tail 20 db`, and name the cause: a
missing-mailer-variable line is step 4 unfinished, `port is already allocated` means something
else holds 8145. A running container is not success.

STOP: tell the user to read their root password with `grep KEILA_PASSWORD ~/selfhost/keila/.env`,
put it in their password manager, log in at http://localhost:8145/auth/login as `root@localhost`,
and wait. Do not continue until they confirm they are inside. The next screen asks for a project,
and a sender must be added inside it before a campaign can go out.

## 8. First backup and restore

Two artifacts: a database dump with the contacts, their consent, campaigns and click history,
and an archive with the config and the uploads.

```bash
cd ~/selfhost/keila
docker compose exec -T db pg_dump -U keila -d keila | gzip > ~/selfhost/keila/backups/keila-db-$(date +%F).sql.gz
tar -C ~/selfhost/keila -czf ~/selfhost/keila/backups/keila-files-$(date +%F).tar.gz compose.yml .env uploads
ls -lh ~/selfhost/keila/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. The archive contains .env, with the relay password
and the key base, so treat it like a password-manager export.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination off this computer, a sync folder or a USB
stick, and copy both there with `cp`. Assert: the user confirms both are listed there.

To restore, in this order. `cd ~/selfhost/keila`, untar the archive there first so compose.yml
and .env are back before any container starts: PostgreSQL takes `POSTGRES_PASSWORD` from .env
the moment it initialises an empty volume. Then `docker compose down -v`, the one place `-v`
belongs, then `docker compose up -d db`, wait 30 seconds for healthy, pipe `gunzip -c` on the
`.sql.gz` into
`docker compose exec -T db psql -U keila -d keila`, then `docker compose up -d` and re-run step
7's asserts. Who opted in and when is the part that cannot be recreated.

## 9. Updating later

New versions are at https://github.com/pentacent/keila/releases. Back up first, then edit the
image line in ~/selfhost/keila/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/keila
docker compose pull
docker compose up -d
docker compose logs --tail 30 keila
```

Keila migrates on the way up: watch that log settle, then re-run step 7's asserts.

## 10. What will probably go wrong

I scheduled a campaign for the morning, closed the lid, and found it unsent at lunchtime.
Nothing was broken. Keila moves a queue only while this machine is awake
and the Docker daemon is up, and `restart: unless-stopped` acts only once that daemon runs, so a
reboot leaves nothing on 8145 until Docker Desktop starts. Turn on its start-at-login setting,
and run `cd ~/selfhost/keila && docker compose up -d` after a reboot before concluding anything
is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not send a campaign to anybody but the user, and do not import a contact list. The
  unsubscribe link resolves only on this computer.
- Do not configure hCaptcha or Friendly Captcha keys. They guard a sign-up form this install
  has switched off.
