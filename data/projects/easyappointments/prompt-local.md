You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Easy!Appointments 1.6.0, with the MySQL it keeps every appointment in, under
~/selfhost/easyappointments, answering at http://localhost:8160.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all. The
booking page lives at http://localhost:8160, which means "this computer" wherever it is read, so
a link sent to a customer, or opened on the user's own phone, resolves to nothing. They get the
diary, the services and the working plans, driven from this desk, not a page customers can book
on.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. This install needs 1536 MB of RAM available
and 5 GB free on the home disk, most of it for MySQL 8.4; both images publish amd64 and arm64.
On macOS and Windows the figure printed is the host's, and Docker Desktop takes its share out of
it. If either floor is missed, print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/easyappointments/backups
ls -la ~/selfhost/easyappointments
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder, deliberately:
every appointment, customer and setting is a row in MySQL, which step 5 keeps in a volume Docker
manages.

## 4. Secrets

Two secrets, both database passwords: the MySQL root account and the account the application
connects with. Generate both here, print neither, and keep both out of your summary and out of
any log line.

```bash
umask 077
cat > ~/selfhost/easyappointments/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/easyappointments/.env
umask 022
ls -l ~/selfhost/easyappointments/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems, though on Windows the mode bits are advisory and the real boundary is
the user's own account. No administrator password is generated: that one is created in a browser
in step 7, by the user.

## 5. compose.yml

```bash
cat > ~/selfhost/easyappointments/compose.yml <<'EOF'
# Easy!Appointments · the local-path fallback, authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   server image ... https://github.com/alextselegidis/easyappointments-docker/blob/master/README.md
#   entrypoint ..... https://github.com/alextselegidis/easyappointments-docker/blob/master/assets/docker-entrypoint.sh
#   install guide .. https://github.com/alextselegidis/easyappointments/blob/1.6.0/docs/installation-guide.md
#
# Two services, driven from ~/selfhost/easyappointments/ so one file works on
# macOS, Linux and Windows. The database is a named volume, not a bind mount:
# the MySQL image chowns /var/lib/mysql to a uid Docker Desktop's Windows file
# sharing cannot grant on a home-directory bind mount. The app container needs
# none, since every appointment is a row in MySQL. Digests read from Docker Hub
# on 2026-08-06; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  easyappointments-db:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: easyappointments
      MYSQL_USER: easyappointments
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - easyappointments-db:/var/lib/mysql
    healthcheck:
      # -h 127.0.0.1 forces TCP: the first start runs a socket-only server.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 --silent"]
      interval: 10s
      start_period: 60s
      timeout: 5s
      retries: 18
    # No `ports:` at all: 3306 is reachable only from the other container.

  easyappointments:
    image: alextselegidis/easyappointments:1.6.0@sha256:ab35b8872d5d3328fa3afb641a89a75f3c6f96f3fb98d6d6d3447fff9d357fa1
    restart: unless-stopped
    environment:
      # BASE_URL is inside every booking link, so they work here only.
      BASE_URL: http://localhost:8160
      DEBUG_MODE: "FALSE"
      DB_HOST: easyappointments-db
      DB_NAME: easyappointments
      DB_USERNAME: easyappointments
      DB_PASSWORD: ${DB_PASSWORD}
      # Off: turning it on means an OAuth client in your own Google project.
      GOOGLE_SYNC_FEATURE: "FALSE"
    ports:
      # Loopback only: no other device on the wifi can reach 8160.
      - "127.0.0.1:8160:80"
    depends_on:
      easyappointments-db:
        condition: service_healthy

volumes:
  easyappointments-db:
EOF
cd ~/selfhost/easyappointments && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve, and no certificate because a certificate attests a public name and nothing here has
one; browsers treat http://localhost as a secure context anyway, so pages needing crypto still
work. 8160 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the
same wifi, not anyone on the internet. For a booking page that is the whole trade. Confirm it:

```bash
grep -n '"127.0.0.1:' ~/selfhost/easyappointments/compose.yml
```

Assert: exactly one line, `- "127.0.0.1:8160:80"`. MySQL publishes no host port, so 3306 cannot
appear.

## 7. Start and verify

MySQL initialises from nothing on the first start, and the app container is held back until it
reports healthy.

```bash
cd ~/selfhost/easyappointments
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8160/index.php/installation); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8160/index.php/installation | grep -qF 'Easy!Appointments Installation' && echo "installer OK" || echo "installer MISSING"
```

Assert both and print what you received. The loop ends printing `200`, and the second command
prints `installer OK`: that page carries the heading `Easy!Appointments Installation`. If either
misses, stop, run `docker compose logs --tail 40 easyappointments` and
`docker compose logs --tail 20 easyappointments-db`, and name the likely cause: a database that
never reports healthy points at step 4. If `port is already allocated` came back, something else
holds 8160; stop until the user frees it, because 8160 is inside `BASE_URL` and every link.

STOP: tell the user to open http://localhost:8160/index.php/installation, enter their name,
email, a username and a password of at least 8 characters, add their company name and company
email, and press Install. Wait. Do not continue until they confirm.

Once they confirm:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8160/index.php/installation
curl -sS http://localhost:8160/ | grep -qF 'Book Appointment With' && echo "booking page OK" || echo "booking page MISSING"
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8160/index.php/api/v1/appointments
```

Assert all three: `307` from the first, or any other 3xx, so the installer now redirects away
because the `users` table exists and the form is gone; `booking page OK` from the second, the
page carrying the title `Book Appointment With`; `401` from the third, the API refusing a caller
with no credentials. A running container is not success.

## 8. First backup and restore

Two artifacts: a database dump with every appointment and customer, and a config archive with
the two files that rebuild the service around it.

```bash
cd ~/selfhost/easyappointments
docker compose exec -T easyappointments-db sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction easyappointments' | gzip > ~/selfhost/easyappointments/backups/easyappointments-db-$(date +%F).sql.gz
tar -C ~/selfhost/easyappointments -czf ~/selfhost/easyappointments/backups/easyappointments-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/easyappointments/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. The password is read inside
the container from its own environment, so it never reaches this machine's process list.
mysqldump still warns about command-line passwords on stderr, which is expected, and nothing is
stopped: `--single-transaction` snapshots a running InnoDB database consistently.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder their sync service
watches or a USB stick, and copy both there with `cp`. Assert: the user confirms both filenames
are there. If they have neither, say plainly that this install has no backup.

To restore, in this order: untar the config archive into ~/selfhost/easyappointments first, so
compose.yml and .env are back before any container starts, because MySQL reads `DB_PASSWORD`
from .env the moment it initialises an empty volume; `docker compose down -v`, the one place
`-v` belongs, because it drops the old volume on purpose; `docker compose up -d
easyappointments-db`; wait a minute for healthy; pipe `gunzip -c` on the dump into
`docker compose exec -T easyappointments-db sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" easyappointments'`;
`docker compose up -d`. Then open the calendar and check an appointment you recognise is there.

## 9. Updating later

New versions are listed at https://github.com/alextselegidis/easyappointments/releases, with the
matching image tag on Docker Hub. Take both backups first, then edit the image line in
~/selfhost/easyappointments/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/easyappointments
docker compose pull
docker compose up -d
docker compose logs --tail 30 easyappointments
```

The application migrates its own database on the way up, so watch that log until it settles,
then re-run step 7's three asserts. An update logs everyone out: sessions are files in the
container.

## 10. What will probably go wrong

I opened http://localhost:8160 about twenty seconds after `docker compose up -d` and the browser
said the connection was refused, which reads like an install that failed silently. Nothing had
failed. The app container is held back until MySQL reports healthy, and MySQL's first start
builds its data directory from scratch, which took a little over two minutes here. The loop in
step 7 exists for that wait. `docker compose ps` showing the app as `Created` rather than `Up`
means it is still waiting on the database, so do not restart anything.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `BASE_URL` to this machine's LAN address and do not rebind 8160 to 0.0.0.0 so a
  phone can reach it. That puts a booking form and a login page on every network the user joins.
- Do not configure SMTP. A laptop is the worst place to start owning deliverability from.
- Do not enable Google Calendar sync. It needs an OAuth client in the user's own Google Cloud
  project, and `GOOGLE_SYNC_FEATURE` stays `FALSE` here.
- Do not install phpMyAdmin. If the database needs a query, run the client in the container.
