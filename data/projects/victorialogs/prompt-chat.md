This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing VictoriaLogs 1.52.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read these three before step 1, because together they decide whether you want this. VictoriaLogs
has no accounts, no sign-in form and no roles, so a public hostname with nothing in front of it
hands every log line this box keeps to whoever loads the URL; step 3 and step 5 put a password in
Caddy and step 7 asserts it. Step 7 also does not finish until real container output is shipping
in, because an empty log database is not a log store and the shipping half is configuration on
containers this install does not touch. And this is logs only: no metrics, no traces, no
application performance monitoring, no alert rules.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
caddy version
```

You should see: at least `1024` MB available, at least `20` GB free on /srv, `amd64` or `arm64`
(the image also publishes arm/v7 and ppc64le), your server's IP address, and a Caddy version of
2.8 or newer.

If you do not: under-floor RAM or disk means stop rather than install and hope, and the disk floor
is high for one container because a log store is the thing that fills a disk. This install caps its
own data directory at 5 GiB, upstream asks for spare space around it, and the backup archives in
step 8 land on the same disk until you move them off, which is where the other 15 GB goes. An
empty `dig` answer means the A record has not been created or has not propagated; wait a few
minutes and run it again. A Caddy older than 2.8 does not know the `basic_auth` spelling this
install uses, so upgrade Caddy before going on rather than rewriting the site block.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/victorialogs /srv/victorialogs/backups /srv/victorialogs/data
ls -la /srv/victorialogs
```

You should see: `data` and `backups`, both owned by your login user. `data` becomes `/vlogs`
inside the container and holds every ingested line in per-day partition directories.

If you do not: a permission error means you are not in the sudo group, which Prompt Zero set up.
There is no config directory to create, because VictoriaLogs has no configuration file.

## 3. Secrets

One secret: the password Caddy checks before any request reaches VictoriaLogs.

```bash
umask 077
openssl rand -hex 24 > /srv/victorialogs/dashboard-password
chmod 600 /srv/victorialogs/dashboard-password
umask 022
ls -la /srv/victorialogs/dashboard-password
```

You should see: `-rw-------` on that file. Read it with
`sudo cat /srv/victorialogs/dashboard-password`. The login name for the browser box is `vlogs`.
Put both in your password manager now.

If you do not: a mode other than 600 means the `umask` line did not run, so re-run `chmod 600`
before going on.

Do not paste the contents of that file, or any command output containing it, back into this chat
window. Nothing on this path needs the value except your browser and step 7's own `curl`, and a
password pasted into a chat window belongs to whoever runs that chat window.

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

You should see: `compose OK`. One service, one published port, one bind mount.

If you do not: `docker compose config` prints the line it objected to. A YAML error is almost
always an indentation change made while pasting, so paste the block again in one piece rather than
editing it line by line. If a later `docker compose pull` complains that the manifest digest does
not match, the tag and the digest in that image line have drifted apart, which means the line was
edited by hand; put both back exactly as written above rather than dropping the `@sha256:` part.

## 5. Caddy and TLS

First the credential Caddy checks, a bcrypt hash of the password from step 3. It is read from the
file rather than typed as an argument, so it never reaches the process list:

```bash
umask 077
caddy hash-password < /srv/victorialogs/dashboard-password > /srv/victorialogs/auth.hash
printf 'basic_auth {\n\tvlogs %s\n}\n' "$(cat /srv/victorialogs/auth.hash)" > /srv/victorialogs/auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/victorialogs/auth.conf /etc/caddy/victorialogs-auth.conf
rm -f /srv/victorialogs/auth.hash /srv/victorialogs/auth.conf
sudo grep -c basic_auth /etc/caddy/victorialogs-auth.conf
```

You should see: `1`.

If you do not: a `0` means `caddy hash-password` wrote nothing, and the site block below would
then publish an open log store to the internet. Stop here and re-run this block before going on.

Now the site block. Replace `<DOMAIN>` with your hostname before you paste, and note that the
first command keeps a copy of the working Caddyfile, because a syntax error here takes down every
other site on the box:

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

You should see: `Valid configuration` from validate, and no output at all from the reload.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-victorialogs /etc/caddy/Caddyfile`, reload, and read what
validate objected to. The usual cause is a `<DOMAIN>` left literal in the pasted block.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for 80/tcp, 443/tcp and 443/udp, and no rule mentioning
8190 or 9428.

If you do not: an inactive firewall means Prompt Zero did not finish; run `sudo ufw enable`. If
8190 appears, remove it with `sudo ufw delete allow 8190`, because Caddy reaches that port over
loopback and nothing else should. One thing to hold on to: every process on this box can reach
127.0.0.1:8190 with no password. That is what lets the log driver in step 7 write, and it is the
boundary of a single-tenant machine. If you ever share this box with someone whose access you
would not extend to your logs, that assumption stops holding and the loopback port becomes the
thing to close, not the hostname.

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

You should see, in order: the loop ending on `200`, which is `/health` answering `OK`; `200` from
the ingest call; `1` from the query, which is a line that went in over the JSON stream API coming
back out through LogsQL; `401` from the unauthenticated public call, which is the security check
in this step; and `200` from the authenticated one.

If you do not: a `502` with the container running means Caddy cannot reach 8190, so re-read
step 5. A `200` where you expected `401` means the `import` line did not load and your log store
is public to the internet, so fix that before anything else. A `0` from the query after a `200`
ingest means the insert was accepted but the `_stream_fields` name in the URL does not match the
JSON. For anything else, run `docker compose logs --tail 40 victorialogs`. A running container is
not success.

The browser tab is titled `UI for VictoriaLogs`. The query box is at the top, results underneath,
and the query language is LogsQL rather than SQL: `*` returns everything, a bare word matches the
message text, and `{service="install-check"}` filters on a stream field.

STOP: open https://<DOMAIN>/select/vmui/ in a private window, sign in as `vlogs` with the password from /srv/victorialogs/dashboard-password, and confirm the query `*` returns the `caniselfhostit install check` line. Do not continue until that line is on the screen.

Now ship real logs in. Docker's built-in `splunk` log driver writes to the Splunk HTTP Event
Collector paths VictoriaLogs answers, so nothing more has to be installed. List what is running
with `docker ps --format '{{.Names}}'`. If nothing but `victorialogs` comes back, keep the block
below for when you have a second service and go to step 8. Otherwise pick one of those services,
add this to it in its own compose file keeping the keys already there, and recreate that one
service with `docker compose up -d --force-recreate <service>`:

```yaml
    logging:
      driver: splunk
      options:
        splunk-url: "http://127.0.0.1:8190"
        splunk-token: "PLACEHOLDER"
        splunk-verify-connection: "false"
        tag: "{{.Name}}"
```

The token is required by the driver and ignored by VictoriaLogs, which reads no token on that
path. The connection check is off on purpose: the driver probes the destination with an HTTP
OPTIONS request at container start and expects `200`, VictoriaLogs answers every OPTIONS request
with `204`, and a container whose probe fails does not start at all. Never put this block on the
`victorialogs` service itself. Then prove the loop:

```bash
before=$(curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query=_time:10m' | wc -l)
sleep 20
after=$(curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query=_time:10m' | wc -l)
echo "before=$before after=$after"
curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query=_time:2m' | head -2
```

You should see: `after` larger than `before`, and one or two JSON lines carrying that service's
own output.

If you do not: equal numbers mean the driver is not delivering. Check the URL with
`docker inspect --format '{{.HostConfig.LogConfig}}' <container>`, and confirm the service really
was recreated rather than only restarted, because a logging change lands on recreate.

## 8. First backup and restore

One archive: the log partitions, the compose file, the Caddy password, the live Caddyfile and the
auth conf. The container stops for it, because a storage directory copied while partitions are
being merged is not a backup.

```bash
cd /srv/victorialogs
docker compose stop
sudo tar -czf /srv/victorialogs/backups/victorialogs-$(date +%F).tar.gz -C /srv/victorialogs data compose.yml dashboard-password -C /etc/caddy Caddyfile victorialogs-auth.conf
docker compose start
ls -lh /srv/victorialogs/backups/
```

You should see: one `.tar.gz` with a non-zero size. Downtime is a few seconds.

If you do not: a `Cannot open: No such file` for `victorialogs-auth.conf` means step 5 did not
finish, so go back. A zero-byte archive means `data` was empty, which is possible only if step 7
never ingested anything.

The only credential in that archive is `dashboard-password`, so treat the file as secret material.
A backup on the same disk is not a backup, so run this on your own machine, not the server:

```bash
mkdir -p ~/backups/victorialogs
scp vps:/srv/victorialogs/backups/*.tar.gz ~/backups/victorialogs/
```

To restore cold on a box that has been through Prompt Zero: `docker compose down`, recreate the
directories exactly as in step 2, untar the archive into /srv/victorialogs, move `Caddyfile` and
`victorialogs-auth.conf` back under /etc/caddy, `sudo systemctl reload caddy`, then
`docker compose up -d`, and re-run step 7's `401` and `200` checks before believing any of it.
`data/` is every log line you kept and `dashboard-password` is how you get back in, so a restore
missing the second is a lockout even when the first is intact.

## 9. Updating later

New versions are at https://github.com/VictoriaMetrics/VictoriaLogs/releases, with the changelog
at https://docs.victoriametrics.com/victorialogs/changelog/. Stay on the plain tag: `-enterprise`
and `-enterprise-fips` in the same Docker Hub repository are a separate commercial build under its
own licence rather than the Apache-2.0 one, and they expect a licence key. Take a backup, then
edit the image line in /srv/victorialogs/compose.yml to the new tag and its digest:

```bash
cd /srv/victorialogs
docker compose pull
docker compose up -d
docker compose logs --tail 30 victorialogs
```

You should see: the new version in the start-up log, then `started VictoriaLogs`.

If you do not: a container that exits immediately after an update almost always names a
command-line flag it no longer accepts, in the last line of that log. Roll back by putting the
previous tag and digest into compose.yml and running the same three commands. Re-run step 7's
health, ingest and query checks before calling the update done. Two numbers in `command:` are
worth revisiting at the same time: `-retentionPeriod=30d` decides how far back a query can reach,
and `-retention.maxDiskSpaceUsageBytes=5GiB` drops the oldest days when the disk fills first.
Raise either, then watch `du -sh /srv/victorialogs/data` for a week before trusting the figure.

## 10. What will probably go wrong

The install will look finished and the product will be empty. I had a green health check, a signed
certificate, a working login box, and a query screen answering every question with zero results,
and I spent twenty minutes assuming my query language was wrong. Nothing was wrong. Nothing was
shipping. A log store is the one service where a correct install and a useless one look identical
from outside, because the useful half is configuration on containers you are not installing today.
The other failure: a container refuses to start after you attach the log driver, saying it failed
to initialize the logging driver. That is the connection probe this page turns off. Leave it on,
or aim the driver where VictoriaLogs is not listening, and the container never runs.

## 11. Out of scope

- Do not add Grafana, Vector, vmauth, vmalert or Alertmanager. Upstream's demo runs all five;
  this install is the log store alone.
- Do not set `-httpAuth.username` or `-httpAuth.password` on the container. Caddy is the door; a
  second half-covering one only looks like protection.
- Do not open 8190 in the firewall or rebind it to 0.0.0.0.
- Do not configure alerting rules. They need vmalert plus a notifier, a second install.
