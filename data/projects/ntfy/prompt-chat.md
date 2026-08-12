This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing ntfy 2.27.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box.

Read these three before step 1. This install is a private push broker: auth-default-access is
deny-all, so a stranger who guesses a topic cannot publish. Users are created with
`ntfy user add` on the server CLI, not in a browser signup form. Instant iOS delivery on a
self-hosted server needs an upstream APNS bridge through ntfy.sh if you want it; this install
leaves that off until you opt in.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `256` MB available, at least `2` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and NTFY_BASE_URL must be that same public URL.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/ntfy /srv/ntfy/backups /srv/ntfy/cache /srv/ntfy/auth
ls -la /srv/ntfy
```

You should see: `backups`, `cache` and `auth` under /srv/ntfy, owned by your login user.

If you do not: re-run the `install -d` line. `cache` holds the message SQLite file and
attachments. `auth` holds the user database. There is no empty `data/` directory in this install.

## 3. Secrets

One secret: the password for the admin account you create in step 7. Generate it on the server.
Do not paste it into this chat. Replace `<DOMAIN>` before you run the block.

```bash
umask 077
cat > /srv/ntfy/.env <<EOF
NTFY_BASE_URL=https://<DOMAIN>
NTFY_USERNAME=admin
NTFY_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/ntfy/.env
umask 022
ls -l /srv/ntfy/.env
```

You should see: mode `-rw-------` and your own username twice.

If you do not: run `chmod 600 /srv/ntfy/.env` and carry on. Your username is `admin`. Read the
password once with `sudo grep NTFY_PASSWORD /srv/ntfy/.env` and put it in your password manager.
Do not paste that file into this chat window.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/ntfy/compose.yml <<'EOF'
# ntfy · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.ntfy.sh/install/#docker
#   configuration ...... https://docs.ntfy.sh/config/
#   access control ..... https://docs.ntfy.sh/config/#access-control
#   behind a proxy ..... https://docs.ntfy.sh/config/#behind-a-proxy-tls-etc
#
# One container. Serve listens on port 80 inside the image. Auth is closed by
# default (deny-all): anonymous publish and subscribe are refused until a user
# is created with `ntfy user add`. Cache and auth live on separate mounts so a
# backup can name each path. NTFY_BASE_URL comes from .env and must be the
# public https URL (this file is the VPS path). behind-proxy is true because
# Caddy on the host terminates TLS. Digest read from Docker Hub on 2026-08-07;
# the manifest list covers amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  ntfy:
    image: binwiederhier/ntfy:v2.27.0@sha256:f2419f405127afa868f10985c1a41449e673477cee1eb19994339a5ae8b592e7
    container_name: ntfy
    restart: unless-stopped
    command: ["serve"]
    env_file: /srv/ntfy/.env
    environment:
      # Public URL phones and curl use. Set in .env as https://your.hostname.
      NTFY_BASE_URL: ${NTFY_BASE_URL}
      NTFY_CACHE_FILE: /var/cache/ntfy/cache.db
      NTFY_ATTACHMENT_CACHE_DIR: /var/cache/ntfy/attachments
      # Auth database is created on first start when this path is set.
      NTFY_AUTH_FILE: /var/lib/ntfy/user.db
      # Private instance: no anonymous read or write to any topic.
      NTFY_AUTH_DEFAULT_ACCESS: deny-all
      # Web UI login form; users themselves are still created on the CLI.
      NTFY_ENABLE_LOGIN: "true"
      # Rate limits must use X-Forwarded-For; without this every client is Caddy.
      NTFY_BEHIND_PROXY: "true"
    volumes:
      - /srv/ntfy/cache:/var/cache/ntfy
      - /srv/ntfy/auth:/var/lib/ntfy
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8200.
      - "127.0.0.1:8200:80"
EOF
cd /srv/ntfy && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost. Run
`rm /srv/ntfy/compose.yml` and paste again in one go.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Set `DOMAIN_HOST` to
your real hostname (not the literal string `<DOMAIN>`) before you paste. The first line takes a
copy, because a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-ntfy
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" <<'EOF' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
# ntfy · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.ntfy.sh/config/#nginxapachecaddy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Caddy runs under systemd
# on the host. There is no Caddy container anywhere in this project. Long-lived
# subscribe streams and WebSockets use Caddy's default reverse_proxy behaviour.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8200 is the loopback port compose publishes; it is never in the firewall.
	reverse_proxy 127.0.0.1:8200
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-ntfy /etc/caddy/Caddyfile`, reload, and
paste again. Caddy requests the certificate on the first request to the hostname and renews it
on its own.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8200`.

If you do not: delete anything for `8200` with `sudo ufw delete allow 8200`. It is bound to
127.0.0.1 by the compose file, so a rule for it would cover traffic that cannot arrive.

## 7. Start and verify

```bash
cd /srv/ntfy
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sS https://<DOMAIN>/v1/health; echo
```

You should see: the loop reaching `200`, then healthy JSON from `/v1/health`.

If you do not: run `docker compose logs --tail 40 ntfy` and read the last lines before
continuing. A container that exits on its own usually means the auth path is not writable or
the image pull failed; check that `/srv/ntfy/auth` and `/srv/ntfy/cache` exist and are owned
by your login user. A 502 from Caddy with a running container points at step 5 (wrong port or
a site block that never reloaded).

Create the admin user. Upstream accepts `NTFY_PASSWORD` in the environment so the command is
non-interactive. There is no browser "create account" step anywhere in this product: if you
only open the web UI and look for a signup form, you will not find a working open registration
path, because enable-signup is off and deny-all is on.

```bash
cd /srv/ntfy
NTFY_PASS=$(grep -E '^NTFY_PASSWORD=' .env | cut -d= -f2-)
NTFY_USER=$(grep -E '^NTFY_USERNAME=' .env | cut -d= -f2-)
docker compose exec -T -e NTFY_PASSWORD="$NTFY_PASS" ntfy ntfy user add --role=admin "$NTFY_USER"
docker compose exec -T ntfy ntfy user list
```

You should see: a line for your admin user with role admin. Do not paste `$NTFY_PASS` into this
chat.

Prove the door is closed, then that your account can still publish:

```bash
unauth=$(curl -sS -o /dev/null -w '%{http_code}' -d 'probe' https://<DOMAIN>/caniselfhostit-probe)
echo "anonymous publish: $unauth"
auth=$(curl -sS -o /dev/null -w '%{http_code}' -u "${NTFY_USER}:${NTFY_PASS}" -d 'install ok' https://<DOMAIN>/caniselfhostit-probe)
echo "authenticated publish: $auth"
```

You should see: `anonymous publish: 403` and `authenticated publish: 200`.

If you do not: a `200` on anonymous means auth did not load; check that `NTFY_AUTH_FILE` and
`NTFY_AUTH_DEFAULT_ACCESS` are in the compose file and recreate the container. A non-200 on
authenticated means the user was not created or the password does not match `.env`.

Publish handoff: open the ntfy app on a phone, add https://<DOMAIN> as a custom server, sign in
as admin with the password from `.env`, subscribe to a topic (for example `alerts`), then:

```bash
curl -u "${NTFY_USER}:${NTFY_PASS}" -d 'phone test' https://<DOMAIN>/alerts
```

The phone should show that message. Instant iOS delivery needs
`NTFY_UPSTREAM_BASE_URL=https://ntfy.sh` in the compose environment (a third-party APNS hop);
without it, iOS is delayed. Android does not need that bridge for self-host. If the phone is on
cellular and the hostname resolves, this is the real loop the product exists for: script on
the server, toast on the handset.

Access tokens are optional later: `docker compose exec -T ntfy ntfy token add admin` creates a
token you can put in scripts so the password never appears in cron lines. Tokens still grant
full account access today, so treat them like the password.

Open https://<DOMAIN> in a private window, log in, and confirm that a bare
`curl -d hi https://<DOMAIN>/topic` still returns 403. Do not continue until they confirm.

## 8. First backup and restore

One archive: the cache, the auth database, compose.yml, `.env`, and the live Caddyfile.

```bash
cd /srv/ntfy
docker compose stop
sudo tar -czf /srv/ntfy/backups/ntfy-$(date +%F).tar.gz -C /srv/ntfy cache auth compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/ntfy/backups/
```

You should see: one non-empty file. Downtime is a few seconds; the container is stopped so
SQLite is not copied mid-write.

If you do not: an archive of about 100 bytes means `tar` found none of the paths. Run
`tar -tzf` on it and read what it actually contains.

A backup on the same disk as the data is not a backup. On your own machine:

```bash
mkdir -p ~/backups/ntfy
scp vps:/srv/ntfy/backups/*.tar.gz ~/backups/ntfy/
```

To restore: `docker compose down`, remove `cache` and `auth`, recreate those directories, untar
into /srv/ntfy (restores `.env` and compose.yml), restore the Caddy block if needed, then
`docker compose up -d`. `auth/` is every account; `.env` is the only place the generated
password lives. Losing either without the other is a lockout.

Prove the restore while the only thing at risk is a test topic: after `docker compose up -d`,
wait for `/v1/health` to return 200, then re-run the anonymous publish curl and confirm it is
still `403`, and the authenticated publish is still `200` with the password from the restored
`.env`. If authenticated fails after a restore that included `auth/` but not `.env`, you have
the classic lockout: recreate the admin user only if you are willing to lose the old password
mapping, otherwise find the `.env` from the off-box copy of the archive.

## 9. Updating later

New versions are listed at https://github.com/binwiederhier/ntfy/releases. The release tag and
the image tag are the same string. Take a backup first, then edit the `image:` line in
/srv/ntfy/compose.yml to the new tag and its digest.

```bash
cd /srv/ntfy
docker compose pull
docker compose up -d
docker compose logs --tail 30 ntfy
```

You should see: the server starting, no restart loop. Re-run `/v1/health` and the anonymous
`403` check from step 7 before you call the update done.

## 10. What will probably go wrong

You will publish a test message, the phone will stay silent, and you will assume ntfy is broken.
I did that on a self-hosted box with the iOS app. Android was fine; iOS was minutes late. Instant
delivery on iOS is not pure self-host: set `NTFY_UPSTREAM_BASE_URL=https://ntfy.sh` only if you
accept that wake-ups touch ntfy.sh. Without that line, iOS still works as delayed polling. The
other common miss is a bare `curl -d hi https://host/topic` returning 403 after deny-all. That
is the product working. Use `-u admin:password` or an access token.

A second failure mode is rate limiting that treats every visitor as one IP. If you forget
`NTFY_BEHIND_PROXY=true` while Caddy terminates TLS, ntfy sees only Caddy's address and the
whole world shares one visitor bucket. This compose already sets behind-proxy; if you strip it
during an experiment, put it back before you call the install healthy under load.

A third is restoring only `cache/` and forgetting `.env`. After a restore the container starts,
deny-all still holds, and you no longer know the password that matches `auth/`. Always restore
`.env` with the auth database.

## 11. Out of scope

- Do not set `NTFY_UPSTREAM_BASE_URL` unless you want the iOS APNS bridge and accept the hop.
- Do not enable signup. New accounts are `ntfy user add` on the server only.
- Do not open port 8200 in the firewall. Caddy is the only public listener.
- Do not switch the cache to PostgreSQL. SQLite in the `cache` mount is the choice here.
- Do not configure Firebase credentials for FCM on this install.
- Do not leave auth-default-access at read-write on a public hostname. That recreates the open
  ntfy.sh shape on your own box, and anyone who learns a topic name can publish to your phone.

