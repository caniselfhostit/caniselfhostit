This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Backrest 1.14.1 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. Backrest is a web UI and a scheduler over restic, and it backs up the
files on the machine it runs on. On this server that means /srv, the data your other services
keep, and not your laptop. It also needs somewhere to send the snapshots, which is a bucket or a
box that still costs money. What you stop paying is the per-computer software fee.

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
and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name that does
not resolve and failed attempts count against a rate limit you cannot see. If free disk is under
5 GB, stop and add disk: that 5 GB is the image plus restic's cache, which grows with the
repository index rather than with the data you copy.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/backrest /srv/backrest/backups
sudo install -d -m 700 -o $(id -u) -g $(id -g) /srv/backrest/config
sudo install -d -m 700 /srv/backrest/data /srv/backrest/cache /srv/backrest/restore
ls -la /srv/backrest
```

You should see: five directories, `config` and `backups` owned by you, and `data`, `cache` and
`restore` at mode `drwx------` owned by root.

If you do not: leave the three root-owned ones alone. The container runs as root, because the
files it reads under /srv were written by your other services as other users, and it writes its
own state as root to match. `config` is yours because step 3 writes a file into it before the
container exists.

## 3. Secrets

One secret: the password for the web login. It is generated here, on the server, and it goes
into a file only you can read. The second half of this step is the security decision in this
install: a Backrest that starts with no configuration file writes itself a default one with
authentication disabled, and then serves every API route to whoever asks. Writing the file first
means that is never true on a public hostname.

Replace `<DOMAIN>` on the `instance` line with your hostname before you paste this.

```bash
umask 077
cat > /srv/backrest/.env <<EOF
BACKREST_USERNAME=admin
BACKREST_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/backrest/.env
cat > /srv/backrest/config/config.json <<'EOF'
{
  "version": 6,
  "instance": "<DOMAIN>",
  "auth": {"disabled": false, "users": [{"name": "admin", "passwordBcrypt": "PLACEHOLDER"}]}
}
EOF
grep BACKREST_PASSWORD /srv/backrest/.env | cut -d= -f2- | caddy hash-password | base64 | tr -d '\n' > /srv/backrest/config/hash.tmp
awk 'NR==FNR{h=$0;next} {sub(/PLACEHOLDER/,h);print}' /srv/backrest/config/hash.tmp /srv/backrest/config/config.json > /srv/backrest/config/config.tmp
mv /srv/backrest/config/config.tmp /srv/backrest/config/config.json && rm /srv/backrest/config/hash.tmp
chmod 600 /srv/backrest/config/config.json
umask 022
ls -l /srv/backrest/.env /srv/backrest/config/config.json
grep -q PLACEHOLDER /srv/backrest/config/config.json && echo "substitution failed" || echo "hash in place"
```

You should see: two files at mode `-rw-------`, and `hash in place` on the last line.

If you do not: `substitution failed` means the `caddy hash-password` line produced nothing,
usually because Caddy is not on this box, which would also mean Prompt Zero was never run here.
A mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you pasted the
lines separately in different shells; run the two `chmod 600` commands again. Three upstream
facts hold that block together: a password is stored as a bcrypt hash that is then base64
encoded, which is what `caddy hash-password` piped into `base64` produces; `version` is required,
because a configuration file with content and no version number is rejected at start-up, and 6
is this release's migration count; and `instance` names this install inside every snapshot it
writes and cannot be changed from the UI later.

Read your password once with `sudo grep BACKREST_PASSWORD /srv/backrest/.env` and put it in your
password manager. Do not paste that file, that password, or any command output containing it
into this chat window. The chat has no reason to see it, and once it is in a transcript you do
not control it any more.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/backrest/compose.yml <<'EOF'
# Backrest · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   readme and docker ... https://github.com/garethgeorge/backrest/blob/v1.14.1/README.md
#   getting started ..... https://garethgeorge.github.io/backrest/introduction/getting-started
#   entrypoint defaults . https://github.com/garethgeorge/backrest/blob/v1.14.1/cmd/docker-entrypoint/main.go
#
# One service. Backrest is a web UI and a scheduler over restic, and the image
# ships the restic it was built against at /bin/restic, so nothing is fetched
# at start-up. It runs as root because the files it reads under /srv were
# written by other services as other users. /userdata is /srv, read-only, so a
# restore cannot go home; that is what the writable /restore is for.
#
# Tag and digest read from ghcr.io on 2026-08-06; the image publishes amd64,
# arm64, arm/v6, arm/v7 and 386.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  backrest:
    image: ghcr.io/garethgeorge/backrest:v1.14.1@sha256:b852979754281026230cc69fb11428e6d57c9a97784ab4a444ffc7934c53a215
    container_name: backrest
    restart: unless-stopped
    environment:
      BACKREST_PORT: "0.0.0.0:9898"
      BACKREST_CONFIG: /config/config.json
      BACKREST_DATA: /data
      XDG_CACHE_HOME: /cache
      BACKREST_RESTIC_COMMAND: /bin/restic
      TZ: UTC
    volumes:
      # Repository URIs, schedules and the login hash, written in step 3.
      - /srv/backrest/config:/config
      # oplog.sqlite, the JWT signing secret, the per-task logs.
      - /srv/backrest/data:/data
      # restic's cache: rebuildable, and it grows with the repository index.
      - /srv/backrest/cache:/cache
      - /srv/backrest/restore:/restore
      # The data this server holds: everything in this catalogue lives in /srv.
      - /srv:/userdata:ro
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8136.
      - "127.0.0.1:8136:9898"
EOF
cd /srv/backrest && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/backrest/compose.yml` and paste again in one go. `no configuration
file provided` means the file landed somewhere other than /srv/backrest.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-backrest
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Backrest · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://garethgeorge.github.io/backrest/cookbooks/reverse-proxy-examples and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Upstream's own
# example is one reverse_proxy line to 9898; the headers are ours.

<DOMAIN> {
	# Caddy's default encode matcher covers text, JSON, JavaScript and SVG
	# only, so a file downloaded from a snapshot passes through untouched.
	encode zstd gzip

	# Backrest sets no transport or frame headers of its own. HSTS is on
	# because every request here carries the token that reads this server.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8136 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8136
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-backrest /etc/caddy/Caddyfile`, reload,
and paste again. Caddy asks for the certificate on the first request to the hostname and renews
it on its own, so there is nothing to schedule and nothing to renew by hand.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8136` or `9898`.

If you do not: delete anything for `8136` with `sudo ufw delete allow 8136`. That port is bound
to 127.0.0.1 by the compose file, so nothing outside this box can reach it and no rule should
exist for it. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way
in, and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different
problem: Prompt Zero left this firewall enabled, so something has turned it off since, and
`sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

```bash
cd /srv/backrest
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/ | grep -o '<title>Backrest</title>'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://<DOMAIN>/v1.Backrest/GetOperations -H 'Content-Type: application/json' -d '{}'
printf 'user = "admin:%s"\n' "$(sudo grep BACKREST_PASSWORD /srv/backrest/.env | cut -d= -f2-)" | curl -sS -o /dev/null -w '%{http_code}\n' -K - -X POST https://<DOMAIN>/v1.Backrest/GetOperations -H 'Content-Type: application/json' -d '{}'
```

You should see, in order: the loop reaching `200`, then `<title>Backrest</title>`, then `401`,
then `200`.

If you do not: the `401` is the one worth understanding. It means an API call with no credentials
was refused, so the configuration file you wrote in step 3 was read and authentication is on. A
`200` in its place means the file was not read, and you should stop and check `docker compose
logs --tail 40 backrest` before going anywhere near a browser, because the instance is open. The
last command is the opposite check: it feeds your password to curl through a config on standard
input, so the value never appears in a command line or in your shell history, and a `200` proves
the password in .env matches the hash in config.json. A `401` there means the two disagree, which
means the `caddy hash-password` line in step 3 did not do what it should have. A running
container is not success.

Now read your password with `sudo grep BACKREST_PASSWORD /srv/backrest/.env`, open
https://<DOMAIN>, and log in as `admin`. The first screen is a box headed `Login`, with
`Username` and `Password` fields and a `Log in` button.

You should see: the Backrest dashboard, empty, with `Add Repo` and `Add Plan` in the side menu.

If you do not: `Password is invalid` with the password you copied out of .env usually means a
partial copy, so select the whole value after the `=` and try once more.

## 8. First backup and restore

Two backups here, and they are not the same thing. First this install's own configuration, which
is the archive below. Then your first real snapshot, which is what you installed this for.

```bash
cd /srv/backrest
docker compose stop
sudo tar -czf /srv/backrest/backups/backrest-config-$(date +%F).tar.gz -C /srv/backrest config data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/backrest/backups/
```

You should see: one archive, a few kilobytes on a fresh install. The container is stopped for
about five seconds on purpose, because a SQLite history copied mid-write is not a backup.

If you do not: an archive of about 45 bytes means tar found nothing, so check that you are in
/srv/backrest and that step 3 wrote both files. Treat this archive as a secret from here on: it
holds the .env and, from the next step, every repository password you type.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/backrest
scp vps:/srv/backrest/backups/*.tar.gz ~/backups/backrest/
```

You should see: one file copied, and it listed by `ls -lh ~/backups/backrest/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now the part only you can do. In the web UI: `Add Repo`, and point it at the storage your
snapshots go to. Then `Add Plan`, with paths under `/userdata`. Then run that plan once, and
restore one file from the snapshot into `/restore`.

Three things while you do it. The repository password you type is a restic encryption password:
lose it and every snapshot is unreadable, including by you, so it goes in the password manager
beside the login. The paths box wants paths inside the container, where this server's /srv is
`/userdata`, and `/userdata/backrest` belongs in the excludes because it is this app's own cache
and history. And the storage you point at is a bill from somebody: a B2 or S3 bucket, an SFTP
account, or a disk in a friend's house.

```bash
sudo ls -lR /srv/backrest/restore
```

You should see: the file you restored, non-empty.

If you do not: an empty listing means the restore went somewhere else. In the restore dialog the
target path has to be `/restore`, which is the one writable place the container has, because
`/userdata` is mounted read-only on purpose. A backup nobody has restored is a hope, and that
listing is what turns it into a fact.

To restore Backrest itself: `docker compose down`, `sudo rm -rf /srv/backrest/config
/srv/backrest/data`, recreate the directories as in step 2, untar the archive back into
/srv/backrest, put the Caddy block back if that is what was lost, then `docker compose up -d`.

## 9. Updating later

New versions are listed at https://github.com/garethgeorge/backrest/releases. Take the step 8
archive first, then edit the image line in /srv/backrest/compose.yml to the new tag and digest.

```bash
cd /srv/backrest
docker compose pull
docker compose up -d
docker compose logs --tail 30 backrest
```

You should see: the version line, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Backrest
rewrites its configuration file in place as it migrates, so watch that log until it settles, then
re-run step 7's four checks before you call the update done.

## 10. What will probably go wrong

The paths. I typed `/srv/shlink` into the plan's path box, got an error, retyped it, and spent
several minutes convinced the read-only mount was broken. It was not: the box wants a path inside
the container, and this server's /srv is `/userdata` in there, so the answer was
`/userdata/shlink`. The autocomplete in that field is the tell, because it offers only paths the
container can see. If the first backup finishes in one second and stores nothing, that is the
same mistake wearing a different hat.

## 11. Out of scope

- Do not disable authentication and do not add a second user. This host answers on the public
  internet, and one account with a generated password is the access model.
- Do not configure command hooks. They run in this container as root with /srv mounted.
- Do not configure an rclone remote in the container. The image ships rclone, but its config
  directory is not mounted, so the remote dies with the next recreate.
- Do not set up multihost sync. It pairs this instance with another Backrest somewhere else,
  which this install does not have.
