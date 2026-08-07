This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Gatus 5.36.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read these two before step 1, because together they decide whether you want this at all. A
monitor cannot tell you that the machine it runs on is down, so this belongs on a box other than
the ones it watches, and you should keep one free external check pointed at this hostname from a
service you do not run. And what you are building is a public status page: no login, no account,
and the name and URL of every endpoint in the configuration file are published to whoever loads
the page.

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
resolve, failed attempts count against a rate limit you cannot see, and step 2 writes that same
hostname into a check that queries it, so an unresolvable name gives you a red row as well as no
certificate. An architecture line reading `armhf` is also fine: the image publishes amd64, arm64
and arm/v7.

## 2. Layout and configuration

The configuration file is the product. It carries the monitors, their pass conditions and the
alerting, it is the only thing you edit after today, and Gatus will not start without it, so it
gets written before the container has ever run. Replace `<DOMAIN>` on the two lines that carry it
before you paste, and paste the whole block at once.

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

You should see: `config`, `data` and `backups` under /srv/gatus, `data` owned by `root`, and
`config.yaml` at mode `-rw-------`.

If you do not: leave `data` owned by root on purpose. The image declares no user, so the process
inside the container runs as root and creates `data.db` there itself. If `ls` shows no
`config.yaml`, the heredoc did not close: the last three lines of the paste are `EOF`, the
`chmod`, and the `ls`, and a shell still showing a `>` prompt is waiting for that `EOF`. Press
Ctrl-C and paste the block again in one go.

## 3. Secrets

There are none, and that is the whole block. Gatus ships no account, no registration form and no
administration screen, so this install generates nothing, writes no `.env`, and leaves no default
credential for step 7 to close. Exactly one route writes anything, the push endpoint for
externally reported checks, and it refuses any call arriving without a bearer token that the
configuration file would have had to declare first. Yours declares none. Step 7 proves it.

```bash
ls -l /srv/gatus/config/config.yaml
sudo grep -c . /srv/gatus/config/config.yaml
```

You should see: mode `-rw-------`, your own username twice, and a line count around `40`.

If you do not: a mode of `-rw-r--r--` means the `chmod` line in step 2 did not run. Run
`chmod 600 /srv/gatus/config/config.yaml` and carry on.

Do not paste that file, or any command output containing it, into this chat window. Nothing in it
is a secret today. The moment you uncomment the alerting block and put a real Slack webhook URL
there, it is one, and a webhook URL is a working credential to anyone who reads it.

The other half of this block is not about credentials at all. The dashboard and its JSON API
answer everybody, because that is what a status page is for, and the file you wrote in step 2
decides what everybody sees: the name of every endpoint, its URL, and whether it is passing right
now. An internal hostname in that file is an internal hostname on a public page. If you would
rather the page were behind a password, upstream's `security.basic` and `security.oidc` settings
do that; this install uses neither, and turning one on is a decision about who the page is for.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/gatus/compose.yml` and paste again in one go. There is no database
service in this file and that is correct: the results, the uptime figures and the event history
are rows in `data/data.db`, which is why step 2 made that directory.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-gatus /etc/caddy/Caddyfile`, reload, and
paste again. The commonest cause is a `<DOMAIN>` you replaced in the site line but left in the
comment above it, which is harmless, or one you left in the site line, which is not. Caddy
requests the certificate on the first request to the hostname and renews it on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8132` or `8080`.

If you do not: delete anything for `8132` with `sudo ufw delete allow 8132`. It is bound to
127.0.0.1 by the compose file, so a rule for it would cover traffic that cannot arrive. Your
checks need nothing opened either: they are outbound requests from the container, and ufw governs
what arrives. `Status: inactive` is a different problem, because Prompt Zero left this firewall
on, so something has turned it off since; `sudo ufw enable` puts it back.

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

You should see, in order: the loop reaching `200`, then `{"status":"UP"}`, then a number greater
than `0` because `Health Dashboard` is the heading the page renders, then three lines reading
`"key":"internal_gatus"`, `"key":"public_status-page"` and `"key":"public_dns"` in some order,
then `401`.

If you do not: that `401` is the one worth understanding, so read it as good news. It means the
only route in this application that writes anything refused a call carrying no bearer token, and
because your configuration declares no external endpoint there is no token that would work. A
`404` from the first three instead means Caddy is reaching something other than Gatus: check
`docker compose ps`. If the container is not running at all, run
`docker compose logs --tail 40 gatus` and look for a parse error, because a configuration Gatus
cannot read makes it refuse to start rather than ignore the file, and that points at step 2.

Now open https://<DOMAIN> in a private window and read it the way a stranger would. You should
see three rows under the headings `internal` and `public`. The `status-page` row may be red on
this first pass, which is correct rather than broken: it checks this host through its own
certificate, and Caddy may still have been issuing that certificate when Gatus first asked.
Green within a minute or two. Red past five minutes means the server cannot reach its own
public URL, which a few providers' networks refuse; run `curl -sS https://<DOMAIN>/health` on
the server itself to see which side is failing. A running container is not success; that page
is.

Before you go further, look at what is on it. The names and the URLs you wrote in step 2 are now
public. If either of them is something you would rather strangers did not know about, edit
/srv/gatus/config/config.yaml now, because Gatus rereads it within about thirty seconds.

## 8. First backup and restore

One archive: the configuration, the results database, the compose file and the live Caddy site
block.

```bash
cd /srv/gatus
docker compose stop
sudo tar -czf /srv/gatus/backups/gatus-$(date +%F).tar.gz -C /srv/gatus config data compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/gatus/backups/
```

You should see: one file, a few kilobytes on a fresh install. Downtime is about five seconds, and
the container is stopped on purpose, because a SQLite file copied mid-write is not a backup.

If you do not: an archive of about 100 bytes means `tar` found none of the paths, which happens
if you ran it from somewhere other than /srv/gatus with a typo in a `-C` argument. Run
`tar -tzf` on it and read what it actually contains.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/gatus
scp vps:/srv/gatus/backups/*.tar.gz ~/backups/gatus/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/gatus/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an hour of history:

```bash
cd /srv/gatus
docker compose down
sudo rm -rf /srv/gatus/data /srv/gatus/config
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/gatus/config
sudo install -d -m 750 /srv/gatus/data
sudo tar -C /srv/gatus -xzf /srv/gatus/backups/gatus-$(date +%F).tar.gz config data compose.yml
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/v1/endpoints/statuses | grep -o '"key":"[^"]*"'
```

You should see: the same three keys as in step 7, from a config directory and a database that
were both deleted a minute ago.

If you do not: `tar: config: Not found in archive` means you passed a date that does not match
the filename, so run `ls /srv/gatus/backups/` and use the real one. Know which half matters:
`config/config.yaml` is every monitor you ever wrote, and `data/data.db` is only the history
behind them. Losing the second costs your uptime figures. Losing the first costs the product.

## 9. Updating later

New versions are listed at https://github.com/TwiN/gatus/releases. The release tag and the image
tag are the same string, so release `v5.37.0` is image tag `v5.37.0`. Take a backup first, then
edit the `image:` line in /srv/gatus/compose.yml to the new tag and its digest.

```bash
cd /srv/gatus
docker compose pull
docker compose up -d
docker compose logs --tail 30 gatus
```

You should see: the server starting, no repeating restart, and no line about an invalid
configuration.

If you do not: put the old tag and digest back and run the same three commands. Gatus migrates
the SQLite schema on the way up, so watch that log until it settles, then re-run the `/health`
and statuses checks from step 7 before you call the update done.

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

- Do not configure an alerting provider yet. Each one needs a webhook URL or a key from a service
  you sign up for, and the commented block in config.yaml is where yours goes.
- Do not turn on `security.basic` or `security.oidc`. Whether this page is public is your
  editorial decision, and the OIDC path needs an identity provider registered somewhere else.
- Do not switch `storage.type` to postgres. SQLite is the choice here, and it is the reason this
  is one container and one file to copy.
- Do not set `metrics: true` and do not add Prometheus or Grafana beside it. This install is one
  service.
