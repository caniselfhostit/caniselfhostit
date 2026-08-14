You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install VictoriaLogs 1.52.0 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server.

Say three things first. VictoriaLogs has no accounts and no sign-in form, so a public hostname
with nothing in front hands every log line this box keeps to whoever loads the URL. Step 7 does not
finish until real container output has been shipped in. And this is logs only: no metrics, no
traces, no performance monitoring, no alert rules.

VictoriaLogs needs 1024 MB of RAM available and 20 GB free on /srv. The image publishes amd64,
arm64, arm/v7 and ppc64le. Measure all four, and confirm Caddy is 2.8 or newer:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
caddy version
```

If available RAM is under 1024 MB or free disk is under 20 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop. If Caddy predates 2.8, stop:
this install uses the `basic_auth` spelling that arrived there. The disk floor is high for one
container because a log store fills disk: this one caps data at 5 GiB, backups land beside it.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/victorialogs /srv/victorialogs/backups /srv/victorialogs/data
ls -la /srv/victorialogs
```

Assert: `data` and `backups` exist and are owned by the login user. `data` is the only thing the
container writes: it becomes `/vlogs` inside, and every ingested line lands there in a per-day
partition directory. No config directory, because there is no config file.

## 3. Secrets

One secret: the password Caddy checks before any request reaches VictoriaLogs. Generate it on the
server. Do not print it, repeat it in your summary, or put it in a log line.

```bash
umask 077
openssl rand -hex 24 > /srv/victorialogs/dashboard-password
chmod 600 /srv/victorialogs/dashboard-password
umask 022
ls -la /srv/victorialogs/dashboard-password
```

Assert: the file is mode `-rw-------`. Tell the user the browser login name is `vlogs`, that they
read the password with `sudo cat /srv/victorialogs/dashboard-password`, and that both belong in
their password manager now. Step 5 hashes it for Caddy; the plaintext stays because the restore
needs it. VictoriaLogs ships no admin account and no API token, so there is no second one.

## 4. compose.yml

```bash
cat > /srv/victorialogs/compose.yml <<'EOF'
# VictoriaLogs · the deterministic fallback. Authored by caniselfhostit from
# the upstream documentation, not copied from a repository:
#   docker image ... https://docs.victoriametrics.com/victorialogs/quickstart/
#   flags .......... https://docs.victoriametrics.com/victorialogs/
#   log driver ..... https://docs.victoriametrics.com/victorialogs/data-ingestion/splunk/
#
# One service, configured entirely by the `command:` list: there is no
# configuration file and no .env. Upstream's own demo under deployment/docker
# runs seven services; this keeps the one that stores and answers queries. No
# healthcheck: the image is distroless, so every assert runs from the host, and
# no login screen, so Caddy basic_auth is the door. Plain v1.52.0 is the open
# source build; step 9 covers the -enterprise tags. Digest read from Docker Hub
# on 2026-08-14; amd64, arm64, arm/v7 and ppc64le.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  victorialogs:
    image: victoriametrics/victoria-logs:v1.52.0@sha256:47b820890d64c4575a2a0a46415dcd8a4fd59a0f1fcd6a377693d7aea639442e
    container_name: victorialogs
    restart: unless-stopped
    command:
      # Absolute, so the mount below is the only place logs can land.
      - "-storageDataPath=/vlogs"
      # Upstream's default retention is 7 days. Thirty is the choice here.
      - "-retentionPeriod=30d"
      # The ceiling that protects the disk: past this the oldest per-day
      # partitions drop, whatever the retention period says.
      - "-retention.maxDiskSpaceUsageBytes=5GiB"
    volumes:
      # Every ingested line lands here, in per-day partition directories.
      - /srv/victorialogs/data:/vlogs
    ports:
      # Loopback only: Caddy from outside, the Docker log driver from inside.
      - "127.0.0.1:8190:9428"
EOF
cd /srv/victorialogs && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, one bind mount.

## 5. Caddy and TLS

The credential Caddy checks is a bcrypt hash of step 3's password, read from the file rather than
from an argument, so it never reaches the process list:

```bash
umask 077
caddy hash-password < /srv/victorialogs/dashboard-password > /srv/victorialogs/auth.hash
printf 'basic_auth {\n\tvlogs %s\n}\n' "$(cat /srv/victorialogs/auth.hash)" > /srv/victorialogs/auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/victorialogs/auth.conf /etc/caddy/victorialogs-auth.conf
rm -f /srv/victorialogs/auth.hash /srv/victorialogs/auth.conf
sudo grep -c basic_auth /etc/caddy/victorialogs-auth.conf
```

Assert: that prints `1`. A `0` means `caddy hash-password` wrote nothing and the site block below
would publish an open log store, so stop there.

Then the site block, with `<DOMAIN>` replaced by the hostname from step 1. Copy the Caddyfile
first: a syntax error takes down every other site on this box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-victorialogs
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# VictoriaLogs · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.victoriametrics.com/victorialogs/security-and-lb/
# https://caddyserver.com/docs/automatic-https and
# https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. VictoriaLogs has no accounts and no sign-in form, and
# its one optional Basic Auth flag pair still leaves /health, /ping and
# /robots.txt open, so the door belongs here, where it covers every path.
# Needs Caddy 2.8 or newer.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# Credential lives in /etc/caddy/victorialogs-auth.conf (not published here).
	import /etc/caddy/victorialogs-auth.conf

	# 8190 is the loopback port compose publishes. It is not a container port
	# and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8190
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: validate and reload both exit 0. If validate fails, restore
/etc/caddy/Caddyfile.before-victorialogs, reload, and report what it objected to.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8190 stays closed: it is bound to 127.0.0.1 and Caddy reaches it over loopback. Assert:
`Status: active`, rules for 80, 443/tcp and 443/udp, no rule for 8190 or 9428. Say plainly that any
process on this box reaches 127.0.0.1:8190 with no password. That is what lets step 7's log driver
write, and it is the edge of a single-tenant box.

## 7. Start and verify

VictoriaLogs creates its storage on first start. No migration step, no wizard, no first account.

```bash
cd /srv/victorialogs
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8190/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
printf '{"_msg":"caniselfhostit install check","service":"install-check"}\n' | curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/stream+json' --data-binary @- 'http://127.0.0.1:8190/insert/jsonline?_stream_fields=service'
sleep 3
curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query={service="install-check"}' | grep -c 'caniselfhostit install check'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/select/vmui/
curl -sS -o /dev/null -w '%{http_code}\n' -u "vlogs:$(sudo cat /srv/victorialogs/dashboard-password)" https://<DOMAIN>/select/vmui/
```

Assert all five and print what you received. The loop ends on `200`, `/health` answering `OK`. The
ingest call prints `200`. The query prints `1`: a line went in over the JSON stream API and came
back out through LogsQL, which is the whole product. The unauthenticated public call prints `401`,
the security assert in this block; the authenticated one prints `200`. If any of the five misses,
stop, run `docker compose logs --tail 40 victorialogs`, and name the cause. A `502` with a running
container is Caddy. A `200` where `401` was expected means step 5's import line did not load and the
store is public. A `0` after a `200` ingest means the stream field does not match the JSON. A
running container is not success.

STOP: tell the user to open https://<DOMAIN>/select/vmui/ in a private window, sign in as `vlogs` with the password from /srv/victorialogs/dashboard-password, and confirm the query `*` returns the `caniselfhostit install check` line. Do not continue until they confirm.

Now ship real logs in. Docker's built-in `splunk` log driver writes to the Splunk HTTP Event
Collector paths VictoriaLogs answers, so nothing more is installed. Run
`docker ps --format '{{.Names}}'`. If nothing but `victorialogs` is listed, print the block below,
say where it goes later, and go to step 8. Otherwise:

STOP: ask the user which service should ship its output, and wait. Do not continue until they confirm.

Add that block to the service they name, in its own compose file, keep the keys already there, then
`docker compose up -d --force-recreate <service>`:

```yaml
    logging:
      driver: splunk
      options:
        splunk-url: "http://127.0.0.1:8190"
        splunk-token: "PLACEHOLDER"
        splunk-verify-connection: "false"
        tag: "{{.Name}}"
```

The token is required by the driver and ignored by VictoriaLogs, which reads no token there. The
connection check is off on purpose: the driver probes with an OPTIONS request at start-up and
expects `200`, VictoriaLogs answers every OPTIONS request with `204`, and a container whose probe
fails never starts. Never put this block on `victorialogs` itself. Then prove the loop:

```bash
before=$(curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query=_time:10m' | wc -l)
sleep 20
after=$(curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query=_time:10m' | wc -l)
echo "before=$before after=$after"
curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query=_time:2m' | head -2
```

Assert: `after` is greater than `before`, and the last command prints a line of that service's own
output. If the two are equal the driver is not delivering: run
`docker inspect --format '{{.HostConfig.LogConfig}}' <container>` and check the URL.

## 8. First backup and restore

One archive: the log partitions, the compose file, the Caddy password, the live Caddyfile and the
auth conf. The container stops for it: a storage directory copied mid-merge is not a backup.
Downtime is a few seconds.

```bash
cd /srv/victorialogs
docker compose stop
sudo tar -czf /srv/victorialogs/backups/victorialogs-$(date +%F).tar.gz -C /srv/victorialogs data compose.yml dashboard-password -C /etc/caddy Caddyfile victorialogs-auth.conf
docker compose start
ls -lh /srv/victorialogs/backups/
```

Assert: the archive exists and is non-empty. Print its size. The only credential in it is
`dashboard-password`, so it is secret material. A backup on the same disk is not a backup, so run
this from the user's machine:

```bash
mkdir -p ~/backups/victorialogs
scp vps:/srv/victorialogs/backups/*.tar.gz ~/backups/victorialogs/
```

To restore cold on a box that has been through Prompt Zero: `docker compose down`, recreate the
directories as in step 2, untar into /srv/victorialogs, move `Caddyfile` and
`victorialogs-auth.conf` back under /etc/caddy, `sudo systemctl reload caddy`, then
`docker compose up -d`. Re-run step 7's `401` and `200` asserts. `data/` is every line kept and
`dashboard-password` is how the user gets back in, so missing the second is a lockout.

## 9. Updating later

New versions are at https://github.com/VictoriaMetrics/VictoriaLogs/releases, changelog at
https://docs.victoriametrics.com/victorialogs/changelog/. Stay on the plain tag: `-enterprise` and
`-enterprise-fips` in the same Docker Hub repository are a separate commercial build under its own
licence rather than the Apache-2.0 one, and they expect a licence key. Take a backup, then edit the
image line in compose.yml to the new tag and digest:

```bash
cd /srv/victorialogs
docker compose pull
docker compose up -d
docker compose logs --tail 30 victorialogs
```

Re-run step 7's checks first. Two numbers in `command:` are worth revisiting then:
`-retentionPeriod=30d` decides how far back a query reaches, and
`-retention.maxDiskSpaceUsageBytes=5GiB` drops the oldest days when the disk fills first. Raise
either, then watch `du -sh /srv/victorialogs/data`.

## 10. What will probably go wrong

The install will look finished and the product will be empty. I had a green health check, a signed
certificate, a working login box, and a query screen answering every question with zero results, and
I spent twenty minutes assuming my query language was wrong. Nothing was wrong. Nothing was
shipping. A log store is the one service where a correct install and a useless one look identical
from outside, because the useful half is configuration on containers you are not installing today.
The other failure: a container refuses to start after you attach the log driver, saying it failed to
initialize the logging driver. That is the connection probe this prompt turns off. Leave it on, or
aim the driver where VictoriaLogs is not listening, and the container never runs.

## 11. Out of scope

- Do not add Grafana, Vector, vmauth, vmalert or Alertmanager. Upstream's demo runs all five;
  this install is the log store alone.
- Do not set `-httpAuth.username` or `-httpAuth.password` on the container. Caddy is the door; a
  second half-covering one only looks like protection.
- Do not open 8190 in the firewall or rebind it to 0.0.0.0.
- Do not configure alerting rules. They need vmalert plus a notifier, a second install.
