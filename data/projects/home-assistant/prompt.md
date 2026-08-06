You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Home Assistant 2026.7.4 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Home Assistant needs 1024 MB of RAM available and 5 GB free on /srv. The 2026.7.4 image is
published for amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a hostname that does not resolve.

Say one thing to the user before anything installs. On a rented machine the integrations that
work are the ones reaching a device over the internet or over an address they type in. Nothing
on this server's network segment is theirs, so mDNS and SSDP discovery, Bluetooth and USB
radios are all out of reach. A hub for the sensors in their house belongs in their house.

## 2. Layout

Home Assistant writes its own configuration file on the first start, and this install cannot
let it, because the file has to name the reverse proxy before the first request arrives.
Upstream is explicit: a request from a proxy is blocked until the proxy is trusted. Write the
tree and all four files now.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/home-assistant /srv/home-assistant/backups
sudo install -d -m 750 /srv/home-assistant/config /srv/home-assistant/config/themes
sudo tee /srv/home-assistant/config/configuration.yaml >/dev/null <<'EOF'
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

# Caddy terminates TLS on this host and forwards to 127.0.0.1:8107. Home
# Assistant rejects a proxied request with 400 until it is told which addresses
# are allowed to set X-Forwarded-For, which is why this block exists before the
# first start rather than after it. Docker rewrites the source address of a
# published-port connection to the gateway of the container's bridge network,
# and that gateway is assigned by Docker and moves when the network is
# recreated, so the range is what holds rather than one address.
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1/32
    - 172.16.0.0/12
  ip_ban_enabled: true
  login_attempts_threshold: 5

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
EOF
printf '[]\n' | sudo tee /srv/home-assistant/config/automations.yaml >/dev/null
sudo touch /srv/home-assistant/config/scripts.yaml /srv/home-assistant/config/scenes.yaml
sudo ls -la /srv/home-assistant/config
```

Assert: `ls -la` lists `configuration.yaml`, `automations.yaml`, `scripts.yaml`, `scenes.yaml`
and `themes`, all owned by root. The container runs as root, so root owns this directory and
the user reads it with `sudo`. The two empty files and the empty list exist because the
include lines point at them and a missing include is a start-up error.

## 3. Secrets

Nothing is generated here and there is no `.env` file. Home Assistant's only credential is the
owner account, and it is created in a browser at step 7 rather than written into a file now.
That is why this block has nothing to run.

Say one thing to the user. Between the container starting and that account existing, the
onboarding form is open to whoever loads the hostname first, and the first person through it
owns the house. Step 7 makes that window as short as it can be, and it is a hard stop for that
reason.

## 4. compose.yml

```bash
cat > /srv/home-assistant/compose.yml <<'EOF'
# Home Assistant · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   container install .. https://www.home-assistant.io/installation/linux/
#   http integration ... https://www.home-assistant.io/integrations/http/
#   remote access ...... https://www.home-assistant.io/docs/configuration/remote/
#
# One container. Upstream's own example sets network_mode: host and
# privileged: true, because at home that is how Home Assistant finds devices
# over mDNS and SSDP and reaches a USB radio. A rented server has no devices on
# its network segment and no radio plugged into it, so this file drops both and
# publishes one loopback port instead. Everything lives under /config: the
# configuration file, the .storage directory holding the accounts, and the
# recorder database. Upstream pins the floating :stable tag; this file pins the
# 2026.7.4 release and the digest read from ghcr.io on 2026-08-06, published
# for linux/amd64 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:2026.7.4@sha256:5a531753cea96444200158fc2b0ac7ccd739291ec50414877b396de6e0bb29b3
    container_name: homeassistant
    restart: unless-stopped
    environment:
      # This labels the container's log timestamps. Home Assistant's own time
      # zone is a separate setting, chosen during onboarding.
      TZ: UTC
    volumes:
      # The image runs as root, so this directory and everything the container
      # writes into it belong to root on the host.
      - /srv/home-assistant/config:/config
    ports:
      # Loopback only. The host's Caddy is the only thing that reaches 8107.
      # 8123 is the port Home Assistant listens on inside the container.
      - "127.0.0.1:8107:8123"
EOF
cd /srv/home-assistant && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Do not add `network_mode: host` or `privileged: true` from
the upstream example. Host networking would bind 8123 to every interface on a public machine,
which is the opposite of what step 6 is protecting, and the hardware access privileged mode
grants has nothing here to reach.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-home-assistant
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Home Assistant · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.home-assistant.io/docs/configuration/remote/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under
# systemd on the host; there is no Caddy container in this project.
#
# Caddy adds X-Forwarded-For on its own, and Home Assistant answers 400 to a
# request carrying that header until configuration.yaml lists the proxy under
# trusted_proxies. That file is written before the first start for exactly this
# reason, and this block cannot make up for a missing one.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# The dashboard holds a WebSocket open for as long as a tab is open. Caddy
	# negotiates that upgrade itself, so there are no Upgrade or Connection
	# headers to set by hand.
	#
	# 8107 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8107
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-home-assistant, reload, and report what it objected to. Caddy
requests the certificate on the first request and renews it on its own, so there is no
renewal to schedule.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3. 8107 stays closed because compose bound it to 127.0.0.1, so a rule for it
would cover traffic that cannot arrive; if one is there a previous run left it, and
`sudo ufw delete allow 8107` removes it. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule for 8107 or 8123.

## 7. Start and verify

The first start is slow. Home Assistant installs the Python requirements for the integrations
`default_config` pulls in before it serves anything, and on a small server that takes minutes.
The loop below waits for it.

```bash
cd /srv/home-assistant
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/onboarding); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/onboarding
echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/
```

Assert, all three, and print what you received for each. The loop ends printing `200`. The
onboarding response contains `"step":"user","done":false`. The last command prints `401`,
because that endpoint needs a token and refusing without one is the security assert in this
block.

If the loop returns `400` instead, stop: that is Home Assistant rejecting a request from an
untrusted proxy, so step 2 wrote the wrong file or wrote it after the first start. Check with
`sudo grep -A4 trusted_proxies /srv/home-assistant/config/configuration.yaml`, then
`docker compose restart`. If the loop returns `502` for the whole forty rounds, run
`docker compose logs --tail 40 homeassistant` and read it before touching anything else. A
running container is not success.

The first screen at https://<DOMAIN> shows the heading `Welcome!` and a button reading
`Create my smart home`. Until someone submits that form, anyone who loads the page can.

STOP: tell the user to open https://<DOMAIN> right now, create the owner account, and save the
password in their password manager. Wait until they confirm.

Then prove it closed:

```bash
curl -sS https://<DOMAIN>/api/onboarding
echo
```

Assert: the response now contains `"step":"user","done":true`. Have the user also open
https://<DOMAIN> in a private window and confirm they see a sign-in form and no
`Create my smart home` button. Both asserts must pass before you report success.

## 8. First backup and restore

Take the backup now, before the user adds a single device. Stop first: the recorder database
under /config is SQLite, and a copy taken mid-write is not a backup.

```bash
cd /srv/home-assistant
docker compose stop
sudo tar -czf /srv/home-assistant/backups/home-assistant-$(date +%F).tar.gz -C /srv/home-assistant config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/home-assistant/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about ten seconds.
`config` is the whole install: the configuration file, the `.storage` directory holding the
owner account and every integration's credentials, and `home-assistant_v2.db` of history.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/home-assistant
scp vps:/srv/home-assistant/backups/*.tar.gz ~/backups/home-assistant/
```

To restore: `docker compose down`, `sudo rm -rf /srv/home-assistant/config`,
`sudo tar -C /srv/home-assistant -xzf` the archive, then `docker compose up -d`. Those four
commands are the whole disaster plan. Tell the user the `.storage` directory is the part that
matters most: it holds the tokens for every integration they will ever link, and losing it
means linking all of them again by hand.

## 9. Updating later

New versions are listed at https://github.com/home-assistant/core/releases. Take a backup
first, then edit the image line in /srv/home-assistant/compose.yml to the new tag and digest:

```bash
cd /srv/home-assistant
docker compose pull
docker compose up -d
docker compose logs --tail 30 homeassistant
```

Home Assistant migrates its own storage on the way up, so watch that log until it settles, then
re-run the check from step 7 before calling the update done.

One thing to tell the user before they take a release from the 2026.8 series or later. Those
releases move the HTTP settings out of `configuration.yaml` and into the interface, under
Settings then System then Network. The `http:` block written in step 2 is imported once on the
first start after the upgrade and then has to be confirmed there, and the confirmation window
is short. If the site starts answering 400 after an upgrade, the way back in is an SSH tunnel
to the loopback port, `ssh -L 8107:127.0.0.1:8107 vps`, and then http://localhost:8107 in a
browser to set the trusted proxies again.

## 10. What will probably go wrong

The first boot looks like a failure for several minutes. I brought this up, watched Caddy
return `502` for four minutes straight, decided the reverse proxy was wrong, and started
editing the Caddyfile while Home Assistant was still installing the Python packages that
`default_config` asks for. Nothing was broken. The container fetches and builds requirements
for two dozen integrations before it opens a socket, and on a one-core server that is slow
enough to be alarming. Let the loop in step 7 run all forty rounds before concluding anything,
and read `docker compose logs -f homeassistant` while you wait rather than changing files.

## 11. Out of scope

- Do not set `network_mode: host` or `privileged: true`. They are in the upstream example for a
  machine sitting on the user's home network; on a public server they bind 8123 to every
  interface and grant hardware access to nothing.
- Do not configure the Alexa or Google Assistant integrations. Upstream's manual route for each
  needs an AWS Lambda function or a Google Home Developer Console project, and that is a
  separate afternoon, not a step in this install.
- Do not install HACS or any add-on. Add-ons belong to the Home Assistant Operating System
  install type and do not exist in a container install.
- Do not configure SMTP or any notify platform. Home Assistant runs without mail, and the
  channels the user wants are accounts and tokens they pick in the interface.
