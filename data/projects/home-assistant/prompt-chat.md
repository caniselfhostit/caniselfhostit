This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Home Assistant 2026.7.4 on a VPS where Prompt Zero is done: `ssh vps`
works, Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A
record already points at the box.

Read this before step 1, because it decides whether you want this install at all. On a rented
machine the integrations that work are the ones that reach a device over the internet or over
an address you type in. Nothing on the server's network segment is yours, so the discovery
that finds a Hue bridge or a Sonos speaker on its own will never fire here, and neither
Bluetooth nor a USB radio is reachable. A hub for the sensors in your house belongs in your
house. What this gives you is a Home Assistant with a public address, which is the half that
Home Assistant Cloud sells.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 1024 MB of
available RAM, stop and resize the server: the first boot installs a few dozen Python packages
and the OOM killer arrives in the middle of it, which looks like a random crash rather than a
machine that is too small.

## 2. Layout

Home Assistant writes its own configuration file on the first start, and this install cannot
let it, because the file has to name the reverse proxy before the first request arrives.
Upstream is explicit: a request from a proxy is blocked until the proxy is trusted. Paste the
whole block at once, including the last four lines.

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

You should see: `configuration.yaml`, `automations.yaml`, `scripts.yaml`, `scenes.yaml` and
`themes`, all owned by `root`.

If you do not: root ownership is correct and not something to fix. The container runs as root,
so it writes root-owned files here, and you read them with `sudo`. If `scripts.yaml` or
`scenes.yaml` is missing, create it with `sudo touch`: the include lines at the bottom of
`configuration.yaml` point at those files, and a missing include stops Home Assistant from
starting with an error that names the file rather than the include.

## 3. Secrets

Nothing is generated here and there is no `.env` file. Home Assistant has one credential, the
owner account, and you create it in a browser at step 7.

Between the container starting and that account existing, the onboarding form is open to
whoever loads your hostname first, and the first person through it owns the house. Step 7 is
written to make that window short, which is why it asks you to stop reading and go create the
account the moment the checks pass.

Nothing in this guide asks you to paste a credential into this chat window. Do not paste the
owner password, the contents of anything under `/srv/home-assistant/config/.storage`, or the
output of any command containing either, at any point.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/home-assistant/compose.yml` and paste again in one go. Do not add
`network_mode: host` or `privileged: true` from the upstream example, however many guides tell
you to. Host networking would bind 8123 to every interface on a machine with a public IP, which
undoes step 6, and privileged mode grants hardware access to a server with no hardware attached.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-home-assistant /etc/caddy/Caddyfile`,
reload, and paste again. The most common cause is a `<DOMAIN>` you forgot to replace, which
Caddy reports as an invalid site address. Caddy requests the certificate on the first request
and renews it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8107` or `8123`.

If you do not: delete anything for `8107` or `8123` with `sudo ufw delete allow 8107`. 8107 is
bound to 127.0.0.1 by the compose file, so a rule for it would cover traffic that cannot
arrive, and 8123 exists only inside the container. 80/tcp is there to redirect to HTTPS and to
answer the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy
offers by default. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back before you go
any further.

## 7. Start and verify

The first start is slow. Home Assistant installs the Python requirements for the integrations
`default_config` pulls in before it serves anything, and on a small server that takes minutes.
The loop below waits for it, up to ten minutes.

```bash
cd /srv/home-assistant
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/onboarding); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS https://<DOMAIN>/api/onboarding
echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/
```

You should see, in order: the loop counting up and reaching `200`, then a line containing
`"step":"user","done":false`, then `401`.

If you do not: the number the loop settles on tells you which step to look at. A `400` is Home
Assistant rejecting a request from a proxy it does not trust, which means step 2's
`configuration.yaml` is wrong or arrived after the first start. Check it with
`sudo grep -A4 trusted_proxies /srv/home-assistant/config/configuration.yaml`, fix it, and run
`docker compose restart`. A `502` that never clears is the container not listening yet, so run
`docker compose logs --tail 40 homeassistant` and read it: a first boot is a long list of
packages being installed, which is the container working rather than failing. A `401` from the
last command is the good outcome, not an error: that endpoint requires a token, and refusing
without one is the point. A running container is not success.

The first screen at https://<DOMAIN> shows the heading `Welcome!` and a button reading
`Create my smart home`. Until you submit that form, anyone who loads the page can.

Go and do it now, before you read the rest of this file: open https://<DOMAIN>, create the
owner account, and put the password in your password manager. Then come back and prove it
closed:

```bash
curl -sS https://<DOMAIN>/api/onboarding
echo
```

You should see: the same line, now containing `"step":"user","done":true`.

If you do not: `"done":false` means the form was never submitted, so the window is still open.
Also open https://<DOMAIN> in a private window and confirm you get a sign-in form and no
`Create my smart home` button.

## 8. First backup and restore

Take the backup now, before you add a single device. Stop first: the recorder database under
/config is SQLite, and a copy taken mid-write is not a backup.

```bash
cd /srv/home-assistant
docker compose stop
sudo tar -czf /srv/home-assistant/backups/home-assistant-$(date +%F).tar.gz -C /srv/home-assistant config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/home-assistant/backups/
```

You should see: one file, a few megabytes on a fresh install. Downtime is about ten seconds.

If you do not: an archive of a few hundred bytes means `tar` found nothing, which usually means
the paths after `-C` do not exist. `config` is the whole install: `configuration.yaml`, the
`.storage` directory that holds the owner account and every integration's credentials, and
`home-assistant_v2.db` with the history.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/home-assistant
scp vps:/srv/home-assistant/backups/*.tar.gz ~/backups/home-assistant/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/home-assistant/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/home-assistant
docker compose down
sudo rm -rf /srv/home-assistant/config
sudo tar -C /srv/home-assistant -xzf /srv/home-assistant/backups/home-assistant-$(date +%F).tar.gz
docker compose up -d
sleep 90
curl -sS https://<DOMAIN>/api/onboarding
echo
```

You should see: `"step":"user","done":true` again, and your own account still working when you
sign in.

If you do not: `"done":false` means the archive was taken before you created the account, so
take another one now and repeat. Understand the stakes before you skip this. The `.storage`
directory holds the token for every integration you will ever link, and losing it means linking
all of them again by hand, one login at a time.

## 9. Updating later

New versions are listed at https://github.com/home-assistant/core/releases. Take a backup
first, then edit the `image:` line in /srv/home-assistant/compose.yml to the new tag and its
digest.

```bash
cd /srv/home-assistant
docker compose pull
docker compose up -d
docker compose logs --tail 30 homeassistant
```

You should see: storage migration lines, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands, then re-run
step 7's check. One thing to know before you take a release from the 2026.8 series or later.
Those releases move the HTTP settings out of `configuration.yaml` and into the interface, under
Settings then System then Network. The `http:` block from step 2 is imported once on the first
start after the upgrade and then has to be confirmed there, and the confirmation window is
short. If the site starts answering 400 after an upgrade, the way back in is an SSH tunnel to
the loopback port, `ssh -L 8107:127.0.0.1:8107 vps`, run on your own machine, and then
http://localhost:8107 in a browser to set the trusted proxies again.

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
  machine sitting on your home network; on a public server they bind 8123 to every interface
  and grant hardware access to nothing.
- Do not configure the Alexa or Google Assistant integrations. Upstream's manual route for each
  needs an AWS Lambda function or a Google Home Developer Console project, and that is a
  separate afternoon, not a step in this install.
- Do not install HACS or any add-on. Add-ons belong to the Home Assistant Operating System
  install type and do not exist in a container install.
- Do not configure SMTP or any notify platform. Home Assistant runs without mail, and the
  channels you want are accounts and tokens you pick in the interface.
