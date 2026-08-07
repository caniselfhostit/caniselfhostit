You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install wg-easy 15.3.0 under ~/selfhost/wg-easy, with its admin interface at
http://localhost:8133 and its tunnel on UDP 51820.

## 1. Preflight

Say this before step 2 runs; it decides whether they want this install at all. Every client
configuration this creates carries `Endpoint = localhost:51820`, which means "the machine
reading this file" wherever it is read, so a config copied to a phone points that phone at
itself. This is a WireGuard server for one computer, not a VPN the household joins.

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
ID and codename print next, for step 2. wg-easy needs 512 MB of RAM available and 5 GB free on
the home disk; the image publishes amd64 and arm64. Under either floor, print both numbers and
stop.

WireGuard lives in the kernel and the container cannot create `wg0` without it. On Linux that
kernel is this machine's, so check it:

```bash
if [ "$(uname -s)" = "Linux" ]; then
  sudo modprobe wireguard
  lsmod | grep -c '^wireguard'
fi
```

On Linux a `0` there is a stop: this kernel has no WireGuard module and no container setting
works around it. On macOS and Windows the kernel belongs to Docker Desktop's virtual machine
rather than this operating system, so there is nothing here to load, and step 7 is where the
answer arrives as `Cannot find device "wg0"` if Docker Desktop is too old.

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
mkdir -p ~/selfhost/wg-easy/etc_wireguard ~/selfhost/wg-easy/backups
ls -la ~/selfhost/wg-easy
```

Assert: `ls -la` shows `etc_wireguard` and `backups`, both owned by the user. No ownership fix
runs here. The image declares no user, so the container writes as root: on Linux the files under
`etc_wireguard` end up root's, and on macOS and Windows Docker Desktop maps them back, which is
why step 8 archives from inside the container.

## 4. Secrets

One secret: the password for the `admin` account the container creates on its first start.
Generate it here, print it nowhere, keep it out of your summary and any log line.

```bash
umask 077
cat > ~/selfhost/wg-easy/.env <<EOF
INIT_ENABLED=true
INIT_USERNAME=admin
INIT_PASSWORD=$(openssl rand -base64 24)
INIT_HOST=localhost
INIT_PORT=51820
INIT_DNS=1.1.1.1
INIT_ALLOWED_IPS=0.0.0.0/0
EOF
chmod 600 ~/selfhost/wg-easy/.env
umask 022
ls -l ~/selfhost/wg-easy/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same on
all three. Upstream documents the `INIT_` group as an unattended setup read only at the
container's first start and recommends removing the variables afterwards; step 7 does. The
password is 32 characters because upstream rejects anything under 12, and `INIT_DNS` and
`INIT_ALLOWED_IPS` carry one value each because step 5 turns IPv6 off.

On Windows those mode bits are advisory: NTFS does not enforce them, and the real boundary is
the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/wg-easy/compose.yml <<'EOF'
# wg-easy · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   optional config .... https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/advanced/config/optional-config.md
#   unattended setup ... https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/advanced/config/unattended-setup.md
#   no reverse proxy ... https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/examples/tutorials/reverse-proxyless.md
#
# One service. Paths are relative to ~/selfhost/wg-easy/ and both mounts are
# ordinary bind mounts, so the database and the archives show up in Finder or
# Explorer. Two differences from the VPS file: INSECURE is true, upstream's
# setting for running without a reverse proxy, and ./backups is mounted so
# step 8 writes its archive from inside the container.
#
# Same tag and digest as the VPS file, read from ghcr.io on 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15.3.0@sha256:93bbd593e07bab98d02807a28770ac87ab6c48818e319e68c1f66561feb99876
    container_name: wg-easy
    restart: unless-stopped
    env_file: ./.env
    environment:
      # Nothing terminates TLS here, so the session cookie cannot be Secure.
      INSECURE: "true"
      DISABLE_IPV6: "true"
    volumes:
      - ./etc_wireguard:/etc/wireguard
      - ./backups:/backups
    ports:
      # The tunnel: the one port here that is not on loopback. A WireGuard
      # listener answers nothing to a packet it cannot verify.
      - "51820:51820/udp"
      # The admin UI. Loopback only: no other device on the wifi reaches 8133.
      - "127.0.0.1:8133:51821"
    cap_add:
      # Creating wg0, its routes, and the NAT rule the PostUp hook adds.
      - NET_ADMIN
    sysctls:
      # Routing out of eth0, and the mark wg-quick sets on its own packets so
      # the kernel does not drop them as martians on the way back.
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF
cd ~/selfhost/wg-easy && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so the sign-in page works without one.

8133 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi. One port is not on loopback and the user should hear it plainly. 51820/udp, the tunnel, is
published as it is on a server, because a WireGuard server with no reachable socket is a key
generator. A stranger on that network gets nothing from it: WireGuard answers no packet it
cannot verify, and `docker compose down` closes it.

```bash
grep -n '127.0.0.1' ~/selfhost/wg-easy/compose.yml
```

Assert: one line, `- "127.0.0.1:8133:51821"`.

## 7. Start and verify

```bash
cd ~/selfhost/wg-easy
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8133/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -H 'Accept-Language: en' http://localhost:8133/login | grep -o 'Sign In'
docker compose exec -T wg-easy wg show
```

Assert all three and print what you received. The loop ends printing `200`. The second prints
`Sign In`. The third prints a block beginning `interface: wg0` with a `listening port: 51820`
line, the tunnel existing rather than the web server. If any miss, stop, run
`docker compose logs --tail 40 wg-easy`, and name the cause: `Cannot find device "wg0"` is the
kernel module from step 1; `port is already allocated` means something else holds 8133 or 51820,
so find it with `lsof -nP -iTCP:8133 -sTCP:LISTEN` or, on Windows,
`netstat -ano | findstr :8133`. A running container is not success.

The first screen at http://localhost:8133/login is a card with `Username` and `Password` boxes
and a `Sign In` button. There is no register link and no default account.

STOP: tell the user to open http://localhost:8133, sign in as `admin` with the password from
`grep INIT_PASSWORD ~/selfhost/wg-easy/.env`, save it in their password manager, and add a
client named `laptop`. Wait. Do not continue until they confirm the client is listed.

Once they confirm, prove the key reached the live interface, then clear the password out of the
environment:

```bash
cd ~/selfhost/wg-easy
docker compose exec -T wg-easy wg show | grep -c '^peer:'
sed -i.bak '/^INIT_/d' .env && rm -f .env.bak
docker compose up -d --force-recreate
sleep 15
grep -c '^INIT_' .env || true
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8133/login
```

Assert all four before reporting success. The first prints `1`, a key that went from the browser
into the running kernel interface. The third prints `0`, so the password is out of the file the
container reads on every start, which upstream recommends once setup is done. The last prints
`200`: the account and the client live in the database now.

Say what this cannot prove rather than implying it passed: a handshake needs a device dialling
in, and the only one that can reach `localhost:51820` is this computer.

## 8. First backup and restore

One archive, written from inside the container so one command covers all three systems, with
the app down because `wg-easy.db` is SQLite and a mid-write copy is not a database.

```bash
cd ~/selfhost/wg-easy
docker compose down
docker compose run --rm --no-deps -T wg-easy sh -c 'tar -czf /backups/wg-easy-$(date +%F).tar.gz -C /etc/wireguard .'
docker compose up -d
ls -lh ~/selfhost/wg-easy/backups/
```

Assert: the archive exists and is non-empty. Print its size. It holds the database with the
admin account and every client's private key.

That archive is on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy it there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`. Assert: the user confirms the filename is listed there.
If they have nowhere to put it, say plainly that this install has no backup, and say the other
half: whoever holds that file holds the private key of every device enrolled here, so it belongs
somewhere encrypted.

To restore: `docker compose down`, `rm -rf etc_wireguard`, `mkdir etc_wireguard`, untar into it
with
`docker compose run --rm --no-deps -T wg-easy sh -c 'tar -xzf /backups/<archive> -C /etc/wireguard'`,
then `docker compose up -d`. If the folder is gone too, steps 4 and 5 rewrite compose.yml and
`.env`, and `cli db:admin:reset` sets a new password.

## 9. Updating later

New versions are listed at https://github.com/wg-easy/wg-easy/releases. Back up first, then set
the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/wg-easy
docker compose pull
docker compose up -d
docker compose logs --tail 30 wg-easy
```

Watch that log until it settles, then re-run step 7's three checks. Upstream also publishes a
moving `15` tag, which this file does not use.

## 10. What will probably go wrong

I closed the laptop lid, opened it an hour later, and found the admin page dead and the tunnel
gone. Nothing was broken. A sleeping machine is not a VPN server, and Docker Desktop does not
always come back with the session either. Turn on its start-at-login setting, and after a reboot
or a long sleep run `cd ~/selfhost/wg-easy && docker compose up -d` before concluding anything
is wrong. This is the part a rented server is selling: a machine that is awake when your phone
reaches for it.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change the Host in the admin panel to this machine's address on the wifi so a phone can
  join. That address moves with the network, and handing tunnel keys to a second device raises a
  security question this prompt has not answered.
- Do not enable the per-client firewall in the admin panel. Upstream marks it experimental and
  it needs host iptables rules this install does not create.
- Do not install AdGuard Home or Pi-hole alongside this. A local resolver for the tunnel's DNS
  is a separate install.
