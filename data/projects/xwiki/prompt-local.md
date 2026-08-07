You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install XWiki 17.10.11, with the PostgreSQL it keeps every page in, under ~/selfhost/xwiki,
answering at http://localhost:8172.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install. XWiki is built
for a team, and this one answers only at http://localhost:8172, which means "this computer"
wherever it is read: a colleague sent that address gets an error, and so does the user's own
phone. What they get is a private wiki for one. Then measure the machine:

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
ID and codename print next, for step 2. XWiki is Java: the image gives Tomcat a 1024 MB heap
and runs LibreOffice in the same container, with PostgreSQL beside it, so this needs 3072 MB of
RAM available and 10 GB free on the home disk. Both images publish amd64 and arm64. On macOS
and Windows that figure is the host's, minus Docker Desktop's VM allocation, so check its
memory limit too. Under either floor, print both and stop.

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
mkdir -p ~/selfhost/xwiki/data ~/selfhost/xwiki/backups
ls -la ~/selfhost/xwiki
```

Assert: `data` and `backups`, owned by the user. `data` is XWiki's permanent directory: the
downloaded user interface, the search index, the logs and every attachment. The database is a
volume Docker manages, so nothing here needs an ownership fix; on Linux the container's Tomcat
writes inside `data` as root, which is expected.

## 4. Secrets

One secret: the PostgreSQL password. Generate it here, print it nowhere, and keep it out of
your summary and every log line.

```bash
umask 077
cat > ~/selfhost/xwiki/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/xwiki/.env
umask 022
ls -l ~/selfhost/xwiki/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so this runs the same everywhere. Docker
Compose reads this file for the `${DB_PASSWORD}` substitution and hands the value to both
containers. No administrator password is in it: XWiki seeds no account, and the user creates
the first one in the browser at step 7. On Windows the mode bits are advisory, and the boundary
is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/xwiki/compose.yml <<'EOF'
# XWiki · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image tags .... https://github.com/docker-library/official-images/blob/master/library/xwiki
#   image sources . https://github.com/xwiki/xwiki-docker/tree/master/17/postgres-tomcat
#
# Two services, every path relative to ~/selfhost/xwiki/ so one file works on
# macOS, Linux and Windows. The database is a named volume, not a bind mount,
# because PostgreSQL chowns its data directory to its own uid and a Windows
# home bind cannot allow that. The permanent directory stays a bind mount: it
# holds the flavor, the Solr index and every attachment, file storage having
# been XWiki's attachment default since 10.5. `init: true` reaps LibreOffice's
# orphans. 17.10.11 is the LTS line. Digests read 2026-08-07; both multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: xwiki-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: xwiki
      POSTGRES_USER: xwiki
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      # Upstream initialises it this way; encoding is fixed at create time.
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale-provider=builtin --locale=C.UTF-8"
    volumes:
      - xwiki-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U xwiki -d xwiki"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  xwiki:
    image: xwiki:17.10.11-postgres-tomcat@sha256:f1b36072ed82d2e7414b3b12b670d4ddf981f32698f70a8fa8deb606fe989621
    container_name: xwiki
    restart: unless-stopped
    init: true
    # DB_PASSWORD arrives from ./.env, mode 600. The entrypoint writes it
    # and the three below into WEB-INF/hibernate.cfg.xml.
    env_file: ./.env
    environment:
      DB_HOST: postgres
      DB_DATABASE: xwiki
      DB_USER: xwiki
      # No JAVA_OPTS: setenv.sh gives Tomcat a 1024 MB heap, and JAVA_OPTS
      # is where you raise it.
    volumes:
      - ./data:/usr/local/xwiki
    healthcheck:
      # Tomcat boots, then XWiki builds its schema: long start period.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8080/bin/view/Main/ || exit 1"]
      interval: 15s
      retries: 20
      start_period: 300s
    ports:
      # Loopback only: no other device on the wifi can reach 8172.
      - "127.0.0.1:8172:8080"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  xwiki-pgdata:
EOF
cd ~/selfhost/xwiki && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: nothing to resolve, no public name to
attest, nothing published beyond loopback. Browsers treat http://localhost as a secure context,
so pages needing crypto still work. 8172 is bound to 127.0.0.1: not the user's phone, not a
laptop on the wifi, not anyone on the internet. That is the point of this path. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/xwiki/compose.yml
```

Assert: `1`, the published-port line. PostgreSQL publishes no host port, so 5432 cannot appear.

## 7. Start and verify

Two slow things happen in a row, and neither is a fault. Tomcat starts and XWiki builds its
whole schema, the loop below. Then the user runs the wizard, whose second step downloads the
default user interface from upstream's extension repository: minutes, and this computer has to
be online.

```bash
cd ~/selfhost/xwiki
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sSL -o /dev/null -w '%{http_code}' http://localhost:8172/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL http://localhost:8172/ | grep -c 'id="distributionWizard"'
curl -sSL http://localhost:8172/ | grep -c 'Distribution Wizard'
```

Assert all three and print what you received for each. The loop ends on `200`, after two
redirects: `/` goes to `/bin/view/Main/`, which goes to the wizard. Both greps print `1`. If
any misses, stop, run `docker compose logs --tail 60 xwiki` and
`docker compose logs --tail 20 postgres`, and name the cause: a database that never reports
healthy points at step 4, where an empty `DB_PASSWORD` leaves PostgreSQL refusing to start; a
refused connection while the XWiki log still prints schema updates wants more time. If
`port is already allocated` came back, find what holds 8172 (`lsof -nP -iTCP:8172 -sTCP:LISTEN`,
or `netstat -ano | findstr :8172` on Windows) and stop until it is freed. A running container
is not success.

The first screen at http://localhost:8172/ is the wizard, headed `Distribution Wizard`; its
second step is headed `Admin user`.

STOP: tell the user to open http://localhost:8172/ now, work through the wizard, register the
administrator on the `Admin user` step, let the `User Interface` step finish, and wait.
Do not continue until they confirm they reached the report at the end. Have them put that
password in their password manager: nothing here sends reset mail.

Once they confirm, check the wizard closed behind them:

```bash
curl -sSL -o /dev/null -w '%{http_code}\n' http://localhost:8172/
curl -sSL http://localhost:8172/bin/distribution/XWiki/Distribution | grep -c 'id="distributionWizard"'
```

Assert: the first prints `200` and the second prints `0`. Upstream offers a signed-out visitor
the wizard only while the wiki has no registered user, so once the administrator exists that
URL answers with a login form. Both must pass before you report success.

## 8. First backup and restore

Two artifacts, and you need both. The database holds every page, revision, comment and user.
The archive holds the permanent directory, where the attachments are, plus the two files that
rebuild the service.

```bash
cd ~/selfhost/xwiki
docker compose exec -T postgres pg_dump -U xwiki -d xwiki | gzip > ~/selfhost/xwiki/backups/xwiki-db-$(date +%F).sql.gz
tar -C ~/selfhost/xwiki -czf ~/selfhost/xwiki/backups/xwiki-files-$(date +%F).tar.gz compose.yml .env data
ls -lh ~/selfhost/xwiki/backups/
```

Assert: both exist, neither is empty, both sizes printed. Nothing goes offline: `pg_dump`
snapshots a running database consistently. On Linux the container wrote `data` as root; those
files stay readable, and if `tar` prints `Permission denied`, rerun that line with `sudo`.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination off this computer, a sync folder or a USB
stick, and copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert: both
names are listed there, or this install has no backup.

To restore: `docker compose down -v`, the one place `-v` belongs because it drops the old
database volume on purpose. Delete `data`, untar the archive into ~/selfhost/xwiki so `.env`
and the permanent directory are back before any container starts, because PostgreSQL takes
`DB_PASSWORD` from `.env` the moment it initialises an empty volume. Then
`docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T postgres psql -U xwiki -d xwiki`, then `docker compose up -d`.
Both matter: the dump alone restores a wiki whose every attachment is a broken link.

## 9. Updating later

New versions are listed at https://github.com/xwiki/xwiki-platform/releases, and the tag each
maps to is in https://github.com/docker-library/official-images/blob/master/library/xwiki. Stay
on 17.10.x, the long-term line; 18.x is the monthly train. Back up first, then edit the image
line in ~/selfhost/xwiki/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/xwiki
docker compose pull
docker compose up -d
docker compose logs --tail 40 xwiki
```

XWiki migrates its own schema on the way up, and a version bump brings the wizard back for its
user-interface step. Watch that log settle, then re-run step 7's checks.

## 10. What will probably go wrong

I closed the laptop lid during the wizard's user-interface step and came back to a browser tab
that had given up, and read that as a broken install. It was not. That step is a download from
upstream's extension repository taking minutes, and this machine has to stay awake and online
for all of it, which a laptop on battery does not do by itself. Reloading
http://localhost:8172/ puts the wizard back where it got to. Docker Desktop wants the same
afterwards: nothing answers on 8172 until it is running, so after a reboot start it first.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8172 to 0.0.0.0 so a phone can reach it. That puts a wiki with one password on
  every network the user joins.
- Do not configure SMTP. XWiki runs without it, and every notification it would have emailed
  stays inside the web interface.
- Do not install the Confluence import extension. It is a contributed extension, added from
  the Extension Manager once there is a wiki to import into.
