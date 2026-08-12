You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install AdGuard Home 0.107.78 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say three things before anything is installed, because they decide whether this path is the right
one. One: LAN DNS is the real product. Blocking ads for phones and laptops means those devices
send DNS to this resolver; an admin UI alone does nothing. Two: this VPS path does not open port
53 to the world. A public recursive resolver is an open-resolver risk, and this catalog will not
ship that shape. Use this install for the admin UI from the internet (or over a VPN), and put
household DNS on a LAN machine or reach the resolver through a VPN. Three: during the first-run
wizard you must keep the Admin Web Interface on port 3000. This compose maps host 8201 to
container 3000 only. If the wizard moves the UI to port 80, Caddy keeps talking to 3000 and the
dashboard disappears.

AdGuard Home needs 512 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
hostname that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/adguard-home /srv/adguard-home/backups /srv/adguard-home/work /srv/adguard-home/conf
ls -la /srv/adguard-home
```

Assert: `ls -la` shows `backups`, `work` and `conf` owned by the login user. Upstream mounts
`/opt/adguardhome/work` and `/opt/adguardhome/conf`. There is no empty `data/` directory in this
install. `conf/` will hold AdGuardHome.yaml (including the admin password hash) after the wizard.
`work/` holds query logs and filter data.

## 3. Secrets

No secret is generated for this install and there is no `.env` file. That is not an oversight.
The first-run wizard creates the admin account in the browser, and the hash lands in
`conf/AdGuardHome.yaml`. There is no default password to rotate before first login, and there is
no open registration form after setup: only the accounts you create. Step 7 closes the wizard
path by asserting the dashboard requires a completed setup and a login.

Tell the user: when the wizard asks for a username and password, choose both carefully and store
them in a password manager. After setup, the only copy of that password hash on disk is under
`conf/`.

## 4. compose.yml

```bash
cat > /srv/adguard-home/compose.yml <<'EOF'
# AdGuard Home · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker ............. https://github.com/AdguardTeam/AdGuardHome/wiki/Docker
#   configuration ...... https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration
#
# One container. Admin UI is published only on loopback at host 8201 mapped to
# container 3000. DNS ports are deliberately NOT published on this VPS path: a
# public open resolver is a liability, and household DNS belongs on a LAN host
# or behind a VPN. During the first-run wizard the operator must keep the web
# interface on port 3000 so this publish mapping continues to work after setup.
# Volumes are work/ and conf/ (upstream's real paths), not an empty data/.
# Digest for v0.107.78 read from Docker Hub on 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  adguard-home:
    image: adguard/adguardhome:v0.107.78@sha256:1ea34eafe5dc691007946e8eaab7bf46b0de9412f39213d8c06e48b53bf9a6c5
    container_name: adguard-home
    restart: unless-stopped
    volumes:
      - /srv/adguard-home/work:/opt/adguardhome/work
      - /srv/adguard-home/conf:/opt/adguardhome/conf
    ports:
      # Loopback only: Caddy reaches the admin UI. Keep wizard web port at 3000.
      - "127.0.0.1:8201:3000"
EOF
cd /srv/adguard-home && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, two bind mounts, no DNS port
on the host. That missing 53 is intentional.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-adguard-home
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" <<'EOF' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
# AdGuard Home · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration#encryption and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project. This site
# block fronts the admin UI only. It does not make this host a public DNS
# resolver; port 53 stays closed on the VPS path.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8201 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8201
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `DOMAIN_HOST` to the real hostname before the `sed` runs. Assert: `caddy validate` exits 0
and the reload exits 0. If validate fails, restore /etc/caddy/Caddyfile.before-adguard-home,
reload, and report what it objected to.

## 6. Firewall

Two ports open, both Caddy's. Do not open 53:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8201 or 53. If anything allows 53 from anywhere, delete that rule and stop until the
user understands why this path refuses to be a public resolver.

## 7. Start and verify

```bash
cd /srv/adguard-home
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert: the loop ends on a success-class code and the container is running. Before the wizard,
the page is the setup flow. After the wizard (with UI kept on 3000), the page is the login or
dashboard.

STOP: tell the user to open https://<DOMAIN> and complete the wizard now if it appears. Hard
requirements during the wizard:

1. Admin Web Interface port: keep **3000** (do not switch to 80).
2. Create a strong admin username and password; store them offline.
3. Do not enable this host as a public DNS listener for the internet.

When they finish, they must confirm back to you that they can sign in and see the dashboard.
Do not continue until they confirm.

Post-wizard closure asserts (run only after they confirm the dashboard works):

```bash
# Config file exists and names a user (admin credential lives here).
test -f /srv/adguard-home/conf/AdGuardHome.yaml && echo "conf ok"
grep -E '^(users:|name:|password:)' /srv/adguard-home/conf/AdGuardHome.yaml | head -20
# UI still answers on the mapped port through Caddy.
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
# Port 53 must not be published on non-loopback addresses.
ss -lunpt 2>/dev/null | grep -E ':53\b' || echo "no :53 listeners (good on this path)"
```

Assert: `conf ok` prints, the yaml shows a users section (do not print password hashes into the
chat summary), the UI still returns a success-class code, and there is no public :53 listener
created by this install. If the UI returns connection failures after the wizard, the web port
was moved off 3000: say that plainly and stop; recovery means editing conf to put the web port
back to 3000 or republishing the new port, which this path does not do by default.

A running container is not success; a signed-in dashboard with conf present is.

## 8. First backup and restore

One archive: `work/`, `conf/`, compose.yml, and the live Caddy site block. Take a backup after
the wizard so the admin hash and filter choices are inside it.

```bash
cd /srv/adguard-home
docker compose stop
sudo tar -czf /srv/adguard-home/backups/adguard-home-$(date +%F).tar.gz -C /srv/adguard-home work conf compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/adguard-home/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds.

A backup on the same disk as the data is not a backup. From the user's machine:

```bash
mkdir -p ~/backups/adguard-home
scp vps:/srv/adguard-home/backups/*.tar.gz ~/backups/adguard-home/
```

To restore: `docker compose down`, remove `work` and `conf`, recreate them as in step 2, untar
into /srv/adguard-home, put the Caddy block back if needed, then `docker compose up -d`. Tell
the user: `conf/` is blocklists, rewrites and the admin hash; `work/` is query history and
runtime state. Losing conf loses the product.

## 9. Updating later

New versions are listed at https://github.com/AdguardTeam/AdGuardHome/releases. Take a backup
first, then edit the image line in /srv/adguard-home/compose.yml to the new tag and its digest:

```bash
cd /srv/adguard-home
docker compose pull
docker compose up -d
docker compose logs --tail 30 adguard-home
```

Watch that log until it settles, then open the dashboard and confirm login still works before
calling the update done.

## 10. What will probably go wrong

You will finish the wizard, feel proud, and then change the web port to 80 because the form
suggested it. The dashboard will vanish behind Caddy. I did that once and spent an hour on TLS
before noticing 8201 still pointed at an empty 3000. Keep the UI on 3000. The other miss is
opening 53/udp on a cloud firewall "for a quick test" and discovering the box is in open-resolver
blocklists by Monday. This path refuses that test. If the household needs DNS, install on a LAN
host with the local path, or put devices on a VPN that reaches a resolver you control.

## 11. Out of scope

- Do not publish host port 53 on this VPS. Do not `ufw allow 53`.
- Do not move the admin web port off 3000 in the wizard.
- Do not enable DHCP on a cloud VPS.
- Do not promise NextDNS-style per-device profiles on every cellular network without a VPN or
  encrypted-DNS client config, which this install does not configure.
- Do not skip the post-wizard backup. Pre-wizard archives lack the admin hash you care about.
