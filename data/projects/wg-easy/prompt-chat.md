This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing wg-easy 15.3.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` becomes `INIT_HOST`, the address written into every client
configuration this server hands out. Changing it later means editing the Host in the admin panel
and reissuing every config you have already put on a phone, so pick the hostname you intend to
keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
sudo modprobe wireguard
lsmod | grep -c '^wireguard'
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, your
server's IP, and `1` on the last line.

If you do not: an empty `dig` line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that does
not resolve and failed attempts count against a rate limit you cannot see. A `0` on the last
line is the one that ends this install: WireGuard lives in the kernel, and upstream names a
missing module as the cause of `Cannot find device "wg0"`. No container setting works around it.
On a normal VPS the module is there; on an old kernel or a container-based plan it is not, and
the honest answer is a different server.

Make the module survive a reboot:

```bash
echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf
```

You should see: `wireguard` echoed back, because `tee` prints what it writes.

If you do not: a permission error means the `sudo` was dropped from the line.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wg-easy /srv/wg-easy/backups
sudo install -d -m 700 /srv/wg-easy/etc_wireguard
ls -la /srv/wg-easy
```

You should see: `backups` owned by you, and `etc_wireguard` at mode `drwx------` owned by root.

If you do not: leave `etc_wireguard` owned by root on purpose. The published image declares no
user, so the container runs as root and writes there as root. That directory is the entire
install: `wg-easy.db` holds the admin account and every client's private key, and `wg0.conf` is
rewritten from that database on every change.

## 3. Secrets

One secret: the password for the `admin` account the container creates on its first start. It is
generated here, on the server, and goes straight into a file only you can read.

```bash
umask 077
cat > /srv/wg-easy/.env <<EOF
INIT_ENABLED=true
INIT_USERNAME=admin
INIT_PASSWORD=$(openssl rand -base64 24)
INIT_HOST=<DOMAIN>
INIT_PORT=51820
INIT_DNS=1.1.1.1
INIT_ALLOWED_IPS=0.0.0.0/0
EOF
chmod 600 /srv/wg-easy/.env
umask 022
ls -l /srv/wg-easy/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the `INIT_HOST` line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/wg-easy/.env` and carry
on. If the file already existed from an earlier attempt, this block has overwritten the
password, which is harmless before the first container start and useless after it: once the
account exists in the database, upstream ignores `INIT_` entirely and the way to change a
password is `docker compose exec -it wg-easy cli db:admin:reset`.

Read the password once with `sudo grep INIT_PASSWORD /srv/wg-easy/.env` and put it in your
password manager now. Step 7 deletes that line, which is what upstream recommends once the setup
has run, and after that the file no longer has it.

Do not paste that file, the password, or any command output containing it into this chat window.
The agent path never sees those values; a chat window hands them to a third party.

`INIT_DNS` and `INIT_ALLOWED_IPS` carry one value each because step 4 turns IPv6 off, and a
client handed an IPv6 resolver and a `::/0` route would push its IPv6 traffic into a tunnel with
no IPv6 address on it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/wg-easy/compose.yml <<'EOF'
# wg-easy · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   getting started .... https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/getting-started.md
#   basic installation . https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/examples/tutorials/basic-installation.md
#   optional config .... https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/advanced/config/optional-config.md
#   unattended setup ... https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/advanced/config/unattended-setup.md
#   caddy example ...... https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/examples/tutorials/caddy.md
#
# One service and no database process. The admin UI, the wg0 interface and the
# SQLite file holding the account and every client key live in this container,
# and /etc/wireguard is the whole of the state.
#
# Two deliberate differences from the compose file upstream ships:
#   * SYS_MODULE is not granted and /lib/modules is not mounted. That
#     capability lets a container load kernel modules, which is a way out of
#     it; the install loads the wireguard module on the host instead.
#   * DISABLE_IPV6 is true. Upstream documents that as dropping the IPv6
#     firewall rules and the IPv6 address on the interface and on clients. It
#     takes the ip6tables kernel tables off the host's requirements and the
#     IPv6 Docker network out of this file. Tunnels here carry IPv4.
#
# Tag and digest read from ghcr.io on 2026-08-06; amd64 and arm64 published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15.3.0@sha256:93bbd593e07bab98d02807a28770ac87ab6c48818e319e68c1f66561feb99876
    container_name: wg-easy
    restart: unless-stopped
    env_file: /srv/wg-easy/.env
    environment:
      # Upstream's default, kept explicit. The session cookie is marked Secure,
      # so the admin UI works over https and refuses a login over plain http.
      INSECURE: "false"
      DISABLE_IPV6: "true"
    volumes:
      - /srv/wg-easy/etc_wireguard:/etc/wireguard
    ports:
      # The tunnel. Phones and laptops speak WireGuard straight to this port,
      # so no reverse proxy can stand in front of it. It answers nothing at all
      # to a packet that is not signed by a key this install issued.
      - "51820:51820/udp"
      # The admin UI. Loopback only: the host's Caddy is the only thing that
      # reaches 8133.
      - "127.0.0.1:8133:51821"
    cap_add:
      # Creating wg0, writing its routes, and the NAT rule the PostUp hook adds.
      - NET_ADMIN
    sysctls:
      # Packets arriving on wg0 have to be routed out of eth0.
      - net.ipv4.ip_forward=1
      # wg-quick marks its own packets; without this the kernel drops them as
      # martians on the way back.
      - net.ipv4.conf.all.src_valid_mark=1
EOF
cd /srv/wg-easy && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/wg-easy/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal,
so run `rm /srv/wg-easy/compose.yml` and paste again in one go. The `sysctls` block is not
decoration: without `ip_forward` the tunnel comes up and forwards nothing, which is the failure
that looks like a DNS problem.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-wg-easy
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# wg-easy · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/examples/tutorials/caddy.md
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Caddy carries the
# admin UI and nothing else: the tunnel itself is UDP on 51820 and never passes
# through here.

<DOMAIN> {
	encode zstd gzip

	header {
		# The admin UI issues client keys, so a downgrade on one request is a
		# stolen tunnel. HSTS is not optional here.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8133 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8133
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-wg-easy /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the container, which is why
`INSECURE` stays `false` in the compose file: the session cookie is marked Secure, and the
sign-in page refuses a password typed over plain http.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 51820/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp`, `443/udp` and `51820/udp`, and
no rule mentioning `8133`.

If you do not: delete anything for `8133` with `sudo ufw delete allow 8133`. It is bound to
127.0.0.1 by the compose file, so a firewall rule for it would only widen what Caddy already
fronts. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp carries the admin UI,
443/udp is HTTP/3. 51820/udp is different in kind: WireGuard is the transport, phones send
encrypted UDP straight at it, and no reverse proxy can carry that. What sits on that port is a
socket that stays silent to every packet it cannot verify against a key this install issued,
which is why WireGuard belongs on a public port and the admin UI does not. One thing to know
about that fourth rule: Docker writes its own iptables rules for a published port ahead of
ufw's, so deleting it would not close 51820/udp. `docker compose down` does. `Status: inactive`
is a different problem: Prompt Zero left this firewall enabled, so something has turned it off
since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

```bash
cd /srv/wg-easy
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -H 'Accept-Language: en' https://<DOMAIN>/login | grep -o 'Sign In'
docker compose exec -T wg-easy wg show
```

You should see, in order: the loop reaching `200`, the word `Sign In`, then a block beginning
`interface: wg0` with a `listening port: 51820` line.

If you do not: `Cannot find device "wg0"` in the logs means step 1's module check was skipped or
the module was unloaded, so run `sudo modprobe wireguard` and `docker compose up -d` again. A
`502` from Caddy means nothing is listening on 8133: check `docker compose ps` and
`docker compose logs --tail 40 wg-easy`. If the loop never reaches `200` but the container is
running, the certificate is probably still being issued; give it another minute. A running
container is not success, and that third command is why: the web server can be perfectly healthy
while the tunnel does not exist.

The first screen at https://<DOMAIN>/login is a card with `Username` and `Password` boxes and a
`Sign In` button. There is no register link and no default account.

Now open https://<DOMAIN> in a browser, sign in as `admin` with the password from
`sudo grep INIT_PASSWORD /srv/wg-easy/.env`, and save that password in your password manager.
Then add a client named `phone`, install the WireGuard app on that phone, scan the QR code the
page shows, and switch the tunnel on.

Once the phone says it is connected, prove the handshake and clear the password out of the
environment:

```bash
cd /srv/wg-easy
docker compose exec -T wg-easy wg show | grep -c 'latest handshake'
sed -i '/^INIT_/d' /srv/wg-easy/.env
docker compose up -d --force-recreate
sleep 15
sudo grep -c '^INIT_' /srv/wg-easy/.env || true
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/login
```

You should see: `1` or more, then `0`, then `200`.

If you do not: a `0` from the first command means the phone never completed a handshake. Check
that the tunnel switch is actually on, then that `sudo ufw status verbose` really lists
51820/udp, then whether your hosting provider runs a firewall of its own in front of the box,
because several do and UDP is what gets forgotten there. The `0` from the third command is the
one you want: the password is no longer in a file the container reads on every start, which is
what upstream recommends once the setup is done, and the final `200` proves the account and the
clients live in the database rather than in those variables.

## 8. First backup and restore

One archive. The database, the interface config, the compose file and the Caddy site block are
the whole install, and together a few hundred kilobytes.

```bash
cd /srv/wg-easy
docker compose down
sudo tar -czf /srv/wg-easy/backups/wg-easy-$(date +%F).tar.gz -C /srv/wg-easy compose.yml .env etc_wireguard -C /etc/caddy Caddyfile
docker compose up -d
ls -lh /srv/wg-easy/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install. The container is down for
about twenty seconds, on purpose, because `wg-easy.db` is SQLite and a file copied mid-write is
not a database. Connected clients reconnect on their own.

If you do not: a `.tar.gz` of about 100 bytes means the archive is empty, so check that
`/srv/wg-easy/etc_wireguard` has files in it. A `Permission denied` means the `sudo` was dropped
from the `tar` line; that directory belongs to root.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/wg-easy
scp vps:/srv/wg-easy/backups/*.tar.gz ~/backups/wg-easy/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/wg-easy/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one test client:

```bash
cd /srv/wg-easy
docker compose down
sudo rm -rf /srv/wg-easy/etc_wireguard
sudo tar -xzf /srv/wg-easy/backups/wg-easy-$(date +%F).tar.gz -C /srv/wg-easy compose.yml .env etc_wireguard
docker compose up -d
sleep 20
docker compose exec -T wg-easy wg show | grep -c '^peer:'
```

You should see: `1`, the client you enrolled coming back out of the archive and into the live
interface.

If you do not: `0` peers means the archive did not contain the database, so check the archive
listing with `tar -tzf` before trusting it. Understand the stakes before you skip this: that
database holds the private key of every device you have enrolled, so an archive that leaks is
every tunnel opened, and an archive that is missing means re-enrolling every phone by hand.

## 9. Updating later

New versions are listed at https://github.com/wg-easy/wg-easy/releases. Take the backup first,
then edit the `image:` line in /srv/wg-easy/compose.yml to the new tag and its digest.

```bash
cd /srv/wg-easy
docker compose pull
docker compose up -d
docker compose logs --tail 30 wg-easy
```

You should see: migration lines, then the banner with the version number, and no repeating
restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
three checks from step 7 before you call the update done, including `wg show`, because the web
interface can come back perfectly while the interface fails to start. Upstream also publishes a
moving `15` tag that this file deliberately does not use; a major-version jump has migrated the
database before, so read the release notes before changing the first number.

## 10. What will probably go wrong

The web interface will come up, the phone will say `Connected`, and no page will load on it. I
lost twenty minutes to that. The tunnel was fine and nothing was being forwarded out of the box,
because a WireGuard peer that cannot route still reports a healthy handshake, and the symptom
reads exactly like a DNS fault. Check in this order: `docker compose exec -T wg-easy wg show`
for a recent handshake, then `docker compose exec -T wg-easy sysctl net.ipv4.ip_forward`, then
`docker compose exec -T wg-easy iptables -t nat -L POSTROUTING -n` for the MASQUERADE line the
PostUp hook writes.

## 11. Out of scope

- Do not enable the per-client firewall in the admin panel. Upstream marks it experimental and
  it needs host iptables rules this install does not create.
- Do not install AdGuard Home or Pi-hole alongside this. Pointing the tunnel's DNS at a resolver
  on the same box is a second install with its own prompt, not a setting in this one.
- Do not enable the Prometheus metrics endpoint. It is off by default and turning it on adds a
  route with no authentication unless a bearer password is set as well.
- Do not set `EXPERIMENTAL_AWG`. That trades a standard WireGuard tunnel every client app
  already speaks for an obfuscated one.
