You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install VictoriaLogs 1.52.0 under ~/selfhost/victorialogs, answering at http://localhost:8190.

## 1. Preflight

Say this before step 2 runs, because it decides whether the user wants this install at all. A log
store holds only what is shipped to it, and this one answers at http://localhost:8190, which means
this computer and nothing else. It collects what containers on this machine say. It cannot reach a
VPS, and while the machine sleeps it collects nothing.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. VictoriaLogs needs 1024 MB of RAM available
and 20 GB free on the home disk, and the image publishes amd64, arm64, arm/v7 and ppc64le. If
available RAM is under 1024 MB or free disk is under 20 GB, print both and stop. The floor is high
for one container because a log store fills disk: this one caps data at 5 GiB.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they
  confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/victorialogs/data ~/selfhost/victorialogs/backups
ls -la ~/selfhost/victorialogs
```

Assert: `data` and `backups` exist. `data` becomes `/vlogs` inside the container and holds every
ingested line in per-day partitions. There is no config directory: the flags in step 5 are the
whole configuration. No ownership fix is needed: the image declares no user, so the
process runs as root and writes world-readable partition directories, which lets step 8 archive
them without sudo.

## 4. Secrets

No secret is generated on this path and there is no `.env` file. The VPS path generates one
password because it puts a public hostname in front of a service with no login of its own; here
there is no hostname and no Caddy, so loopback is the whole door. Say plainly that anything on this
computer can read and write this log store with no credential, and the protection is that nothing
else reaches 8190.

## 5. compose.yml

```bash
cat > ~/selfhost/victorialogs/compose.yml <<'EOF'
# VictoriaLogs · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker image ... https://docs.victoriametrics.com/victorialogs/quickstart/
#   flags .......... https://docs.victoriametrics.com/victorialogs/
#   log driver ..... https://docs.victoriametrics.com/victorialogs/data-ingestion/splunk/
#
# One service on the computer you are sitting at. The data path is relative to
# ~/selfhost/victorialogs/, so one file works on macOS, Linux and Windows, and
# stays a bind mount so the partition directories are visible in Finder or
# Explorer. The `command:` list is the whole configuration: no config file, no
# .env. No healthcheck, because the image is distroless. Plain v1.52.0 is the
# open source build; step 9 covers the -enterprise tags. Digest read from
# Docker Hub on 2026-08-14; amd64, arm64, arm/v7 and ppc64le.
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
      # partitions drop. A laptop disk fills sooner than a server one.
      - "-retention.maxDiskSpaceUsageBytes=5GiB"
    volumes:
      # Every ingested line lands here, in per-day partition directories.
      - ./data:/vlogs
    ports:
      # Loopback only: no other device on the wifi reaches 8190.
      - "127.0.0.1:8190:9428"
EOF
cd ~/selfhost/victorialogs && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one port, one bind mount.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname to
resolve, a certificate attests a public name and nothing here has one, and nothing is published
beyond loopback. Browsers treat http://localhost as a secure context, so the query page works
without TLS.

8190 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. For a log store that is a fair trade, because what it collects
lives here too. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/victorialogs/compose.yml
```

Assert: that prints `1`. A `0` means the port line was edited and the store may be listening on
every interface with no password in front of it; stop and fix the compose file.

## 7. Start and verify

VictoriaLogs creates its storage on first start. No migration step, no wizard, no first account.

```bash
cd ~/selfhost/victorialogs
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8190/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
printf '{"_msg":"caniselfhostit install check","service":"install-check"}\n' | curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/stream+json' --data-binary @- 'http://localhost:8190/insert/jsonline?_stream_fields=service'
sleep 3
curl -sS http://localhost:8190/select/logsql/query -d 'query={service="install-check"}' | grep -c 'caniselfhostit install check'
curl -sSL http://localhost:8190/select/vmui/ | grep -c 'UI for VictoriaLogs'
```

Assert all four and print what you received. The loop ends on `200`, `/health` answering `OK`. The
ingest call prints `200`. The query prints `1`: a line went in over the JSON stream API and came
back out through LogsQL, which is the whole product. The last prints more than `0`, because
`UI for VictoriaLogs` is the title the query page carries. If any of the four misses, stop, run
`docker compose logs --tail 40 victorialogs`, and name the cause. If `port is already allocated`
came back, find what holds 8190 (`lsof -nP -iTCP:8190 -sTCP:LISTEN`, `ss -ltnp | grep 8190` on
Linux, `netstat -ano | findstr :8190` on Windows) and stop until it is freed. A running container
is not success.

STOP: tell the user to open http://localhost:8190/select/vmui/, run the query `*`, and confirm they see the `caniselfhostit install check` line. Do not continue until they confirm.

Now ship real logs in. Docker's built-in `splunk` log driver writes to the Splunk HTTP Event
Collector paths VictoriaLogs answers, so nothing more installs. Run
`docker ps --format '{{.Names}}'`. If nothing but `victorialogs` is listed, print the block below,
say where it goes later, and go to step 8. Otherwise:

STOP: ask the user which service should ship its output, and wait. Do not continue until they confirm.

Add that block to the service they name, in its own compose file, then
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
connection check is off because the driver probes with an OPTIONS request at start-up expecting
`200`, VictoriaLogs answers OPTIONS with `204`, and a container whose probe fails never starts. Do
not put this block on `victorialogs` itself. Then prove the loop:

```bash
before=$(curl -sS http://localhost:8190/select/logsql/query -d 'query=_time:10m' | wc -l)
sleep 20
after=$(curl -sS http://localhost:8190/select/logsql/query -d 'query=_time:10m' | wc -l)
echo "before=$before after=$after"
curl -sS http://localhost:8190/select/logsql/query -d 'query=_time:2m' | head -2
```

Assert: `after` is greater than `before`, and the last command prints a line of that service's own
output. If the two are equal the driver is not delivering: check the URL with
`docker inspect --format '{{.HostConfig.LogConfig}}' <container>`.

## 8. First backup and restore

One archive: the log partitions and the compose file. The container stops for it, because a
storage directory copied mid-merge is not a backup. Downtime is a few seconds.

```bash
cd ~/selfhost/victorialogs
docker compose stop
tar -C ~/selfhost/victorialogs -czf ~/selfhost/victorialogs/backups/victorialogs-$(date +%F).tar.gz data compose.yml
docker compose start
ls -lh ~/selfhost/victorialogs/backups/
```

Assert: the archive exists and is non-empty. Print its size. There is no password file and no
`.env` here, so it holds logs and configuration, which is whatever those logs say.

That archive sits on the same disk as the data, which is not a backup, and on a laptop the disk and
the machine fail together. Ask the user for a destination that leaves this computer, a sync folder
or a USB stick, and copy it there with `cp`. In Git Bash a Windows drive is written `/d/Backups`,
not `D:\Backups`. Assert: the user confirms the filename is there. If they have nowhere, say that
this install has no backup.

To restore: `cd ~/selfhost/victorialogs`, `docker compose down`, `rm -rf data`, untar the archive
there, `docker compose up -d`, then re-run step 7's health and query asserts. On Linux the partition
files are owned by root, so that `rm -rf` needs `sudo`. The archive is the only copy of what the
containers that produced it have already rotated away.

## 9. Updating later

New versions are at https://github.com/VictoriaMetrics/VictoriaLogs/releases, changelog at
https://docs.victoriametrics.com/victorialogs/changelog/. Stay on the plain tag: `-enterprise` and
`-enterprise-fips` in the same Docker Hub repository are a separate commercial build under its own
licence rather than the Apache-2.0 one, and expect a licence key. Take a backup, then edit the
image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/victorialogs
docker compose pull
docker compose up -d
docker compose logs --tail 30 victorialogs
```

Re-run step 7's checks first. Two numbers in `command:` are worth revisiting then:
`-retentionPeriod=30d` decides how far back a query reaches, and
`-retention.maxDiskSpaceUsageBytes=5GiB` drops the oldest days when the disk fills. Raise either,
then watch `du -sh ~/selfhost/victorialogs/data`.

## 10. What will probably go wrong

I closed the lid on a Friday and came back on Monday to a log store with nothing from the weekend.
Nothing was broken. The machine was asleep, the containers were not running, there was nothing to
collect, and the gap reads as a quiet weekend rather than an outage. The second thing is worse and
happens at the same moment: a container with the splunk log driver attached refuses to start if
VictoriaLogs is not up first, saying it failed to initialize the logging driver. Turn on Docker
Desktop's start-at-login, and after a reboot run `cd ~/selfhost/victorialogs && docker compose up -d`
before anything that ships to it.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8190 to 0.0.0.0 so another machine can ship logs here. That publishes a readable
  and writable log store, with no password, on every network this laptop joins.
- Do not add Grafana, Vector, vmauth, vmalert or Alertmanager, and do not configure alerting
  rules: those need vmalert and a notifier, a second install.
