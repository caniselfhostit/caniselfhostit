You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Vaultwarden 1.37.1 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` is the hostname whose A record already points here; `<ADMIN_EMAIL>` is
the address their vault account is created with in step 7, written to no file. Vaultwarden
needs 512 MB of RAM available and 10 GB free on /srv, and runs on amd64 and arm64. Measure:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If RAM is under 512 MB or free disk is under 10 GB, print both and stop; do not install and
hope. If `dig +short` prints nothing, stop too: Caddy cannot certify a name that does not
resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/vaultwarden /srv/vaultwarden/data /srv/vaultwarden/backups
ls -la /srv/vaultwarden
```

Assert: `ls -la` shows `data` and `backups` owned by the login user at mode `750`. Nothing is
written outside /srv/vaultwarden, and `data` is the whole vault: SQLite, attachments, RSA keys.

## 3. Secrets

Two secrets, both generated on the server. The first is the admin page passphrase, which the
user keeps; the second is its Argon2 PHC hash, which is what the server stores, produced by
Vaultwarden's own binary. Print neither value, in chat, in your summary, or in any log line.
Replace `<DOMAIN>` with the real hostname as you write the first file:

```bash
umask 077
cat > /srv/vaultwarden/.env <<'EOF'
DOMAIN=https://<DOMAIN>
EOF
PASSPHRASE="$(openssl rand -base64 33)"
HASH="$(printf '%s\n%s\n' "$PASSPHRASE" "$PASSPHRASE" | docker run --rm -i vaultwarden/server:1.37.1-alpine@sha256:b094afed4ed5ea353821c6efcedca446f30c6654ba2bc441db6089b0c2b94ac8 /vaultwarden hash --preset owasp | grep -o '\$argon2[^ ]*' | tail -n 1)"
ESCAPED="$(printf '%s' "$HASH" | sed 's/[$]/$$/g')"
echo "ADMIN_TOKEN=$ESCAPED" >> /srv/vaultwarden/.env
printf '%s\n' "$PASSPHRASE" > /srv/vaultwarden/admin-passphrase.txt
chmod 600 /srv/vaultwarden/.env /srv/vaultwarden/admin-passphrase.txt
unset PASSPHRASE HASH ESCAPED
umask 022
ls -l /srv/vaultwarden/.env /srv/vaultwarden/admin-passphrase.txt
grep -c '^ADMIN_TOKEN=' /srv/vaultwarden/.env
```

Assert: both files exist at mode `-rw-------` and the grep prints `1`. Doubling every `$` is
what stops compose eating half the hash; step 10 has the whole story. Tell the user the
passphrase is in /srv/vaultwarden/admin-passphrase.txt, to move it into their vault after step 7
and then delete that file, and that you have not read it out anywhere.

## 4. compose.yml

```bash
cat > /srv/vaultwarden/compose.yml <<'EOF'
# Vaultwarden · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   compose shape ... https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose
#   reverse proxy ... https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples
#   admin token ..... https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page
#   websockets ...... https://github.com/dani-garcia/vaultwarden/wiki/Enabling-WebSocket-notifications
#
# One container, and no proxy service: the Caddy that Prompt Zero installed under
# systemd terminates TLS and reaches this one on loopback. SQLite keeps the vault
# and the attachments under /data, so that directory is the whole backup. Since
# 1.31.0 WebSocket traffic rides the main HTTP port. Tag and digest are the 1.37.1
# release read from the Docker Hub registry API on 2026-08-05, amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  vaultwarden:
    image: vaultwarden/server:1.37.1-alpine@sha256:b094afed4ed5ea353821c6efcedca446f30c6654ba2bc441db6089b0c2b94ac8
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: ${DOMAIN}
      # Opened for one step during the install, then closed and asserted closed.
      SIGNUPS_ALLOWED: "false"
      # Argon2 PHC hash made on the server. Every "$" is stored as "$$" in .env.
      ADMIN_TOKEN: ${ADMIN_TOKEN}
    volumes:
      - /srv/vaultwarden/data:/data
    ports:
      # Loopback only, and 8222 never enters the firewall.
      - "127.0.0.1:8222:80"
EOF
cd /srv/vaultwarden && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. If compose reports that `DOMAIN` or `ADMIN_TOKEN` is not set,
step 3 did not finish; go back rather than inventing a value here.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-vaultwarden
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Vaultwarden · the Caddy site block for this service. Authored by caniselfhostit
# from https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples,
# https://github.com/dani-garcia/vaultwarden/wiki/Enabling-WebSocket-notifications
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed under
# systemd, with <DOMAIN> replaced by the hostname pointed at this box. 8222 is the
# loopback port compose publishes; it is not open in the firewall. The X-Real-IP
# header_up is upstream's, and Vaultwarden's login rate limiter reads it.
#
# No WebSocket route, and none is missing: 3012 was removed in 1.31.0 and that
# traffic rides the main HTTP port, which reverse_proxy upgrades on its own.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}

	reverse_proxy 127.0.0.1:8222 {
		header_up X-Real-IP {remote_host}
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-vaultwarden, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it with no cron job, and the systemd Caddy is
already holding 80 and 443, so do not start a second one.

## 6. Firewall

Two ports open, both of them Caddy's, and 8222 is not one of them. These are idempotent, so on
a box Prompt Zero configured they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and
443/udp is HTTP/3, which Caddy offers by default. 8222 stays closed: bound to 127.0.0.1, a rule
for it would cover traffic that cannot arrive, and `sudo ufw delete allow 8222` removes one a
previous run left. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule for 8222.

## 7. Start and verify

```bash
cd /srv/vaultwarden
docker compose pull
docker compose up -d
sleep 15
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

Assert: that prints `200`. `/alive` opens the database to answer, so 200 means container and
vault file are both good. Anything else: stop, run `docker compose logs --tail 30 vaultwarden`
and `sudo journalctl -u caddy -n 30`, and say which earlier step is the likely cause. Usually
DNS: an A record created minutes ago makes Caddy's first certificate attempt fail and retry.

Registration is off in compose.yml, which is right for every day except this one. Turn it on
for exactly one step:

```bash
cd /srv/vaultwarden
sed -i 's/SIGNUPS_ALLOWED: "false"/SIGNUPS_ALLOWED: "true"/' /srv/vaultwarden/compose.yml
docker compose up -d --force-recreate vaultwarden
sleep 10
```

The first screen at https://<DOMAIN> shows a `Log in` heading and a `Create account` link.

STOP: tell the user to open https://<DOMAIN>, create their account using <ADMIN_EMAIL>, and
wait. Do not continue until they confirm they can sign in.

Once they confirm, close registration again:

```bash
cd /srv/vaultwarden
sed -i 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' /srv/vaultwarden/compose.yml
docker compose up -d --force-recreate vaultwarden
sleep 10
grep 'SIGNUPS_ALLOWED' /srv/vaultwarden/compose.yml
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

Assert, all three: the grep prints `SIGNUPS_ALLOWED: "false"`, the curl prints `200`, and the
user reloads and confirms the `Create account` link is gone. All three pass before you report
success, and the third is the one with security meaning. A running container is not success.

## 8. First backup and restore

Take the backup now, before the user puts a single password in, and take it with the app
stopped: a SQLite file copied mid-write is not a backup.

```bash
cd /srv/vaultwarden
docker compose stop
tar -C /srv/vaultwarden -czf /srv/vaultwarden/backups/vaultwarden-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/vaultwarden/backups/
```

Assert: the archive exists and is non-empty. Print its size. Downtime is about five seconds,
and `data` plus `.env` is the whole install. A backup on the same disk as the data is not a
backup, so run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/vaultwarden
scp vps:/srv/vaultwarden/backups/*.tar.gz ~/backups/vaultwarden/
```

Now prove the restore, today, while the only thing at risk is an empty vault. A backup nobody
has restored is a guess:

```bash
cd /srv/vaultwarden
docker compose down
sudo rm -rf /srv/vaultwarden/data
tar -C /srv/vaultwarden -xzf /srv/vaultwarden/backups/vaultwarden-$(date +%F).tar.gz
docker compose up -d
sleep 15
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

Assert: `200`. Then tell the user to sign in once with the account from step 7; if that
password is refused, the archive did not hold `data/db.sqlite3` and the tar step is where to
look. Those four commands are the whole disaster plan and they have now been run once. The
certificate is not among them: it belongs to the host Caddy under /var/lib/caddy, so a restore
onto a fresh machine asks Let's Encrypt for a new one.

## 9. Updating later

New versions are listed at https://github.com/dani-garcia/vaultwarden/releases. Take a backup
first. Run `docker pull` on the new tag by hand once: the `Digest: sha256:` line it prints is
what goes after the `@` in the image line of /srv/vaultwarden/compose.yml. Edit both, then:

```bash
cd /srv/vaultwarden
docker compose pull
docker compose up -d
docker compose logs --tail 20 vaultwarden
```

Vaultwarden migrates its own database on start, so read that log before calling it done.

## 10. What will probably go wrong

The admin token, and it fails silently. The hash Vaultwarden's own generator prints is full of
`$`, and docker compose expands `$` inside `.env` values, so a hash stored unescaped reaches
the container with pieces missing. Nothing errors. The container starts, the vault works, and
/admin refuses the correct passphrase forever. I lost twenty minutes to that before thinking to
compare lengths. Step 3 doubles every `$` for that reason; if the user hand-edits it, look
here first.

## 11. Out of scope

- Do not configure SMTP. Password hint mail is not worth a port 25 argument on a fresh VPS.
- Do not switch the database to PostgreSQL. SQLite is why the whole vault is one directory.
- Do not enable Bitwarden push notifications. They need keys issued by Bitwarden, separately.
- Do not add a reverse proxy container, and do not touch any global options block in
  /etc/caddy/Caddyfile. This install appends one site block and nothing else.
