You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Gatus 5.36.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say two things to the user first. One: a monitor cannot tell them the machine it runs on is down.
If they have a second server this belongs on the other one, and either way they should keep one
free external check pointed at this hostname from a service they do not run, because that check
survives the outage this install cannot report. Two: this produces a public status page. There is
no login and no account, and every endpoint name and URL written in step 2 is published to anyone
who loads it.

Gatus needs 512 MB of RAM available and 5 GB free on /srv. The image publishes amd64, arm64 and
arm/v7. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
hostname that does not resolve, and step 2 writes that hostname into a check that queries it.

## 2. Layout and configuration

The configuration file is the product. It carries the monitors, their pass conditions and the
alerting, it is the only thing the user edits after today, and Gatus refuses to start without it,
so it is written before the container ever runs. Replace `<DOMAIN>` with the real hostname below.

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/gatus /srv/gatus/backups /srv/gatus/config
sudo install -d -m 750 /srv/gatus/data
cat > /srv/gatus/config/config.yaml <<'EOF'
# Gatus · the configuration is the product. Authored by caniselfhostit from
# https://github.com/TwiN/gatus/blob/v5.36.0/README.md#configuration
#
# Every name and every URL below is printed on a page anyone can open.

storage:
  type: sqlite
  path: /data/data.db

endpoints:
  - name: gatus
    group: internal
    url: "http://127.0.0.1:8080/health"
    interval: 60s
    conditions:
      - "[STATUS] == 200"
      - "[BODY].status == UP"

  - name: status-page
    group: public
    url: "https://<DOMAIN>/health"
    interval: 60s
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 1000"
      - "[CERTIFICATE_EXPIRATION] > 240h"

  - name: dns
    group: public
    url: "1.1.1.1"
    interval: 5m
    dns:
      query-name: "<DOMAIN>"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"

# Alerting is off. Every provider wants a webhook URL or a key from a service
# you sign up for. To turn Slack on: uncomment, paste your own webhook URL, and
# add an `alerts:` list with `- type: slack` under an endpoint.
#alerting:
#  slack:
#    webhook-url: "PASTE_YOUR_OWN_SLACK_WEBHOOK_URL_HERE"
EOF
chmod 600 /srv/gatus/config/config.yaml
ls -la /srv/gatus /srv/gatus/config
```

Assert: `ls -la` shows `config.yaml` at mode `-rw-------`, `data` owned by root, and `backups`
owned by the login user. The file holds no secret today and is mode 600 because the alerting
stanza is where one would land later; the container reads it as root whatever the mode says.
`data` is root-owned because the image declares no user, so the process inside runs as root and
creates `data.db` itself.

## 3. Secrets

No secret is generated for this install and there is no `.env` file. That is not an oversight,
and there is no default credential for step 7 to close: Gatus ships no account, no registration
form and no administration screen. Exactly one route writes anything, the push endpoint for
externally reported checks, and it answers `401` to any call arriving without a bearer token the
user declared in the configuration first. This install declares none, so that route has nothing
to accept. Step 7 asserts it.

What replaces the credential question here is publication. The dashboard and its JSON API answer
everybody, because that is what a status page is for, and step 2's file decides what everybody
sees: the name of every endpoint, its URL, and whether it is passing right now. An internal
hostname in that file is an internal hostname on a public page.

Tell the user this: if they would rather the page were behind a password, upstream's
`security.basic` and `security.oidc` do that, this install uses neither, and turning one on is a
decision about who the page is for.

## 4. compose.yml

```bash
cat > /srv/gatus/compose.yml <<'EOF'
# Gatus · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker deployment .. https://github.com/TwiN/gatus/blob/v5.36.0/README.md#docker
#   configuration ...... https://github.com/TwiN/gatus/blob/v5.36.0/README.md#configuration
#   storage ............ https://github.com/TwiN/gatus/blob/v5.36.0/README.md#storage
#   image build ........ https://github.com/TwiN/gatus/blob/v5.36.0/Dockerfile
#
# One service, no database container: storage is SQLite in the /data mount,
# because upstream's default is memory and upstream says memory does not survive
# a restart. The config directory is mounted rather than the single file, since
# Gatus polls the loaded path for changes and upstream reports that binding the
# file hides them. No healthcheck and no `user:` line: the image is built FROM
# scratch and carries the binary and the CA bundle, so there is no shell to run
# a check with and no user database to name a user from. No .env: this install
# generates no secret. Digest read from ghcr.io on 2026-08-06; the manifest list
# covers amd64, arm64 and arm/v7.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  gatus:
    image: ghcr.io/twin/gatus:v5.36.0@sha256:c5f210d095fa78e6efaa20ffeb14803f2ba4f10615e16a6d12087697149617f0
    container_name: gatus
    restart: unless-stopped
    environment:
      # DEBUG here while a check fails for a reason the dashboard will not say.
      GATUS_LOG_LEVEL: INFO
    volumes:
      # config.yaml is the product. Read only: Gatus never writes here.
      - /srv/gatus/config:/config:ro
      # data.db, the SQLite file holding every result and every uptime figure.
      - /srv/gatus/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8132.
      - "127.0.0.1:8132:8080"
EOF
cd /srv/gatus && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no database container:
results, uptime figures and event history are rows in `data/data.db`.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-gatus
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Gatus · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/TwiN/gatus/blob/v5.36.0/README.md#deployment and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Everything served here
# is public on purpose: a status page nobody can open is a log file.

<DOMAIN> {
	# Gatus compresses its own responses when the browser asks, so this mostly
	# covers what the container hands over uncompressed.
	encode zstd gzip

	# About how the page is framed and referred to, not about protecting a
	# session. There is no session here: no accounts, no login, no cookie.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8132 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8132
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-gatus, reload, and report what it objected to. Caddy requests the
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

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8132 stays closed because compose binds it to 127.0.0.1. The checks need nothing
opened: they are outbound, and default-deny governs what arrives. Assert:
`ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule
mentioning 8132 or 8080.

## 7. Start and verify

Gatus runs every endpoint once at start-up rather than waiting out the first interval, so results
exist seconds after the container comes up.

```bash
cd /srv/gatus
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/health; echo
curl -sSL https://<DOMAIN>/ | grep -c 'Health Dashboard'
curl -sS https://<DOMAIN>/api/v1/endpoints/statuses | grep -o '"key":"[^"]*"'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST 'https://<DOMAIN>/api/v1/endpoints/public_status-page/external?success=true'
```

Assert all five, and print what you received for each. The loop ends printing `200`. The health
endpoint answers `{"status":"UP"}`. The grep prints a number greater than `0`, because
`Health Dashboard` is the heading the page renders. The statuses call prints three lines, one
`"key"` per endpoint: `internal_gatus`, `public_status-page` and `public_dns`. The last command prints `401`: that push route is
the only thing here that writes, and it refuses a call carrying no bearer token, which is the
security assert in this block. If any of the five misses, stop, run
`docker compose logs --tail 40 gatus`, and name the likely earlier step: a container that exits
on its own is step 2, because a configuration Gatus cannot parse makes it refuse to start rather
than ignore the file, and a 502 from Caddy with a running container is step 5. A running
container is not success.

The `status-page` row may be red on the first pass: it checks this host through its own
certificate, which Caddy may still have been issuing when Gatus first asked. Green within a
minute or two; red past five means this box cannot reach its own public URL, which a few
provider networks refuse.

STOP: tell the user to open https://<DOMAIN> in a private window, read the page as a stranger
would, and confirm two things back to you: that they see three rows under the headings `internal`
and `public`, and that they are content for those names and URLs to be public, because they now
are. Do not continue until they confirm.

## 8. First backup and restore

One archive: the configuration, the results database, the compose file and the live Caddy site
block. Take it now, before there is a month of history to lose.

```bash
cd /srv/gatus
docker compose stop
sudo tar -czf /srv/gatus/backups/gatus-$(date +%F).tar.gz -C /srv/gatus config data compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/gatus/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds, and
the container is stopped on purpose, because a SQLite file copied mid-write is not a backup.

A backup on the same disk as the data is not a backup. Run this one from the user's machine, not
the server:

```bash
mkdir -p ~/backups/gatus
scp vps:/srv/gatus/backups/*.tar.gz ~/backups/gatus/
```

To restore: `docker compose down`, `sudo rm -rf /srv/gatus/data /srv/gatus/config`, recreate the
directories as in step 2, untar the archive back into /srv/gatus, put the Caddy block back if
that is what was lost, then `docker compose up -d`. Tell the user which half matters:
`config/config.yaml` is every monitor they ever wrote, and `data/data.db` is only the history
behind those monitors. Losing the second costs the uptime figures. Losing the first costs the
product.

## 9. Updating later

New versions are listed at https://github.com/TwiN/gatus/releases. The release tag and the image
tag are the same string, so release `v5.37.0` is image tag `v5.37.0`. Take a backup first, then
edit the image line in /srv/gatus/compose.yml to the new tag and its digest:

```bash
cd /srv/gatus
docker compose pull
docker compose up -d
docker compose logs --tail 30 gatus
```

Gatus migrates the SQLite schema on the way up. Watch that log until it settles, then re-run
step 7's checks before calling the update done.

## 10. What will probably go wrong

You will open config.yaml to add your first real monitor, save it, and half a minute later the
container will be gone. I did that with a mis-indented `conditions:` list. Gatus polls its own
configuration while it runs, and upstream's default when the new file does not parse is to exit
rather than keep serving the old one, so `restart: unless-stopped` starts it again, it reads the
same broken file, and it exits again. The dashboard goes down with it, a poor look for a status
page. Run `docker compose logs --tail 20 gatus`, read the parse error at the top, fix that line
in /srv/gatus/config/config.yaml, and the next restart picks it up. Do not set
`skip-invalid-config-update` to true to stop the symptom: upstream recommends against it, because
the broken file then survives quietly until the next real restart, which stops the container
anyway.

## 11. Out of scope

- Do not configure an alerting provider. Each one needs a webhook URL or a key from a service
  the user signs up for, and the commented block in config.yaml is where theirs goes.
- Do not turn on `security.basic` or `security.oidc`. Whether this page is public is the user's
  editorial decision, and the OIDC path needs an identity provider registered somewhere else.
- Do not switch `storage.type` to postgres. SQLite is the choice here, and it is the reason this
  is one container and one file to copy.
- Do not set `metrics: true` and do not add Prometheus or Grafana beside it. This installs one
  service.
