This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing AdGuard Home 0.107.78 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read these three before step 1. LAN DNS is the real product: devices must send DNS to this
resolver or nothing is blocked. This VPS path does not open port 53 to the world; a public open
resolver is a liability. During the first-run wizard you must keep the Admin Web Interface on
port 3000, because this install only maps host 8201 to container 3000.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/adguard-home /srv/adguard-home/backups /srv/adguard-home/work /srv/adguard-home/conf
ls -la /srv/adguard-home
```

You should see: `backups`, `work` and `conf` under /srv/adguard-home, owned by your login user.

If you do not: re-run the `install -d` line. Upstream mounts `work` and `conf`. There is no empty
`data/` directory. After the wizard, `conf/AdGuardHome.yaml` holds the admin password hash.

## 3. Secrets

There are none generated in a `.env` file, and that is the whole block. The first-run wizard
creates the admin account in the browser. Choose a strong username and password, store them in a
password manager, and know that the only on-disk copy of the password hash is under `conf/` after
setup. There is no open registration form for strangers once the wizard is done.

```bash
ls -la /srv/adguard-home/work /srv/adguard-home/conf
```

You should see: both directories exist and are empty (or nearly empty) before first start.

If you do not: create them with the `install -d` line from step 2.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost. Run
`rm /srv/adguard-home/compose.yml` and paste again in one go. Notice there is no `53:53` line.
That absence is intentional on a public VPS.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Set `DOMAIN_HOST` to
your real hostname before you paste. The first line takes a copy, because a syntax error here
takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-adguard-home /etc/caddy/Caddyfile`,
reload, and paste again. Caddy requests the certificate on the first request to the hostname and
renews it on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8201` or `53`.

If you do not: delete anything for `53` or `8201`. This path must not be an open resolver. If a
rule already allowed 53 from anywhere, remove it and stop until you understand why.

## 7. Start and verify

```bash
cd /srv/adguard-home
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: the loop ending on a success-class code. Before the wizard, the page is setup.
After the wizard (with UI kept on 3000), the page is login or dashboard.

If you do not: run `docker compose logs --tail 40 adguard-home`. A 502 from Caddy with a running
container points at step 5 (wrong reverse_proxy port or a site block that never reloaded). A
container that exits on its own usually means the conf or work path is not writable; check
ownership on `/srv/adguard-home/work` and `/srv/adguard-home/conf`.

This install is local-first in spirit even on a VPS: the admin UI is what you can safely put
on the public hostname. DNS for the household still wants a LAN machine or a VPN. Do not treat
a successful Caddy certificate as proof that phones are filtering ads.

Open https://<DOMAIN> and complete the wizard if it appears. Hard requirements:

1. Admin Web Interface port: keep **3000** (do not switch to 80).
2. Create a strong admin username and password; store them offline.
3. Do not enable this host as a public DNS listener for the internet.

When the dashboard works after sign-in, run the post-wizard closure checks:

```bash
test -f /srv/adguard-home/conf/AdGuardHome.yaml && echo "conf ok"
grep -E '^(users:|name:)' /srv/adguard-home/conf/AdGuardHome.yaml | head -20
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
ss -lunpt 2>/dev/null | grep -E ':53\b' || echo "no :53 listeners (good on this path)"
```

You should see: `conf ok`, a users section in the yaml (do not paste password hashes into this
chat), a success-class code from the UI, and no public :53 listener from this install.

If the UI vanishes after the wizard, the web port left 3000. Say that plainly; recovery means
putting the web port back to 3000 in conf, not opening random ports.

Do not continue until they confirm the dashboard works and they kept the UI on 3000.

## 8. First backup and restore

One archive: `work/`, `conf/`, compose.yml, and the live Caddyfile. Take it after the wizard so
the admin hash and filter choices are inside it.

```bash
cd /srv/adguard-home
docker compose stop
sudo tar -czf /srv/adguard-home/backups/adguard-home-$(date +%F).tar.gz -C /srv/adguard-home work conf compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/adguard-home/backups/
```

You should see: one non-empty file. Downtime is a few seconds.

If you do not: an archive of about 100 bytes means `tar` found none of the paths. Run
`tar -tzf` on it and confirm `conf/` and `work/` are listed.

A backup on the same disk as the data is not a backup. On your own machine:

```bash
mkdir -p ~/backups/adguard-home
scp vps:/srv/adguard-home/backups/*.tar.gz ~/backups/adguard-home/
```

To restore: `docker compose down`, remove `work` and `conf`, recreate them, untar into
/srv/adguard-home, restore the Caddy block if needed, then `docker compose up -d`. `conf/` is
blocklists, rewrites and the admin hash. Losing conf loses the product. After restore, sign in
with the same admin password before you trust the install.

Prove the restore while risk is low: after `docker compose up -d`, wait for
`https://<DOMAIN>/` to answer, confirm `conf/AdGuardHome.yaml` still lists your user, and sign
in once. If login fails after a restore that included `work/` but not `conf/`, you restored the
wrong half. Always keep both directories in the same archive, and keep a copy of that archive off
the VPS.

## 9. Updating later

New versions are listed at https://github.com/AdguardTeam/AdGuardHome/releases. Take a backup
first, then edit the `image:` line in /srv/adguard-home/compose.yml to the new tag and its
digest.

```bash
cd /srv/adguard-home
docker compose pull
docker compose up -d
docker compose logs --tail 30 adguard-home
```

You should see: the server starting, no restart loop. Open the dashboard and confirm login still
works before you call the update done.

## 10. What will probably go wrong

You will finish the wizard, change the web port to 80 because the form suggested it, and lose
the dashboard behind Caddy. Keep the UI on 3000. The other miss is opening 53/udp on a cloud
firewall "for a quick test" and finding the box in open-resolver blocklists by Monday. This path
refuses that test. Household DNS belongs on a LAN host (local path) or behind a VPN, not as a
public recursive resolver on a cheap VPS.

A third miss is celebrating a green UI and assuming ads are blocked on the phone. Until a device
or the router uses this resolver for DNS, nothing changes. The admin UI is not a magic network
filter by itself.

A fourth miss is backing up only `work/` because it looks larger. The admin password hash and
every blocklist choice live in `conf/AdGuardHome.yaml`. Restore without `conf/` and you rebuild
the product from scratch even if query history comes back.

If you need DNS for a household from a cloud box, the honest shape is: devices join a VPN (WireGuard
or similar) whose DNS is this host on a private interface, not UDP/53 open on the public
internet. That VPN step is out of scope for this install, but it is the only safe way this VPS
path becomes a family resolver.

## 11. Out of scope

- Do not publish host port 53 on this VPS. Do not `ufw allow 53`.
- Do not move the admin web port off 3000 in the wizard.
- Do not enable DHCP on a cloud VPS.
- Do not promise NextDNS-style per-device profiles on every cellular network without a VPN or
  encrypted-DNS client config, which this install does not configure.
- Do not skip the post-wizard backup. Pre-wizard archives lack the admin hash you care about.
- Do not leave the wizard unfinished. An incomplete setup leaves the door open and the product
  half-installed.
- Do not treat this page as a drop-in for NextDNS on every cellular network. Without a VPN or
  a DoH/DoT client pointing home, phones on LTE never see this resolver.
