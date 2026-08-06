This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Grist 1.7.17 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise. Replace `<DOMAIN>` with the hostname whose A record already points at the
box, and `<ADMIN_EMAIL>` with the address you want to be the administrator of this Grist
installation.

Read this before step 1, because it is the fact that shapes the whole install. grist-core
ships no username-and-password login of its own. Left on a public hostname without one in
front of it, it is an open database. What goes in front of it here is Caddy: a login box
Caddy checks, and then Caddy tells Grist which address it verified. `<ADMIN_EMAIL>` is
both that verified address and the username you type at every sign-in, so pick the one you
will not want to change.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
caddy version
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, a Caddy
version of `2.8` or newer, and your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a
hostname that does not resolve and failed attempts count against a rate limit you cannot see.
A Caddy older than 2.8 is the other blocker: step 5 uses the `basic_auth` directive, which is
what 2.8 renamed `basicauth` to, and an older binary will reject the file. Upgrade Caddy
before you go on.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/grist /srv/grist/backups
sudo install -d -m 700 /srv/grist/persist
ls -la /srv/grist
```

You should see: `backups` owned by you, and `persist` at mode `drwx------` owned by root.

If you do not: leave `persist` owned by root on purpose. The Grist image starts as root,
chowns everything under /persist to its own unprivileged user, and only then drops to that
user, so anything you set here is replaced on the first start. Documents will land in
`persist/docs` as `.grist` SQLite files, and the account table is `persist/home.sqlite3`.

## 3. Secrets

Two secrets, both generated here on the server, both landing in files only you can read. The
first replaces a session key whose default value is published in the Grist source. The second
is the password on the login box, and it is the only thing standing between the public
internet and this database.

```bash
umask 077
cat > /srv/grist/.env <<EOF
APP_HOME_URL=https://<DOMAIN>
GRIST_DEFAULT_EMAIL=<ADMIN_EMAIL>
GRIST_SESSION_SECRET=$(openssl rand -hex 32)
EOF
openssl rand -hex 24 > /srv/grist/browser-login
chmod 600 /srv/grist/.env /srv/grist/browser-login
umask 022
ls -l /srv/grist/.env /srv/grist/browser-login
```

You should see: two files, both mode `-rw-------`, both owned by you. Replace `<DOMAIN>` and
`<ADMIN_EMAIL>` on those two lines with your real values before you paste. Read the login
password once with `cat /srv/grist/browser-login` and put it in your password manager now:
you will type it, with `<ADMIN_EMAIL>` as the username, every time you open the site.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run
`chmod 600 /srv/grist/.env /srv/grist/browser-login` and carry on. If either file already
existed from an earlier attempt, this block has now overwritten it, which is harmless before
step 5 and a locked-out login afterwards, because the hash Caddy checks was built from the old
value.

Do not paste `.env`, the login password, or any command output containing either into this
chat window. Hex rather than base64 for both, because the login value gets typed into a
browser dialog and hex has nothing in it a keyboard layout can ruin.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/grist/compose.yml <<'EOF'
# Grist · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   self-managed ....... https://support.getgrist.com/self-managed/
#   forwarded headers .. https://support.getgrist.com/install/forwarded-headers/
#   env var reference .. https://github.com/gristlabs/grist-core/blob/v1.7.17/README.md
#   upstream examples .. https://github.com/gristlabs/grist-core/tree/v1.7.17/docker-compose-examples
#
# One service. Documents are .grist SQLite files under /persist/docs and the
# account table is /persist/home.sqlite3, so there is no database process to run
# and nothing to dump. grist-core ships no username-and-password login of its
# own: the host Caddy checks the credential and passes the address it verified
# in X-Forwarded-User, which is what GRIST_FORWARD_AUTH_HEADER together with
# GRIST_IGNORE_SESSION tells Grist to trust on every request. Tag and digest
# were read from Docker Hub on 2026-08-06; the image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  grist:
    image: gristlabs/grist-oss:1.7.17@sha256:b87ec1c3b62ca99f872611a9aa71ca33ee5fef9f40e0921e0beed878e5083473
    container_name: grist
    restart: unless-stopped
    environment:
      # These three come from /srv/grist/.env, which is mode 600. Compose reads
      # that file for substitution because it sits beside this one.
      APP_HOME_URL: ${APP_HOME_URL}
      GRIST_DEFAULT_EMAIL: ${GRIST_DEFAULT_EMAIL}
      GRIST_SESSION_SECRET: ${GRIST_SESSION_SECRET}
      # Trust this header, and only this header, for identity. Caddy overwrites
      # it on every proxied request, so a browser cannot put a name in it.
      GRIST_FORWARD_AUTH_HEADER: X-Forwarded-User
      GRIST_IGNORE_SESSION: "true"
      GRIST_FORCE_LOGIN: "true"
      # One team site, so no /o/<team> prefix turns up in any URL.
      GRIST_SINGLE_ORG: grist
      # Skip the first-run Quick setup gate, which would otherwise ask for a
      # boot key pasted out of the container log.
      GRIST_IN_SERVICE: "true"
      # Formulas are Python running on this server. On a public host they run
      # inside gvisor rather than directly.
      GRIST_SANDBOX_FLAVOR: gvisor
    volumes:
      # The image chowns everything under /persist to its own user on start,
      # then drops out of root, so this directory is left alone after step 2.
      - /srv/grist/persist:/persist
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8101.
      - "127.0.0.1:8101:8484"
EOF
cd /srv/grist && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page
and your terminal, so run `rm /srv/grist/compose.yml` and paste again in one go. A warning
that `APP_HOME_URL` is not set means you are not in /srv/grist, or step 3 did not write
`.env`; compose reads that file for substitution because it sits beside compose.yml, so the
`cd` is not optional. There is no second service on purpose: Grist keeps documents and
accounts in SQLite files inside /persist, so there is no database to run and none to dump.

## 5. Caddy and TLS

Two files. First the credential Caddy will check. It is a bcrypt hash of the password step 3
generated, written where the caddy user can read it and nowhere else.

```bash
umask 077
caddy hash-password < /srv/grist/browser-login > /srv/grist/grist-auth.hash
printf 'basic_auth {\n\t%s %s\n}\n' '<ADMIN_EMAIL>' "$(cat /srv/grist/grist-auth.hash)" > /srv/grist/grist-auth.conf
umask 022
sudo install -m 640 -o root -g caddy /srv/grist/grist-auth.conf /etc/caddy/grist-auth.conf
rm -f /srv/grist/grist-auth.hash /srv/grist/grist-auth.conf
sudo grep -c basic_auth /etc/caddy/grist-auth.conf
```

You should see: `1`.

If you do not: `chown: invalid group: 'root:caddy'` means Caddy was installed some way that
did not create a `caddy` group, so use the group the Caddy service actually runs as, which
`systemctl show -p User -p Group caddy` will tell you. Reading the password from a file rather
than passing it on the command line is deliberate: an argument is visible in the process list
to anyone else on the box.

Now the site block. Replace `<DOMAIN>` in it with your hostname before you paste. The first
line takes a copy, because a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-grist
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Grist · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://support.getgrist.com/install/forwarded-headers/,
# https://support.getgrist.com/self-managed/ and
# https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. grist-core has no
# username-and-password login of its own, so this block is the login: Caddy
# checks the credential and then tells Grist which address it verified. Needs
# Caddy 2.8 or newer, which is where the directive is spelled basic_auth.

<DOMAIN> {
	# Grist ships a large JavaScript bundle, so compression is worth having.
	# WebSocket upgrades pass through untouched.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# The credential is not in this file, because this file is published. The
	# install writes /etc/caddy/grist-auth.conf with one basic_auth block: the
	# username, and a bcrypt hash of the password it generated. That file is
	# mode 640, owned by root and readable by the caddy group.
	import /etc/caddy/grist-auth.conf

	# 8101 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8101 {
		# Set, not add. Whatever a browser sent under this name is replaced by
		# the username basic_auth has verified, so the header cannot be
		# spoofed, which is the one thing this whole arrangement depends on.
		header_up X-Forwarded-User {http.auth.user.id}
	}
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-grist /etc/caddy/Caddyfile`, reload,
and paste again. `unrecognized directive: basic_auth` is the Caddy version problem from step 1
showing up late. `import: no files matching` means the first fence in this step did not write
/etc/caddy/grist-auth.conf. Caddy requests the certificate on the first request to the
hostname and renews it on its own, so there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8101`.

If you do not: delete anything for `8101` with `sudo ufw delete allow 8101`. That port is
bound to 127.0.0.1 by the compose file, and opening it would route around the login box you
built in step 5, which is the entire security of this install. 80/tcp redirects to HTTPS and
answers the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy
offers by default. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

```bash
cd /srv/grist
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8101/status?db=1'); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS 'http://127.0.0.1:8101/status?db=1'
docker compose logs grist | grep -c 'gvisor check ok'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see, in order: the loop reaching `200`, a line containing `is alive` and `db ok`,
then `1`, then `401`.

If you do not: the `401` is the one worth understanding. It means Caddy is refusing a request
that carried no credential, which is exactly what should happen, so seeing it is good news. A
`200` in its place means the login box is not in the path, and you should stop and re-read
step 5 before you put anything real in this install. A `502` means Caddy is up and the
container is not. If the loop never reaches `200`, run `docker compose logs --tail 40 grist`:
`gvisor check failed` there means this kernel will not run the sandbox and the container is
exiting on purpose, which is step 10, and it is not something to fix by switching the sandbox
off.

Now open https://<DOMAIN> in a browser. You will get a login box: the username is
`<ADMIN_EMAIL>`, the password is what `cat /srv/grist/browser-login` prints. The first screen
after signing in shows `Create empty document`. Create one document and put a number in a
cell. A running container is not success, and neither is a login box: the document has to
open, because that is the part that uses the WebSocket the proxy has to carry.

## 8. First backup and restore

One archive. Stop the container first: the documents are SQLite files, and a copy taken
mid-write is not a backup.

```bash
cd /srv/grist
docker compose stop
sudo tar -czf /srv/grist/backups/grist-$(date +%F).tar.gz -C /srv/grist persist .env browser-login compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/grist/backups/
```

You should see: one `.tar.gz`, a few hundred kilobytes on a fresh install, and about ten
seconds of downtime.

If you do not: an archive of a few hundred bytes means `persist` was empty, so the container
never started properly and step 7 was passed too generously. That archive holds both secrets,
so treat it as you would the data.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/grist
scp vps:/srv/grist/backups/*.tar.gz ~/backups/grist/
```

You should see: one file copied, and listed by `ls -lh ~/backups/grist/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is a test number:

```bash
cd /srv/grist
docker compose down
sudo rm -rf /srv/grist/persist
sudo tar -C /srv/grist -xzf /srv/grist/backups/grist-$(date +%F).tar.gz
docker compose up -d
sleep 30
curl -sS 'http://127.0.0.1:8101/status?db=1'
```

You should see: `is alive` and `db ok` again, and your document with its number still in it
when you reload the browser.

If you do not: if you ever restore onto a box where /etc/caddy/grist-auth.conf is missing or
stale, rebuild it by re-running the first fence of step 5 against the restored
`browser-login`, then `sudo systemctl reload caddy`. Those steps plus this archive are the
whole disaster plan.

## 9. Updating later

New versions are listed at https://github.com/gristlabs/grist-core/releases. Take the backup
first, then edit the `image:` line in /srv/grist/compose.yml to the new tag and its digest.

```bash
cd /srv/grist
docker compose pull
docker compose up -d
docker compose logs --tail 30 grist
```

You should see: the gvisor check line, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
the four checks from step 7 before you call the update done, and open a real document as well,
because a server that answers `is alive` can still be failing to open documents if a migration
stopped halfway.

## 10. What will probably go wrong

The sandbox. The compose file sets `GRIST_SANDBOX_FLAVOR=gvisor` because formulas in Grist are
Python running on this server, and that turns a start-up check into a hard gate: upstream's
own start script runs `runsc` once before the server, prints `gvisor check ok` or
`gvisor check failed`, and exits on failure. A container stuck in that loop looks fine from
the outside, which is the part that cost me time: `docker compose ps` reports it as restarting
rather than as broken, and the reason is only ever in the log. It is not a Grist bug, and the
honest options are a VPS whose kernel hosts gvisor or a deliberate decision that you will only
open documents you wrote yourself. Read the log before you conclude anything else is wrong.

## 11. Out of scope

- Do not configure OIDC, SAML or any identity provider. Caddy's login box is the whole auth
  story here, and a second one leaves two doors into the same install.
- Do not set `GRIST_BOOT_KEY` or open the Quick setup page. `GRIST_IN_SERVICE` skips that gate
  on purpose, and the address in `GRIST_DEFAULT_EMAIL` is already the installation admin.
- Do not configure SMTP, and do not set `ASSISTANT_API_KEY` or `OPENAI_API_KEY`. Grist runs
  without mail, and the formula assistant is a paid account somewhere else.
- Do not add Redis, PostgreSQL or MinIO. Those belong to the multi-worker setup upstream
  documents separately; this install is one container with SQLite files.
