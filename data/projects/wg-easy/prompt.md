You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install wg-easy 15.3.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say why when you ask: that hostname becomes `INIT_HOST` in step 3, the address every client
configuration this install hands out will dial. Its A record must already point at this server.

wg-easy needs 512 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64. One requirement is not about size: WireGuard lives in the kernel, and the container
cannot create `wg0` if this kernel has no module for it.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
sudo modprobe wireguard
lsmod | grep -c '^wireguard'
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop. If the last command
prints `0`, stop and tell the user this kernel carries no WireGuard module: upstream names that
as the cause of `Cannot find device "wg0"`, and no container setting works around it. It
usually means an old kernel or a container-based VPS plan.

Make the module survive a reboot:

```bash
echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf
```

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/wg-easy /srv/wg-easy/backups
sudo install -d -m 700 /srv/wg-easy/etc_wireguard
ls -la /srv/wg-easy
```

Assert: `ls -la` shows `backups` owned by the login user and `etc_wireguard` at mode `700`
owned by root. The published image declares no user, so the container runs as root and writes
that directory as root; leave it alone. Everything this service remembers is in there:
`wg-easy.db`, holding the admin account and every client's private key, and `wg0.conf`, which
the app rewrites from that database on every change.

## 3. Secrets

One secret: the password for the `admin` account the container creates on its first start.
Generate it on the server. Do not print it, do not repeat it in your summary, and do not put
it in a log line.

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

Assert: the file exists with mode `-rw-------`. Upstream documents this `INIT_` group as an
unattended setup read only during the container's first start, and recommends removing the
variables once it is done; step 7 removes them. The generated password is 32 characters, which
matters because upstream rejects any password under 12 and checks nothing else. `INIT_DNS` and
`INIT_ALLOWED_IPS` carry one value each because step 4 turns IPv6 off, and handing clients an
IPv6 resolver and a `::/0` route would push their IPv6 traffic into a tunnel with no IPv6
address on it.

Tell the user their password is in /srv/wg-easy/.env, read with
`sudo grep INIT_PASSWORD /srv/wg-easy/.env`, and that it belongs in their password manager
before step 7 runs, because step 7 deletes that line.

## 4. compose.yml

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

Assert: that prints `compose OK`. The `sysctls` block is not decoration: without
`ip_forward` the tunnel comes up and forwards nothing, which is the failure that
looks like a DNS problem.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-wg-easy, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own. Nothing to schedule.

## 6. Firewall

Four ports, and the fourth is the one this install exists for:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 51820/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp carries the admin UI, 443/udp
is HTTP/3. 51820/udp is different in kind: WireGuard is the transport, phones send encrypted
UDP straight at it, and no reverse proxy can carry that. What sits there is a socket that stays
silent to every packet it cannot verify against a key this install issued, which is why
WireGuard belongs on a public port and the admin UI on 8133 does not.

Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp, 443/udp and 51820/udp,
and no rule for 8133. Tell the user one thing about that fourth rule: Docker writes its own
iptables rules for a published port ahead of ufw's, so deleting it would not close 51820/udp.
`docker compose down` does.

## 7. Start and verify

```bash
cd /srv/wg-easy
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -H 'Accept-Language: en' https://<DOMAIN>/login | grep -o 'Sign In'
docker compose exec -T wg-easy wg show
```

Assert all three and print what you received. The loop ends printing `200`. The second prints
`Sign In`, the button on the only screen this app shows a stranger. The third prints a block
beginning `interface: wg0` with a `listening port: 51820` line, which is the tunnel existing
rather than the web server existing. If any of the three misses, stop, run
`docker compose logs --tail 40 wg-easy`, and name the likely step: `Cannot find device "wg0"`
is step 1's module check having been skipped, and a `502` from Caddy is step 5 pointing at a
port nothing is listening on. A running container is not success.

The first screen at https://<DOMAIN>/login is a card with `Username` and `Password` boxes and a
`Sign In` button. There is no register link and no default account.

STOP: tell the user to open https://<DOMAIN>, sign in as `admin` with the password from
`sudo grep INIT_PASSWORD /srv/wg-easy/.env`, save that password in their password manager, add
a client named `phone`, install the WireGuard app on that phone, scan the QR code the page
shows, and switch the tunnel on. Wait. Do not continue until they confirm the phone says it is
connected. Only a real device proves this end to end.

Once they confirm, prove the handshake, then take the password out of the environment:

```bash
cd /srv/wg-easy
docker compose exec -T wg-easy wg show | grep -c 'latest handshake'
sed -i '/^INIT_/d' /srv/wg-easy/.env
docker compose up -d --force-recreate
sleep 15
sudo grep -c '^INIT_' /srv/wg-easy/.env || true
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/login
```

Assert all three before you report success. The first prints `1` or more, the phone and the
server having agreed keys and moved packets. The third prints `0`, so the password no longer
sits in a file the container reads on every start, which is what upstream recommends once the
setup is done. The last prints `200`: the account and the clients live in the database now, so
losing those variables changes nothing.

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

Assert: the archive exists and is non-empty. Print its size. The container goes down for the
copy on purpose: `wg-easy.db` is SQLite and a file copied mid-write is not a database. The
tunnel is gone for about twenty seconds and every client reconnects on its own.

A backup on the same disk is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/wg-easy
scp vps:/srv/wg-easy/backups/*.tar.gz ~/backups/wg-easy/
```

To restore: `docker compose down`, `sudo rm -rf /srv/wg-easy/etc_wireguard`,
`sudo tar -xzf <archive> -C /srv/wg-easy compose.yml .env etc_wireguard`, then
`docker compose up -d`. The Caddy site block is in the same archive under `Caddyfile` if
/etc/caddy has to be rebuilt. Say the stakes plainly: that database holds the private key of
every device the user has enrolled, so a leaked archive is every tunnel opened, and a missing
one means re-enrolling every phone by hand.

## 9. Updating later

New versions are listed at https://github.com/wg-easy/wg-easy/releases. Back up first, then
edit the image line in /srv/wg-easy/compose.yml to the new tag and its digest:

```bash
cd /srv/wg-easy
docker compose pull
docker compose up -d
docker compose logs --tail 30 wg-easy
```

Watch that log until it settles, then re-run the three checks from step 7. Upstream publishes a
moving `15` tag this file does not use; a major-version jump has migrated the database before,
so read the notes before changing the first number.

## 10. What will probably go wrong

The interface will come up, the phone will say `Connected`, and no page will load on it. I lost
twenty minutes to that. The tunnel was fine and nothing was being forwarded out of the box,
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
