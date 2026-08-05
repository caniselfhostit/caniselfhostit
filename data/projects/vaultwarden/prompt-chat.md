This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Vaultwarden 1.37.1 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise. Replace `<DOMAIN>` with the hostname whose A record
already points at the box, and `<ADMIN_EMAIL>` with the address you want your vault account
to use.

This one is holding your passwords. Do the backup step. It is step 8 and it is not
optional.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP address on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it at your DNS
provider, wait a minute, run `dig +short <DOMAIN>` again. Do not go on without it: Caddy
cannot get a certificate for a hostname that does not resolve, and failed attempts count
against a rate limit you cannot see.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/vaultwarden /srv/vaultwarden/data /srv/vaultwarden/backups
ls -la /srv/vaultwarden
```

You should see: `data` and `backups`, both owned by your own username, both at
`drwxr-x---`.

If you do not: `install: cannot change owner` means your user cannot sudo, which is a
Prompt Zero problem rather than this one. Remember what `data` is, because every later step
refers back to it: that directory is your entire vault, one SQLite file with the
attachments and the RSA keys beside it.

## 3. Secrets

Two secrets, and both are made here on the server rather than anywhere near this chat
window. The first is the passphrase for Vaultwarden's admin page, which you keep. The
second is the Argon2 hash of it, which is what the server stores, and Vaultwarden's own
binary is what produces it.

Replace `<DOMAIN>` before you paste, and paste the whole block at once:

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

You should see: two files at `-rw-------`, and `1` from the grep. Your passphrase is in
/srv/vaultwarden/admin-passphrase.txt. Read it once, with
`cat /srv/vaultwarden/admin-passphrase.txt`, put it in your new vault after step 7, then
delete the file.

If you do not: `0` from the grep means the hashing step produced nothing, which almost
always means the image pull failed. Run the `docker run` line on its own, read the error,
and paste the block again. A `.env` containing the literal text `<DOMAIN>` means you pasted
before substituting: delete it and start this step over, nothing else has happened yet.

Do not paste `.env`, the passphrase, the hash, or any command output containing them into
this chat window. Nothing in the rest of this guide needs any of those values, and once one
is in a transcript it is somebody else's copy of the key to your vault.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `variable is not set` for `ADMIN_TOKEN` or `DOMAIN` means step 3 did not
finish, so go back. `services must be a mapping` means the indentation was lost between the
page and your terminal: run `rm /srv/vaultwarden/compose.yml` and paste again in one go.
Notice where that port goes. `127.0.0.1:8222:80` publishes the app on loopback only, so the
Caddy already running on this machine is the one thing that can reach it and there is no
public port for you to forget about later.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Nothing here starts
a second Caddy: the one under systemd is already holding 80 and 443, and it is the one that
gets your certificate. Replace `<DOMAIN>` in the block with your hostname before you paste.
The first line takes a copy, because a syntax error here takes down every other site on the
box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-vaultwarden /etc/caddy/Caddyfile`,
reload, and paste again, checking that the blank line from the second command really
landed. A complaint about a brace or a tab means the block did not survive the paste. Caddy
asks Let's Encrypt for the certificate on the first request to your hostname and renews it
on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8222`.

If you do not: a rule for `8222` from an earlier attempt should go, with
`sudo ufw delete allow 8222`. 8222 is bound to 127.0.0.1 by the compose file, so nothing
outside the machine can reach it and a firewall rule for it would cover traffic that cannot
arrive. 80/tcp is there to redirect to HTTPS and answer the ACME challenge, 443/tcp is the
only way in, and 443/udp is HTTP/3.

## 7. Start and verify

```bash
cd /srv/vaultwarden
docker compose pull
docker compose up -d
sleep 15
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

You should see: `200`. That path opens the database to answer, so a 200 means the container
and the vault file are both good.

If you do not: `000` means the certificate is not there yet, and DNS is the usual reason.
Run `dig +short <DOMAIN>` once more, then `sudo journalctl -u caddy -n 30` to watch the
ACME attempt; a record created a few minutes ago makes the first attempt fail and retry
quietly. `502` means Caddy is up but the app is not, so read
`docker compose logs --tail 30 vaultwarden`.

Registration is off in the compose file, which is right for every day except this one. Turn
it on for exactly one step:

```bash
cd /srv/vaultwarden
sed -i 's/SIGNUPS_ALLOWED: "false"/SIGNUPS_ALLOWED: "true"/' /srv/vaultwarden/compose.yml
docker compose up -d --force-recreate vaultwarden
sleep 10
```

You should see: `Recreated`. Now open https://<DOMAIN> in a browser. The first screen shows
a `Log in` heading and a `Create account` link. Create your account with `<ADMIN_EMAIL>`
and sign in.

If you do not: no `Create account` link means the recreate did not happen. Run
`grep SIGNUPS_ALLOWED /srv/vaultwarden/compose.yml`, confirm it reads `"true"`, and run the
recreate line again.

Now close it again, and prove it is closed:

```bash
cd /srv/vaultwarden
sed -i 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' /srv/vaultwarden/compose.yml
docker compose up -d --force-recreate vaultwarden
sleep 10
grep 'SIGNUPS_ALLOWED' /srv/vaultwarden/compose.yml
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

You should see: `SIGNUPS_ALLOWED: "false"`, then `200`. Then reload https://<DOMAIN> in a
fresh private window and confirm the `Create account` link is gone.

If you do not: a `Create account` link that is still there means the container was restarted
rather than recreated, so run the second line again exactly as written. Do not skip this. A
password server that anybody on the internet can register an account on is a password
server for anybody on the internet, and a container showing as running proves none of this.

## 8. First backup and restore

Do this now, before you put a single password in, so you find out today whether it works.
Stop first: a SQLite file copied mid-write is not a backup.

```bash
cd /srv/vaultwarden
docker compose stop
tar -C /srv/vaultwarden -czf /srv/vaultwarden/backups/vaultwarden-$(date +%F).tar.gz data .env
docker compose start
ls -lh /srv/vaultwarden/backups/
```

You should see: one `.tar.gz` file, tens of kilobytes on a fresh install. The site is down
for about five seconds while this runs.

If you do not: `tar: data: Cannot open` means the `cd` did not happen. A size of `45` bytes
means tar wrote an empty archive, so check `ls -la /srv/vaultwarden` before you trust it.

A backup on the same disk as your vault is not a backup. Run this one on your own machine,
not the server:

```bash
mkdir -p ~/backups/vaultwarden
scp vps:/srv/vaultwarden/backups/*.tar.gz ~/backups/vaultwarden/
```

You should see: one file copied, and the same file listed by
`ls -lh ~/backups/vaultwarden/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake.
The `vps:` prefix only means something on your own machine.

Now prove the restore, today, while the only thing at risk is an empty vault:

```bash
cd /srv/vaultwarden
docker compose down
sudo rm -rf /srv/vaultwarden/data
tar -C /srv/vaultwarden -xzf /srv/vaultwarden/backups/vaultwarden-$(date +%F).tar.gz
docker compose up -d
sleep 15
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/alive
```

You should see: `200`, and your account still works when you sign in.

If you do not: a login page that rejects your password after a restore means the archive
did not contain `data/db.sqlite3`, so go back to the tar step. Those four commands are the
whole disaster plan, and you have now run them once. One thing the archive does not hold:
the certificate, which belongs to the host Caddy under /var/lib/caddy, so a restore onto a
fresh machine asks Let's Encrypt for a new one.

## 9. Updating later

New versions are listed at https://github.com/dani-garcia/vaultwarden/releases. Take a
backup first. Run `docker pull` on the new tag by hand once: the `Digest: sha256:` line it
prints is what goes after the `@` in the `image:` line of /srv/vaultwarden/compose.yml.
Edit the tag and the digest together, then:

```bash
cd /srv/vaultwarden
docker compose pull
docker compose up -d
docker compose logs --tail 20 vaultwarden
```

You should see: `Recreated`, then startup lines and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Vaultwarden
migrates its own database on start, so read that log rather than assuming. Caddy is patched
by `apt-get upgrade` on its own schedule and is not part of this step.

## 10. What will probably go wrong

The admin token, and it fails silently. The hash Vaultwarden's own generator prints is full
of `$` characters, and docker compose expands `$` inside `.env` values, so a hash stored
unescaped reaches the container with pieces missing. Nothing errors. The container starts,
the vault works, and /admin refuses the correct passphrase forever. I lost twenty minutes
to that before thinking to compare lengths. Step 3 doubles every `$` for that reason; if
you ever hand-edit that line, or move `.env` between machines through an editor that
helpfully unescapes things, look here first.

## 11. Out of scope

- Do not configure SMTP. Password hint mail is not worth a port 25 argument on a fresh VPS.
- Do not switch the database to PostgreSQL. SQLite is why the whole vault is one directory.
- Do not enable Bitwarden push notifications. They need keys issued by Bitwarden,
  separately.
- Do not add a reverse proxy container, and do not touch any global options block in
  /etc/caddy/Caddyfile. This install appends one site block and nothing else.
