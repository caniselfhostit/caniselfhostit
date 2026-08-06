This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Grafana OSS 13.1.2 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1, because it is what most people wish they had known. Grafana draws
pictures of data it does not hold. It ships with no metrics and no logs of its own, so the far
side of this install is a working, empty dashboard tool. Something has to be producing numbers
already, on this box or another one, before a panel has anything on it. Grafana Cloud bundles
those backends with the dashboard; this install is the dashboard.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line. Upstream documents 512 MB of memory and one CPU core as the
minimum.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for this
hostname while you install, or the certificate is issued to somebody else's edge.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/grafana /srv/grafana/backups
sudo install -d -m 750 -o 472 -g 0 /srv/grafana/data
ls -la /srv/grafana
```

You should see: `backups` owned by you, and `data` owned by `472` in group `root`.

If you do not: leave `data` owned by 472 on purpose. The image runs as that uid and Grafana does
not chown its own data directory: it checks whether the path is writable, prints a warning, and
then fails to build its database. If you already ran this with the wrong owner, fix it with
`sudo chown -R 472:0 /srv/grafana/data`.

## 3. Secrets

Two values, both generated here on the server, both straight into a file only you can read. Hex
rather than base64 because both travel through an env file Docker Compose also reads.

The first is the administrator password. Grafana creates its admin account on the very first
start, using whatever `GF_SECURITY_ADMIN_PASSWORD` says at that moment, and upstream's shipped
value for that setting is the literal word `admin`. Writing this file before the container has
ever run is what stops a known credential from existing. The second is
`GF_SECURITY_SECRET_KEY`, which encrypts the data-source passwords and alerting credentials
Grafana stores in its database; upstream ships a fixed string for it in `conf/defaults.ini` that
anyone can read. Set it now, because upstream documents that changing it later forces every
stored data-source secret to be re-entered by hand.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first two lines with your real hostname before you paste. Then read the password once with
`grep GF_SECURITY_ADMIN_PASSWORD /srv/grafana/.env` and put it in your password manager: it is
the only account this install has.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines in separate shells. Run `chmod 600 /srv/grafana/.env` and carry on. If the
file already existed from an earlier attempt, this block has overwritten both values, which is
harmless before the container has ever started and a problem afterwards: the admin password is
set once, at account creation, so a rewritten file does not change a password that already
exists, and a rewritten secret key makes every stored data-source password undecryptable.

Do not paste that file, either value, or any command output containing them into this chat
window. The agent path never sees them; a chat window hands them to a third party.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/grafana/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal;
run `rm /srv/grafana/compose.yml` and paste again in one go. Grafana listens on 3000 inside the
container and 8106 is bound to 127.0.0.1 on the host, so Caddy is the only route in.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-grafana /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you replaced in one place and not the
other. Caddy asks for the certificate on the first request and renews it with no cron job.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8106`.

If you do not: delete anything for 8106 with `sudo ufw delete allow 8106`. That port is bound to
127.0.0.1 by the compose file, so a firewall rule would cover traffic that cannot arrive.
80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem:
Prompt Zero left this firewall enabled, so something turned it off since, and `sudo ufw enable`
puts it back before you go any further.

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

You should see, in order: the loop reaching `200`; a small JSON object containing
`"database": "ok"` and `"version": "13.1.2"`; then `401`; then `1`.

If you do not: the `401` is the one worth understanding. It means the API is up and refusing the
credential Grafana would have created for itself if step 3 had not run first, so seeing it is
good news, and a `200` there is the one result you must not ignore. If you get it, run
`docker compose down`, then `sudo rm -rf /srv/grafana/data`, then step 2 and this step again,
because a known password on a public hostname is the failure this whole sequence exists to
prevent. If the loop never reaches `200`, run `docker compose logs --tail 40 grafana`: a line
reading `GF_PATHS_DATA='/var/lib/grafana' is not writable` is step 2 done wrong, and a `502`
from Caddy against a container that looks healthy is step 5.

The first screen at https://<DOMAIN> is a sign-in form under the heading `Welcome to Grafana`.
Open it now, sign in with the username `admin` and the password from step 3, and confirm you
land on a page offering to add a data source. A running container is not success; that screen
is.

## 8. First backup and restore

One archive. It holds the SQLite database, the two generated values, the compose file and the
live Caddy site block, which together are the whole install. Stop first, because a SQLite file
copied while Grafana is writing to it is not a backup.

```bash
cd /srv/grafana
docker compose stop
sudo tar -czf /srv/grafana/backups/grafana-$(date +%F).tar.gz -C /srv/grafana compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/grafana/backups/
```

You should see: one file, a few hundred kilobytes on a fresh install. Downtime is a few seconds.

If you do not: an archive of about 100 bytes means `tar` matched nothing, which happens when you
run it from a different directory than the one the `-C` flags name. Run the command exactly as
written.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/grafana
scp vps:/srv/grafana/backups/*.tar.gz ~/backups/grafana/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/grafana/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/grafana
docker compose down
sudo rm -rf /srv/grafana/data
sudo tar -C /srv/grafana -xzf /srv/grafana/backups/grafana-$(date +%F).tar.gz data
sudo chown -R 472:0 /srv/grafana/data
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/health
```

You should see: the same JSON with `"database": "ok"`, and your password still signs you in.

If you do not: `no such file or directory` from `tar` means the archive name has a different
date; check `ls /srv/grafana/backups/`. An empty reply from `curl` usually means Grafana is still
opening the restored database, so wait another twenty seconds and run the last line again.
Understand the stakes before you skip this. `.env` holds
the key your data-source passwords are encrypted with, so an archive without it is a store of
secrets nobody can open again, including you. The archive also carries the Caddy site block as
`/srv/grafana/Caddyfile`; that one goes back into /etc/caddy by hand, and only if the host
config was lost too.

## 9. Updating later

New versions are listed at https://github.com/grafana/grafana/releases. Take a backup first,
then edit the `image:` line in /srv/grafana/compose.yml to the new tag and its digest.

```bash
cd /srv/grafana
docker compose pull
docker compose up -d
docker compose logs --tail 30 grafana
```

You should see: migration lines, then the HTTP server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
health check from step 7 before you call the update done, and open one dashboard as well. Read
the release notes for any major version step: upstream removes panel types between majors, and a
dashboard that stops rendering afterwards is usually that rather than a broken install.

## 10. What will probably go wrong

Nothing will be wrong, and it will look wrong. I finished this install, signed in, and got a
sidebar, an empty dashboard list and a prompt to add a data source, and spent ten minutes
checking logs for a fault that was not there. Grafana holds no data of its own: it queries
Prometheus, a SQL database, a log store, something. Until one of those exists and is pointed at,
an empty screen is the correct output of a correct install. If you expected charts on arrival,
the next thing to install is whatever is going to produce the numbers.

## 11. Out of scope

- Do not install Prometheus, Loki, InfluxDB or any other data source. Each is its own service
  with its own storage and retention decisions, and this install gives you the one that draws
  the pictures.
- Do not configure SMTP. Grafana runs without it; alert notifications can go to a webhook you
  choose later, and outbound mail from a fresh VPS is a separate fight.
- Do not enable anonymous access and do not configure an OAuth or LDAP provider. One
  administrator account with a generated password is the whole authentication model here.
- Do not switch the database to PostgreSQL or MySQL. SQLite is what makes this one container,
  and it is what step 8 is written for.
