You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Vaultwarden 1.37.1 on this computer, reachable at http://localhost:8222, with
everything it owns under ~/selfhost/vaultwarden.

## 1. Preflight

Say this to the user before you install anything: the browser and the Bitwarden extension on
this computer reach this vault fully, but their phone and every other device cannot, so
nothing syncs off this machine. If they want the vault on a phone, stop here: that is the
server path.

Vaultwarden needs 512 MB of RAM and 10 GB free on the home disk, and runs on amd64 and arm64,
Apple Silicon included. Detect the OS and measure both:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Darwin) sysctl -n hw.memsize | awk '{printf "%d MB of RAM installed\n", $1/1048576}' ;;
  Linux) free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory" ;;
esac
df -h ~
```

`Darwin`, `Linux`, and a name starting `MINGW` or `MSYS` in Git Bash on Windows are the three
answers every branch below turns on. Windows prints total bytes, so divide by 1048576 first,
and like macOS it reports RAM installed, not RAM free.

If RAM is under 512 MB or free space on the home disk is under 10 GB, print both numbers and
stop. Do not install and hope.

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
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they confirm.
  Either way, then STOP: tell the user to open Docker Desktop once, accept its terms, and wait
  for the whale icon to say it is running. Do not continue until they confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and install
  it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may ask for a
  reboot; if it does, STOP and tell the user to reboot and come back, this prompt resumes at
  this step. Then STOP: have the user open Docker Desktop, accept its terms, and confirm it
  says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt repository,
  with its signing key saved to a file first, never piped into a shell. Commands below.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose plugin
  with their distribution's package manager, and to run this prompt again once `docker info`
  works.

The Debian and Ubuntu path, in full:

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

Tell the user in one sentence that `docker` group membership is root-equivalent on this
machine, and that the change lands at their next login, so they log out and back in first.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not continue
without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/vaultwarden/data ~/selfhost/vaultwarden/backups
ls -la ~/selfhost/vaultwarden
```

Assert: `ls -la` lists `data` and `backups`. Nothing is written outside ~/selfhost/vaultwarden,
and `data` is the whole vault: SQLite file, attachments and RSA keys.

On Linux the container writes into `data` as root, so step 8 hands that directory back to the
user before archiving. On macOS and Windows, Docker Desktop's file sharing maps them onto the
user's own account and there is nothing to fix.

## 4. Secrets

Two secrets, both generated here: the admin page passphrase, which the user keeps, and its
Argon2 PHC hash, which is what the server stores, from Vaultwarden's own binary. Print neither
value, in chat, in your summary, or in any log line.

```bash
umask 077
cat > ~/selfhost/vaultwarden/.env <<'EOF'
DOMAIN=http://localhost:8222
EOF
PASSPHRASE="$(openssl rand -base64 33)"
HASH="$(printf '%s\n%s\n' "$PASSPHRASE" "$PASSPHRASE" | MSYS_NO_PATHCONV=1 docker run --rm -i vaultwarden/server:1.37.1-alpine@sha256:b094afed4ed5ea353821c6efcedca446f30c6654ba2bc441db6089b0c2b94ac8 /vaultwarden hash --preset owasp | grep -o '\$argon2[^ ]*' | tail -n 1)"
ESCAPED="$(printf '%s' "$HASH" | sed 's/[$]/$$/g')"
echo "ADMIN_TOKEN=$ESCAPED" >> ~/selfhost/vaultwarden/.env
printf '%s\n' "$PASSPHRASE" > ~/selfhost/vaultwarden/admin-passphrase.txt
chmod 600 ~/selfhost/vaultwarden/.env ~/selfhost/vaultwarden/admin-passphrase.txt
unset PASSPHRASE HASH ESCAPED
umask 022
ls -l ~/selfhost/vaultwarden/.env ~/selfhost/vaultwarden/admin-passphrase.txt
grep -c '^ADMIN_TOKEN=' ~/selfhost/vaultwarden/.env
```

Assert: both files exist at mode `-rw-------` and the grep prints `1`. Doubling every `$` is
what stops compose eating half the hash. `MSYS_NO_PATHCONV=1` stops Git Bash rewriting
`/vaultwarden` into a Windows path; on macOS and Linux it does nothing.

On Windows, `chmod 600` sets a mode bit NTFS treats as advisory. Say so plainly: the file is
protected by sitting in the user's own profile, and their account is the real boundary.

Tell the user the passphrase is in ~/selfhost/vaultwarden/admin-passphrase.txt, that they move
it into their vault after step 7 and then delete that file, and that you never printed it.

## 5. compose.yml

```bash
cat > ~/selfhost/vaultwarden/compose.yml <<'EOF'
# Vaultwarden · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   compose shape ... https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose
#   admin token ..... https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page
#   websockets ...... https://github.com/dani-garcia/vaultwarden/wiki/Enabling-WebSocket-notifications
#
# One container, no proxy and no certificate. Every path is relative to the
# directory this file sits in, ~/selfhost/vaultwarden/, so one file works on
# macOS, Linux and Windows. 8222 is on 127.0.0.1 only, and ./data is the whole
# vault: SQLite, attachments, RSA keys. Since 1.31.0 WebSocket traffic rides the
# main HTTP port. Tag and digest are the 1.37.1 release read from the Docker Hub
# registry API on 2026-08-05, amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  vaultwarden:
    image: vaultwarden/server:1.37.1-alpine@sha256:b094afed4ed5ea353821c6efcedca446f30c6654ba2bc441db6089b0c2b94ac8
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      # The address the browser uses, port included: Vaultwarden builds
      # its links from this one value.
      DOMAIN: ${DOMAIN}
      # Opened for one step during the install, then closed and asserted closed.
      SIGNUPS_ALLOWED: "false"
      # Argon2 PHC hash made on this machine. Every "$" is stored as "$$" in .env.
      ADMIN_TOKEN: ${ADMIN_TOKEN}
    volumes:
      - ./data:/data
    ports:
      # Loopback only. Nothing outside this computer can reach 8222.
      - "127.0.0.1:8222:80"
EOF
cd ~/selfhost/vaultwarden && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. If compose says `DOMAIN` or `ADMIN_TOKEN` is not set, step 4
did not finish; go back rather than invent one here. Compose reads `.env` from the
directory the compose file sits in, which is why no path in the file is absolute.

## 6. Nothing is public

Nothing here faces the network. 8222 is published on 127.0.0.1, so it answers programs on this
computer and nothing else. There is no domain and no certificate because there is nothing to
certify: the DNS wait, the TLS issuance and the firewall rules of the server path do not
apply here.

Other devices cannot reach this, including the user's own phone on the same wifi. That is what
this path is, not a defect in it. Confirm the binding before anything starts:

```bash
grep -c '127.0.0.1:8222:80' ~/selfhost/vaultwarden/compose.yml
```

Assert: that prints `1`. If it prints `0`, rewrite the file from step 5 rather than patch
what is there.

Browsers treat `http://localhost` as a secure context, so the Web Crypto the vault and the
extension need works without TLS. Tell the user the Bitwarden extension on this computer
points at http://localhost:8222 through its self-hosted server field.

## 7. Start and verify

```bash
cd ~/selfhost/vaultwarden
docker compose pull
docker compose up -d
sleep 15
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8222/alive
```

Assert: that prints `200`. `/alive` opens the database to answer, so 200 means the container
and the vault file are both good. Anything else: stop and run
`docker compose logs --tail 30 vaultwarden`. If compose refused to start because the port is
already allocated, something else here holds 8222: run `docker ps`, an old container being the
usual answer, and do not move the port to route around it.

Registration is off in compose.yml, right for every day except this one. Turn it on for
exactly one step. `sed -i` takes different arguments on macOS and Linux, so write a new file
and move it into place:

```bash
cd ~/selfhost/vaultwarden
sed 's/SIGNUPS_ALLOWED: "false"/SIGNUPS_ALLOWED: "true"/' compose.yml > compose.new && mv compose.new compose.yml
docker compose up -d --force-recreate vaultwarden
sleep 10
```

The first screen at http://localhost:8222 shows a `Log in` heading and a `Create account`
link. Vaultwarden draws that screen in JavaScript, so curl returns the page shell, not those
two strings; the user confirms them.

STOP: tell the user to open http://localhost:8222 in a browser on this computer, create their
account, and wait. Do not continue until they confirm they can sign in.

Once they confirm, close registration again:

```bash
cd ~/selfhost/vaultwarden
sed 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' compose.yml > compose.new && mv compose.new compose.yml
docker compose up -d --force-recreate vaultwarden
sleep 10
grep 'SIGNUPS_ALLOWED' compose.yml
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8222/alive
```

Assert, all three: the grep prints `SIGNUPS_ALLOWED: "false"`, the curl prints `200`, and the
user reloads and confirms the `Create account` link is gone. All three pass before you report
success. A running container is not success.

## 8. First backup and restore

Take the backup now, before the user puts a single password in, and take it with the app
stopped: a SQLite file copied mid-write is not a backup.

```bash
cd ~/selfhost/vaultwarden
docker compose stop
if [ "$(uname -s)" = "Linux" ] && sudo -n true 2>/dev/null; then sudo chown -R "$(id -u):$(id -g)" data; fi
tar -czf backups/vaultwarden-$(date +%F).tar.gz data .env
docker compose start
ls -lh backups/
```

Assert: the archive exists and is non-empty. Print its size, tens of kilobytes on a fresh
install. The app is down for seconds, and `data` plus `.env` is the whole install. The Linux
line is the ownership fix step 3 promised. It does not run on macOS or Windows, nor where sudo
cannot run unprompted; tar reads the files either way, but a restore that cannot delete `data`
means the user has to run that chown themselves first.

A backup on the same disk as the data is not a backup, and on one computer disk and machine
fail together. Ask the user once for a folder that leaves this machine, one a sync service
watches or a mounted USB stick, `cp` the archive there, and `ls -lh` the destination.
Use the path they give you; this step is not done until that listing shows a non-zero size.

Prove the restore today, while the only thing at risk is an empty vault. A backup nobody has
restored is a guess:

```bash
cd ~/selfhost/vaultwarden
docker compose down
rm -rf data
tar -xzf backups/vaultwarden-$(date +%F).tar.gz
docker compose up -d
sleep 15
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8222/alive
```

Assert: `200`. Then tell the user to sign in once with the account from step 7; if that
password is refused, the archive did not hold `data/db.sqlite3` and the tar step is where to
look. Those four commands are the whole disaster plan, now run once. There is nothing else to
restore here: no certificate, no proxy configuration.

## 9. Updating later

New versions are listed at https://github.com/dani-garcia/vaultwarden/releases. Take a backup
first. Run `docker pull` on the new tag by hand once: the `Digest: sha256:` line it prints is
what goes after the `@` in the image line of ~/selfhost/vaultwarden/compose.yml. Edit both,
then:

```bash
cd ~/selfhost/vaultwarden
docker compose pull
docker compose up -d
docker compose logs --tail 20 vaultwarden
```

Vaultwarden migrates its own database on start, so read that log before calling it done.

## 10. What will probably go wrong

The first reboot. Docker Desktop does not start until the user logs in, and
`restart: unless-stopped` cannot bring a container back before the engine behind it exists, so
for a minute or two after login there is nothing on 8222. The extension answers that with a
sync error while still showing the cached vault, which reads exactly like the install broke
overnight. I sat through two of those minutes convinced the vault was gone before the whale
icon settled. Check that icon first, then `docker compose ps` in ~/selfhost/vaultwarden, and
only then read logs.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP. Vaultwarden runs without it, and this machine is not a mail server.
- Do not switch the database to PostgreSQL. SQLite is why the whole vault is one directory.
- Do not enable Bitwarden push notifications. They need keys issued by Bitwarden, and no phone
  reaches this vault to notify.
