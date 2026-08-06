You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Grafana OSS 13.1.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. The hostname also becomes Grafana's `root_url`,
which the share links and the redirect after sign-in are built from, so a placeholder left in
place produces links that go nowhere.

Say one thing to the user before anything installs, because it decides whether they want this
at all: Grafana draws pictures of data it does not hold. It ships with no metrics and no logs
of its own, so this install ends at a working, empty dashboard tool. Something has to be
producing numbers already, or be installed separately after, before a panel has anything on it.

Upstream documents a minimum of 512 MB of memory and one CPU core. This install wants 512 MB
available and 5 GB free on /srv. The image publishes amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a hostname that does not resolve.

## 2. Layout

The image runs as uid 472 in group 0, so the data directory belongs to 472 and not to the login
user. Grafana does not chown that directory itself: it checks whether it can write there, prints
a warning, and carries on into a database it cannot create.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/grafana /srv/grafana/backups
sudo install -d -m 750 -o 472 -g 0 /srv/grafana/data
ls -la /srv/grafana
```

Assert: `ls -la` shows `backups` owned by the login user and `data` owned by `472`. Nothing is
written outside /srv/grafana. `data` holds `grafana.db`, which is a SQLite file, so keep it on
this machine's own disk rather than any network mount.

## 3. Secrets

Two values are generated here, on the server. Do not print either, do not repeat them in your
summary, and do not put them in any log line. Hex rather than base64, because both travel
through an env file that Docker Compose also reads.

The first is the administrator password. Grafana creates its admin account on the very first
start, using whatever `GF_SECURITY_ADMIN_PASSWORD` says at that moment. Upstream's shipped value
for that setting is the literal word `admin`, so writing this file before the container has ever
run is what stops a known credential from existing.

The second is `GF_SECURITY_SECRET_KEY`. Grafana encrypts data-source passwords and alerting
credentials in its database with a key derived from it, and upstream ships a fixed string in
`conf/defaults.ini` that anyone can read. Set it now: upstream documents that changing it later
forces every stored data-source secret to be re-entered by hand.

```bash
umask 077
cat > /srv/grafana/.env <<EOF
GF_SERVER_ROOT_URL=https://<DOMAIN>
GF_SERVER_DOMAIN=<DOMAIN>
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -hex 24)
GF_SECURITY_SECRET_KEY=$(openssl rand -hex 32)
EOF
chmod 600 /srv/grafana/.env
umask 022
ls -l /srv/grafana/.env
```

Assert: the file exists with mode `-rw-------` and `<DOMAIN>` on the first two lines has been
replaced by the real hostname. Tell the user the password is in /srv/grafana/.env, that they
read it themselves with `grep GF_SECURITY_ADMIN_PASSWORD /srv/grafana/.env`, and that it should
go into their password manager before step 7.

## 4. compose.yml

```bash
cat > /srv/grafana/compose.yml <<'EOF'
# Grafana OSS · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/
#   docker config ...... https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/
#   settings reference . https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
#   health endpoint .... https://github.com/grafana/grafana/blob/v13.1.2/docs/sources/developer-resources/api-reference/http-api/api-legacy/other.md
#
# One container. Grafana keeps dashboards, users and data-source settings in an
# embedded SQLite database under /var/lib/grafana, so nothing else runs here.
# The image is grafana/grafana, not grafana/grafana-oss: upstream's docker page
# says the grafana-oss repository stopped being updated at the 12.4.0 release
# and that grafana/grafana is now the OSS image. Tag and digest were read from
# Docker Hub on 2026-08-06; the manifest list covers linux/amd64, linux/arm64
# and linux/arm/v7. The image runs as uid 472 in group 0, which is why step 2
# hands the data directory to that uid before the first start.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  grafana:
    image: grafana/grafana:13.1.2@sha256:d177053ab62253815f130d81504f77063baf5fd4ca93299d6048453bd31e047a
    container_name: grafana
    restart: unless-stopped
    # The hostname and the two generated values live here, mode 600.
    env_file: /srv/grafana/.env
    environment:
      # Caddy terminates TLS in front of this, so the session cookie can carry
      # the secure flag. Upstream ships it off because it cannot know.
      GF_SECURITY_COOKIE_SECURE: "true"
      # Already the upstream default. Written out because it is the setting
      # that decides whether a stranger who finds the hostname can enrol.
      GF_USERS_ALLOW_SIGN_UP: "false"
      # Upstream ships all three on: usage counters to stats.grafana.org every
      # 24 hours, plus version checks against grafana.com. Off here.
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
    volumes:
      # grafana.db, the plugin directory and rendered exports all land here.
      - /srv/grafana/data:/var/lib/grafana
    healthcheck:
      # curl is in the alpine image upstream builds. /api/health answers 200
      # while the database responds and 503 when it does not.
      test: ["CMD-SHELL", "curl -fsS http://localhost:3000/api/health || exit 1"]
      interval: 15s
      retries: 10
      start_period: 30s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8106.
      - "127.0.0.1:8106:3000"
EOF
cd /srv/grafana && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Grafana serves on 3000 inside the container and 8106 is bound
to 127.0.0.1 on the host, so Caddy is the only route in.

## 5. Caddy and TLS

Append the block below with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-grafana
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Grafana OSS · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also GF_SERVER_ROOT_URL and GF_SERVER_DOMAIN in .env, because Grafana builds
# share links and redirect targets out of root_url rather than out of the Host
# header. The two have to say the same thing.

<DOMAIN> {
	encode zstd gzip

	# No X-Frame-Options here on purpose. Grafana's own allow_embedding
	# setting is false by default, so it already sends a deny, and setting
	# SAMEORIGIN from the proxy would replace a stricter header with a
	# looser one. HSTS is Caddy's because Grafana ships that off.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}

	# Grafana Live pushes dashboard and alert updates over a WebSocket at
	# /api/live/ws. Caddy negotiates the upgrade on its own, so there are no
	# Upgrade or Connection headers to set by hand.
	#
	# 8106 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8106
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-grafana, reload, and report what it objected to. Caddy asks for the
certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. These are idempotent, so on a box Prompt Zero configured they
change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8106 stays closed: compose binds it to 127.0.0.1, so a rule would cover traffic that
cannot arrive, and one that is there was left by a previous run, which
`sudo ufw delete allow 8106` fixes. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule for 8106.

## 7. Start and verify

Grafana builds its SQLite schema and creates the admin account on the first start, so give it a
moment before treating anything as broken.

```bash
cd /srv/grafana
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/health
echo
curl -sS -o /dev/null -w '%{http_code}\n' -u admin:admin https://<DOMAIN>/api/org
curl -sSL https://<DOMAIN>/login | grep -c '<title>Grafana</title>'
```

Assert, all four, and print what you received for each. The loop ends printing `200`. The health
response contains `"database": "ok"` and `"version": "13.1.2"`. The call using upstream's
shipped default credential prints `401`, which is the security assert in this block: it proves
the account Grafana would have created with a known password does not exist. The last command
prints `1`, the served login page.

If any of the four misses, stop, run `docker compose logs --tail 40 grafana`, and name the
likely earlier step. A log line reading `GF_PATHS_DATA='/var/lib/grafana' is not writable` is
step 2 done wrong, and the fix is `sudo chown -R 472:0 /srv/grafana/data`. A `502` from Caddy
with a healthy container is step 5. A `200` from the `-u admin:admin` call means the container
started before step 3 wrote the file, and the repair is `docker compose down`, then
`sudo rm -rf /srv/grafana/data`, then step 2 and step 7 again. A running container is not
success.

The first screen at https://<DOMAIN> is a sign-in form under the heading `Welcome to Grafana`.

STOP: tell the user to read their password with
`grep GF_SECURITY_ADMIN_PASSWORD /srv/grafana/.env`, put it in their password manager, then
open https://<DOMAIN>, sign in with the username `admin` and that password, and confirm they
reach a page offering to add a data source. Wait. Do not continue until they confirm in words.

## 8. First backup and restore

One archive: the SQLite database, the two generated values, the compose file and the live Caddy
site block, which together are the whole install. Stop first, because a SQLite file copied while
Grafana is writing to it is not a backup.

```bash
cd /srv/grafana
docker compose stop
sudo tar -czf /srv/grafana/backups/grafana-$(date +%F).tar.gz -C /srv/grafana compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/grafana/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is a few seconds. A backup
on the same disk as the data is not a backup, so run this from the user's machine, not the
server:

```bash
mkdir -p ~/backups/grafana
scp vps:/srv/grafana/backups/*.tar.gz ~/backups/grafana/
```

To restore: `docker compose down`, `sudo rm -rf /srv/grafana/data`, then
`sudo tar -C /srv/grafana -xzf` the archive, then `sudo chown -R 472:0 /srv/grafana/data`, then
`docker compose up -d`. The archive also carries the Caddy site block as
`/srv/grafana/Caddyfile`; that one goes back into /etc/caddy by hand, and only if the host
config was lost too. Tell the user what is at stake: `.env` holds the key their data-source
passwords are encrypted with, so an archive without it is a store of secrets nobody can open
again.

## 9. Updating later

New versions are listed at https://github.com/grafana/grafana/releases. Take a backup first,
then edit the image line in /srv/grafana/compose.yml to the new tag and its digest:

```bash
cd /srv/grafana
docker compose pull
docker compose up -d
docker compose logs --tail 30 grafana
```

Grafana migrates its own database on the way up, so watch that log until it settles, then re-run
the health check from step 7 before calling the update done. Read the release notes for any
major version step: upstream removes panel types between majors, and a dashboard that stops
rendering afterwards is usually that.

## 10. What will probably go wrong

Nothing will be wrong, and it will look wrong. I finished this install, signed in, and got a
sidebar, an empty dashboard list and a prompt to add a data source, and spent ten minutes
checking logs for a fault that was not there. Grafana holds no data of its own: it queries
Prometheus, a SQL database, a log store, something. Until one of those exists and is pointed at,
an empty screen is the correct output of a correct install. If the user expected charts on
arrival, tell them now, before they start debugging: the next thing to install is whatever is
going to produce the numbers.

## 11. Out of scope

- Do not install Prometheus, Loki, InfluxDB or any other data source. Each is its own service
  with its own storage and retention decisions, and this prompt installs the one that draws the
  pictures.
- Do not configure SMTP. Grafana runs without it; alert notifications can go to a webhook the
  user chooses later, and outbound mail from a fresh VPS is a separate fight.
- Do not enable anonymous access and do not configure an OAuth or LDAP provider. One
  administrator account with a generated password is the whole authentication model here.
- Do not switch the database to PostgreSQL or MySQL. SQLite is what makes this one container,
  and it is what step 8 is written for.
