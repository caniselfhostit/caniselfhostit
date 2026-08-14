You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Stalwart 0.16.17 under ~/selfhost/stalwart, answering at http://localhost:8189.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. A mail server on a laptop is not a mail server. Nothing on the internet can open port 25 on
this machine, no phone can reach 993 on it, and a computer that sleeps stops being a mail
exchanger when the lid closes. This install publishes no mail port. What they get is the real
software and its administration interface, as a sandbox: click through the setup wizard, create
accounts and domains, read the DKIM and SPF records it generates. For mail that arrives, the
server path is on the other tab.

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
distribution ID and codename print next, for step 2. Stalwart needs 1024 MB of RAM available and
10 GB free on the home disk, and the image publishes amd64 and arm64. Every branch prints free
memory, so one floor covers all three; on macOS and Windows it is the host's, and Docker Desktop
takes its allocation from it. If RAM is under 1024 MB or disk under 10 GB, print both and stop.

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
mkdir -p ~/selfhost/stalwart/etc ~/selfhost/stalwart/data ~/selfhost/stalwart/log ~/selfhost/stalwart/backups
if [ "$(uname -s)" = "Linux" ]; then sudo chown -R 2000:2000 ~/selfhost/stalwart/etc ~/selfhost/stalwart/data ~/selfhost/stalwart/log; fi
ls -la ~/selfhost/stalwart
```

Assert: `ls -la` shows `etc`, `data`, `log` and `backups`. The image creates a `stalwart` user
with uid 2000 and runs as it, so on Linux those three are chowned to that uid or the container
cannot write them; on macOS and Windows the fence is a no-op and Docker Desktop handles
ownership. `etc` holds `config.json`, `data` the RocksDB, `log` the wizard's log path the
image does not create.

## 4. Secrets

One secret: the bootstrap administrator credential, generated here. Do not print it, repeat it in
your summary, or log it. Hex, not base64: Stalwart reads a leading `$`, `_` or `{` as a hash
prefix.

```bash
umask 077
cat > ~/selfhost/stalwart/.env <<EOF
STALWART_PUBLIC_URL=http://localhost:8189
STALWART_RECOVERY_ADMIN=admin:$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/stalwart/.env
umask 022
ls -l ~/selfhost/stalwart/.env
```

Assert: mode `-rw-------`. Setting this before the first start is the point: left unset, Stalwart
generates its own bootstrap password and writes it to the container log in clear text. On Windows
the mode bits are advisory on NTFS and the real boundary is the user's own Windows account. Step
7 deletes the line.

## 5. compose.yml

```bash
cat > ~/selfhost/stalwart/compose.yml <<'EOF'
# Stalwart · the deterministic fallback for the local path. Authored by
# caniselfhostit from https://stalw.art/docs/install/platform/docker and
# https://stalw.art/docs/install/security
#
# One service, one published port: 8189, the plain HTTP listener, on loopback.
# No mail port is published, and that is the shape of this path. Nothing on the
# internet can open 25 on a laptop, no phone on the wifi can reach 993 on it,
# and a machine that sleeps is not a mail exchanger. What runs is the server and
# its admin interface, no domain at risk and no mail in flight.
#
# Paths are relative to ~/selfhost/stalwart/, so one file works on macOS, Linux
# and Windows, and all three stay bind mounts so you can open them in Finder or
# Explorer. The image runs as uid 2000, which step 3 chowns for on Linux. Same
# tag and digest as the VPS compose file.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  stalwart:
    image: stalwartlabs/stalwart:v0.16.17@sha256:a8108e19bd927e172d4d8c128907b8dfc93fd180ae8ee07dccdd42cb97eb9dfa
    container_name: stalwart
    restart: unless-stopped
    # Public URL and the generated bootstrap credential. Mode 600.
    env_file: ./.env
    volumes:
      # config.json, the RocksDB, the log path; all owned by uid 2000.
      - ./etc:/etc/stalwart
      - ./data:/var/lib/stalwart
      - ./log:/var/log/stalwart
    ports:
      # Loopback only, and the same host port the VPS compose file publishes.
      - "127.0.0.1:8189:8080"
EOF
cd ~/selfhost/stalwart && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK` prints. One service, one port, three bind mounts.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve, a certificate attests a public name and nothing here has one, and browsers treat
http://localhost as a secure context.

8189 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. For a mail server that is not a trade, it is the character of
this path, because mail arrives on port 25 from machines that must open it. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/stalwart/compose.yml
```

Assert: that prints `1`, and it is the line `- "127.0.0.1:8189:8080"`. Anything else means a mail
port has been published and this is no longer the sandbox it claims to be. Stalwart still reaches
the internet for the web interface download and for DNS: a loopback binding governs what arrives,
not what the container can call.

## 7. Start and verify

With no `config.json` on disk, Stalwart starts in bootstrap mode: one plain HTTP listener on
8080, the wizard at `/admin`, no mail listeners.

```bash
cd ~/selfhost/stalwart
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8189/healthz/live); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8189/admin/
curl -sS http://localhost:8189/login | grep -c '<title>Sign in</title>'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8189/api/account
```

Assert all four and print what you received. The loop ends on `200`. `/admin/` prints `200`: the
web interface is a bundle downloaded from GitHub on first start and `/admin` answers `404` until
that succeeds, so this tests whether this machine can reach GitHub. The grep prints `1`, the
sign-in page from a template compiled into the binary. The last prints `401`, the admin API
refusing a request with no credentials. On any miss, stop, run
`docker compose logs --tail 40 stalwart` and name the cause: a container that exits on its own
points at step 3, a data directory it cannot write. If `port is already allocated` came back, find
what holds 8189 (`lsof -nP -iTCP:8189 -sTCP:LISTEN`, `ss -ltnp | grep 8189` on Linux,
`netstat -ano | findstr :8189` on Windows) and stop until it is free. A running container is
not success.

STOP: tell the user to open http://localhost:8189/admin, sign in as `admin` with the value after the colon in `grep STALWART_RECOVERY_ADMIN ~/selfhost/stalwart/.env`, and finish the wizard: a hostname and domain they can imagine using, DKIM key generation on, and the TLS certificate request OFF, because there is no public name here for a certificate authority to check. The wizard shows the permanent administrator password once and never again. Do not continue until they confirm they saved it.

Then restart so the configuration takes effect and shut the bootstrap door: that credential works
on every sign-in while it is set.

```bash
test -s ~/selfhost/stalwart/etc/config.json && echo "config written"
docker compose restart
sleep 20
RECOVERY=$(grep '^STALWART_RECOVERY_ADMIN=' ~/selfhost/stalwart/.env | cut -d= -f2-)
sed -i.bak '/^STALWART_RECOVERY_ADMIN=/d' ~/selfhost/stalwart/.env && rm -f ~/selfhost/stalwart/.env.bak
docker compose up -d --force-recreate
sleep 20
printf 'user = "%s"\n' "$RECOVERY" | curl -sS -K - -o /dev/null -w '%{http_code}\n' http://localhost:8189/api/account
unset RECOVERY
```

Assert: `config written` prints and the curl prints `401`. That curl replays a credential that
worked ten minutes ago and is refused, which is the evidence the door is shut; it rides in curl's
configuration on stdin, so it never reaches the process table. A `200` means the recreate did not
read the edited file: run it again. A missing `config.json` means the wizard did not finish. Then
tell the user what the sandbox is for: the domain page lists the DNS record set their domain would
need, DKIM key and all, and that list is worth reading before they rent a server.

## 8. First backup and restore

One archive: the configuration, the RocksDB, `.env`, the compose file.

```bash
cd ~/selfhost/stalwart
docker compose stop
tar -C ~/selfhost/stalwart -czf ~/selfhost/stalwart/backups/stalwart-$(date +%F).tar.gz compose.yml .env etc data
docker compose start
ls -lh ~/selfhost/stalwart/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped on purpose:
RocksDB is a set of files under active write, and one tarred mid-write restores as a corrupt
database, not a mailbox. Downtime is a minute.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is `/d/Backups`, not `D:\Backups`. Assert: the user confirms the file is there. If they have
nowhere, say plainly that this install has no backup.

To restore: `cd ~/selfhost/stalwart`, `docker compose down`, `rm -rf etc data`, untar the archive
there, re-run the Linux chown from step 3, `docker compose up -d`. `.env` must be back before the
first start, and `etc/config.json` too or the server returns to bootstrap mode.

## 9. Updating later

New versions are at https://github.com/stalwartlabs/stalwart/releases, and
https://github.com/stalwartlabs/stalwart/tree/main/UPGRADING has a note per version. Back up, then
edit the image line in the compose file:

```bash
cd ~/selfhost/stalwart
docker compose pull
docker compose up -d
docker compose logs --tail 40 stalwart
```

Stalwart migrates its own database on the way up and refuses to start rather than run against a
schema it does not recognise, so watch that log until it settles, then re-run step 7's checks.

## 10. What will probably go wrong

I left this running for a week and then wondered why the queue was empty. Nothing was wrong: no
mail can arrive at a machine no mail server can open a connection to, and nothing had been sent
because there was no domain behind any of it. That is the honest shape of a mail server on a
laptop, and worth saying twice because the software gives no sign of it: the dashboard is green,
the accounts exist, and the product does not do the one thing mail is for. The smaller annoyance
is that after a reboot Docker Desktop is not running until you open it, so http://localhost:8189
refuses the connection and looks broken. Turn on start-at-login, and after any reboot run
`cd ~/selfhost/stalwart && docker compose up -d`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not publish ports 25, 465 or 993. A mail port open on a laptop that joins other networks is
  a mail port open on those networks.
- Do not configure an external directory, LDAP or OIDC. The internal directory creates the
  administrator account this prompt depends on.
- Do not turn on the enterprise features; they need a key from Stalwart Labs.
