You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Netdata 2.10.4 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say three things first. One: the agent is GPL-3.0-or-later; the dashboard UI is closed-source
under NCUL1 and free to use with the agent. Two: without a password in front, a public hostname
is an unauthenticated map of this box. Three: this install adds SYS_PTRACE, SYS_ADMIN and
apparmor:unconfined so collectors can see the host; that widens blast radius on purpose.

Netdata needs 1024 MB of RAM available and 5 GB free on /srv. The image publishes amd64 and
arm64. Measure all four, and confirm Caddy is 2.8 or newer (basic_auth spelling):

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
caddy version
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. If
`dig +short` prints nothing, print that and stop. If Caddy is older than 2.8, stop and upgrade:
this install uses the `basic_auth` directive name from 2.8.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/netdata /srv/netdata/backups /srv/netdata/config /srv/netdata/lib /srv/netdata/cache
ls -la /srv/netdata
```

Assert: config, lib, cache and backups exist and are owned by the login user. Those three data
directories are what the container writes; there is no empty `data/` mount.

## 3. Secrets

One secret: the password Caddy will check before any request reaches Netdata. The agent itself
has no setup wizard and no sign-in form on this path. Generate the password on the server. Do
not print it.

```bash
umask 077
openssl rand -hex 24 > /srv/netdata/dashboard-password
chmod 600 /srv/netdata/dashboard-password
umask 022
ls -la /srv/netdata/dashboard-password
```

Assert: the file is mode 600. Tell the user they can read it with
`sudo cat /srv/netdata/dashboard-password` and that the username for the login box is `netdata`.
Put both in their password manager. Step 5 turns the password into a bcrypt hash Caddy stores
under /etc/caddy.

## 4. compose.yml

```bash
cat > /srv/netdata/compose.yml <<'EOF'
# Netdata · the single-container install. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker .............. https://learn.netdata.cloud/docs/installing/docker
#   reverse proxy ....... https://learn.netdata.cloud/docs/netdata-agent/configuration/securing-agents/running-the-agent-behind-a-reverse-proxy/caddy
#   license table ....... https://github.com/netdata/netdata/blob/v2.10.4/README.md
#
# One container. Capabilities follow upstream docker docs for host metrics
# visibility: SYS_PTRACE and SYS_ADMIN, plus apparmor:unconfined. The dashboard
# has no built-in password on this path; Caddy basic_auth is the door. State
# lives in config, lib and cache mounts. Tag and digest are v2.10.4 from Docker
# Hub on 2026-08-07; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  netdata:
    image: netdata/netdata:v2.10.4@sha256:689145f603fed0ca341b4d8a0fb9910cd9d8c0590b0530cd24ae1912a9c7f8f3
    container_name: netdata
    restart: unless-stopped
    hostname: netdata
    pid: host
    cap_add:
      # Process inspection for per-process charts.
      - SYS_PTRACE
      # Host-level collectors that need admin-capable syscalls.
      - SYS_ADMIN
    security_opt:
      # Upstream docker packaging uses unconfined AppArmor so collectors can
      # read host paths the default profile blocks. This widens the container
      # confinement boundary; do not treat it as free.
      - apparmor:unconfined
    volumes:
      - /srv/netdata/config:/etc/netdata
      - /srv/netdata/lib:/var/lib/netdata
      - /srv/netdata/cache:/var/cache/netdata
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8207.
      - "127.0.0.1:8207:19999"
EOF
cd /srv/netdata && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service. `SYS_PTRACE` is for process charts; `SYS_ADMIN`
is for host-level collectors; `apparmor:unconfined` is the AppArmor profile choice upstream
documents for docker collectors that otherwise cannot read host paths. Do not add
`privileged: true` on top. Do not add a Caddy service to this file.

## 5. Caddy and TLS

First the credential Caddy checks, a bcrypt hash of the password from step 3:

```bash
umask 077
caddy hash-password < /srv/netdata/dashboard-password > /srv/netdata/auth.hash
printf 'basic_auth {\n\tnetdata %s\n}\n' "$(cat /srv/netdata/auth.hash)" > /srv/netdata/auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/netdata/auth.conf /etc/caddy/netdata-auth.conf
rm -f /srv/netdata/auth.hash /srv/netdata/auth.conf
sudo grep -c basic_auth /etc/caddy/netdata-auth.conf
```

Assert: that prints `1`. Reading the password from a file keeps it out of the process list.

Then the site block, with `<DOMAIN>` replaced by the real hostname. Copy the live Caddyfile
first:

```bash
cat > /srv/netdata/Caddyfile <<'EOF'
# Netdata · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://learn.netdata.cloud/docs/netdata-agent/configuration/securing-agents/running-the-agent-behind-a-reverse-proxy/caddy
# https://caddyserver.com/docs/automatic-https and
# https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. The Netdata dashboard
# has no login of its own on this install. Caddy basic_auth is the only door.
# Needs Caddy 2.8 or newer (basic_auth spelling).

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# Credential lives in /etc/caddy/netdata-auth.conf (not published here).
	import /etc/caddy/netdata-auth.conf

	# 8207 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8207
}
EOF
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-netdata
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sed "s|<DOMAIN>|${REAL_DOMAIN}|g" /srv/netdata/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `REAL_DOMAIN` to the hostname from step 1 before sed. Assert: validate and reload exit 0.
If validate fails, restore `/etc/caddy/Caddyfile.before-netdata`, reload, and report the error.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp is ACME and HTTPS redirect, 443/tcp is the only way in, 443/udp is HTTP/3. 8207 stays
closed. Assert: `Status: active`, rules for 80 and 443, no rule for 8207 or 19999.

## 7. Start and verify

There is no Netdata setup wizard and no account creation inside the agent on this path. Success
is charts behind Caddy with unauthenticated requests refused.

```bash
cd /srv/netdata
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8207/api/v1/info); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS http://127.0.0.1:8207/api/v1/info | head -c 200; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/info
curl -sS -o /dev/null -w '%{http_code}\n' -u "netdata:$(cat /srv/netdata/dashboard-password)" https://<DOMAIN>/api/v1/info
```

Assert all four, and print the codes. The loop ends on `200`. The loopback info JSON names the
agent. The unauthenticated public call prints `401`: that is the security assert in this block.
The authenticated call prints `200`. If any miss, stop, run `docker compose logs --tail 40
netdata`, and name the step: a 502 with a running container is Caddy; a missing 401 means
basic_auth did not load. A running container is not success.

STOP: tell the user to open https://<DOMAIN> in a private window, sign in with username
`netdata` and the password from `/srv/netdata/dashboard-password`, and confirm they see the
dashboard charts for this host. Do not continue until they confirm. There is no second setup
screen inside Netdata for this install.

## 8. First backup and restore

One archive: config, lib, cache, the dashboard password, compose, the live Caddyfile and the
auth conf.

```bash
cd /srv/netdata
docker compose stop
sudo tar -czf /srv/netdata/backups/netdata-$(date +%F).tar.gz -C /srv/netdata config lib cache compose.yml dashboard-password -C /etc/caddy Caddyfile netdata-auth.conf
docker compose start
ls -lh /srv/netdata/backups/
```

Assert: the archive exists and is non-empty. Print its size. Treat it as secret material. Copy
it off the box from the user's machine:

```bash
mkdir -p ~/backups/netdata
scp vps:/srv/netdata/backups/*.tar.gz ~/backups/netdata/
```

To restore: `docker compose down`, remove config lib and cache, recreate them as in step 2,
untar into /srv/netdata, put `Caddyfile` and `netdata-auth.conf` back under /etc/caddy, reload
Caddy, then `docker compose up -d`. Re-run step 7's 401 and 200 asserts. Metrics history lives
under lib and cache; config holds agent settings; the password file is how you sign in again.

## 9. Updating later

New versions are at https://github.com/netdata/netdata/releases. Take a backup first, then edit
the image line in /srv/netdata/compose.yml to the new tag and digest:

```bash
cd /srv/netdata
docker compose pull
docker compose up -d
docker compose logs --tail 30 netdata
```

Re-run step 7's checks before calling the update done.

## 10. What will probably go wrong

You will open the hostname without basic_auth during a failed Caddy edit and see every chart
of the box from a phone on a train. I did that once after a validate failure when I restored the
wrong backup of the Caddyfile. The agent still had no password of its own. Keep the import line
for `netdata-auth.conf`, re-assert the 401 after every Caddy change, and treat a public metrics
map as a security incident, not a convenience.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy already runs under systemd on this
  box.
- Do not publish 19999 or 8207 on the public interface. Caddy is the only way in.
- Do not set `privileged: true` in addition to the listed capabilities.
- Do not require a Netdata Cloud claim for this install. Cloud is optional and separate.
