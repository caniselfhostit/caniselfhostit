You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install AdGuard Home 0.107.78 under ~/selfhost/adguard-home, answering at http://localhost:8201.

## 1. Preflight

Say this to the user before step 2 runs. LAN DNS is the real use of AdGuard Home: every device
that should stop talking to ad trackers must use this machine as its DNS server (or the router
must). An admin UI on localhost alone blocks nothing for the household. This path publishes the
admin UI on loopback only by default, and does not bind host port 53 until the user deliberately
opts in. Binding 53 often needs elevated privileges and can fight with systemd-resolved or other
local resolvers; treat it as a careful second step.

Also say: during the first-run wizard, keep the Admin Web Interface on port 3000. This compose
maps 8201 to container 3000. Moving the UI to 80 breaks that mapping.

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
distribution ID and codename print next, for step 2. AdGuard Home needs 512 MB of RAM available
and 5 GB free on the home disk, and the image publishes amd64 and arm64. Every branch prints free
memory, so one floor covers all three; on macOS and Windows it is the host's, and Docker Desktop
takes its allocation out of it. If available RAM is under 512 MB or free disk is under 5 GB,
print both numbers and stop. Do not install and hope.

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
mkdir -p ~/selfhost/adguard-home/work ~/selfhost/adguard-home/conf ~/selfhost/adguard-home/backups
ls -la ~/selfhost/adguard-home
```

Assert: `ls -la` shows `work`, `conf` and `backups`. Upstream uses those two mounts. There is
no empty `data/` directory.

## 4. Secrets

No secret is generated and there is no `.env` file. The wizard creates the admin account; the
hash lands in `conf/AdGuardHome.yaml`. Tell the user to choose a strong password in the wizard
and store it offline.

## 5. compose.yml

```bash
cat > ~/selfhost/adguard-home/compose.yml <<'EOF'
# AdGuard Home · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker ............. https://github.com/AdguardTeam/AdGuardHome/wiki/Docker
#
# One container on the computer you are sitting at. Admin UI on loopback 8201
# mapped to container 3000. Keep the wizard web interface on port 3000. DNS port
# 53 is not published by default: binding host 53 needs care (and often root or
# capabilities) and is documented as an optional LAN step, not a default.
# Volumes are work/ and conf/. Digest for v0.107.78 read from Docker Hub on
# 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  adguard-home:
    image: adguard/adguardhome:v0.107.78@sha256:1ea34eafe5dc691007946e8eaab7bf46b0de9412f39213d8c06e48b53bf9a6c5
    container_name: adguard-home
    restart: unless-stopped
    volumes:
      - ./work:/opt/adguardhome/work
      - ./conf:/opt/adguardhome/conf
    ports:
      # Loopback only: no other device reaches the admin UI unless you rebind.
      - "127.0.0.1:8201:3000"
EOF
cd ~/selfhost/adguard-home && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published admin port, no DNS publish yet.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers
treat http://localhost as a secure context anyway. Nothing is published beyond loopback, so no
port needs closing.

8201 is bound to 127.0.0.1. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/adguard-home/compose.yml
```

Assert: the count is `1`. Optional LAN DNS (only if the user wants this machine to answer DNS
for the network): edit compose to add `"53:53/tcp"` and `"53:53/udp"`, understand that this
exposes a resolver on every interface Docker publishes, stop anything else bound to 53, then
recreate the container. Do not do that on a laptop that joins untrusted networks without
firewall rules. Default remains admin-UI-only.

## 7. Start and verify

```bash
cd ~/selfhost/adguard-home
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8201/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8201/
```

Assert: the loop ends on a success-class code. If `port is already allocated`, free 8201 and
retry.

STOP: tell the user to open http://localhost:8201, complete the wizard if it appears, keep the
Admin Web Interface on port **3000**, create the admin account, and confirm they can sign in to
the dashboard. Do not continue until they confirm.

Post-wizard closure:

```bash
test -f ~/selfhost/adguard-home/conf/AdGuardHome.yaml && echo "conf ok"
grep -E '^(users:|name:)' ~/selfhost/adguard-home/conf/AdGuardHome.yaml | head -20
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8201/
```

Assert: `conf ok` prints, users appear in the yaml, and the UI still answers. If the UI dies
after the wizard, the web port left 3000.

## 8. First backup and restore

One archive: `work/`, `conf/` and compose.yml. Take it after the wizard so the admin hash is in
`conf/`.

```bash
cd ~/selfhost/adguard-home
docker compose stop
tar -C ~/selfhost/adguard-home -czf ~/selfhost/adguard-home/backups/adguard-home-$(date +%F).tar.gz work conf compose.yml
docker compose start
ls -lh ~/selfhost/adguard-home/backups/
```

Assert: the archive exists and is non-empty. Print its size.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`; confirm it exists before copying. Assert: the
user confirms the filename is listed there. If they have nowhere, say plainly that this install
has no backup.

To restore: `cd ~/selfhost/adguard-home`, `docker compose down`, `rm -rf work conf`, untar the
archive there, then `docker compose up -d`. `conf/` is the product (lists, rewrites, admin hash).

## 9. Updating later

New versions are listed at https://github.com/AdguardTeam/AdGuardHome/releases. Take a backup
first, then edit the image line in ~/selfhost/adguard-home/compose.yml to the new tag and its
digest:

```bash
cd ~/selfhost/adguard-home
docker compose pull
docker compose up -d
docker compose logs --tail 30 adguard-home
```

Confirm the dashboard still logs in before calling the update done.

## 10. What will probably go wrong

You will finish the wizard, move the web port to 80 because the form made it look standard, and
lose the UI on 8201. Keep 3000. You will also point the router at this laptop's LAN IP for DNS
and then close the lid: the whole house loses resolution until the machine wakes. A household
resolver wants a host that stays on. Binding 53 while systemd-resolved still owns it fails with
"address already in use"; stop or reconfigure the conflict before blaming AdGuard.

## 11. Out of scope

- Do not expose the admin UI to the internet from this laptop path.
- Do not configure port forwarding on the router for 8201 or 53 without understanding the
  open-resolver risk.
- Do not add a reverse proxy or TLS on this path.
- Do not rebind 8201 to 0.0.0.0 without a reason and a network you trust.
- Do not enable DHCP unless the user understands they are replacing the router for that role.
- Do not skip the post-wizard backup.
