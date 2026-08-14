This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Stalwart 0.16.17 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the mail hostname whose A record
already points at the box.

Read this before step 1. This is a mail server, which means two things no other install on
this site involves. Ports 25, 465 and 993 are published on every interface rather than on
loopback, because other mail servers open 25 themselves and your phone opens 465 and 993
itself, and no reverse proxy can stand in for that. And the software is only half the job:
whether your mail reaches an inbox or a spam folder is decided by DNS records, by the reverse
DNS on your IP address, and by weeks of sending history you do not have yet. Pick a hostname
you intend to keep: `<DOMAIN>` is `mail.example.com`, one label in front of the domain your
addresses will live at, and it becomes the name in SMTP EHLO, the name on the certificate your
phone checks on port 993, and the name reverse DNS has to match.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
dig +short -x $(dig +short <DOMAIN> | tail -1)
timeout 10 bash -c 'exec 3<>/dev/tcp/aspmx.l.google.com/25' && echo "outbound 25 OPEN" || echo "outbound 25 BLOCKED"
```

You should see: at least `1024` MB available, at least `10` G free, `amd64` or `arm64`, your
server's IP, a PTR record reading `<DOMAIN>.`, and `outbound 25 OPEN`.

If you do not: an empty fourth line means the A record does not exist yet, so add it, wait a
minute and re-run, because Caddy cannot get a certificate for a name that does not resolve. An
empty or wrong fifth line means reverse DNS is not set. Only your hosting provider can set it,
usually in a field called rDNS or PTR next to the IP address in their control panel, and until
it matches, receiving servers read your mail as more likely forged. On resources, upstream
measures an idle Stalwart near 100 MB and calls 1 GB enough for five to ten users; the 10 GB
floor is about mail, which only grows.

`outbound 25 BLOCKED` is the one that stops this install dead. Most VPS providers block
outbound port 25 by default, because most spam comes from rented boxes, and most of them
unblock it on request after a short conversation about what the machine is for. Open that
ticket now and wait for the answer before going further. A server that cannot open 25 outbound
receives mail perfectly well and delivers none of it, and it will look like a working install
for about a day.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/stalwart /srv/stalwart/backups
sudo install -d -m 700 -o 2000 -g 2000 /srv/stalwart/etc /srv/stalwart/data /srv/stalwart/log
ls -la /srv/stalwart
```

You should see: `backups` owned by you, and `etc`, `data` and `log` at mode `drwx------` owned
by `2000`.

If you do not: the uid matters. The image creates a `stalwart` user with uid 2000 and runs as
it, so a directory owned by you is a directory the container cannot write. `etc` will hold
`config.json`, the one file whose presence means setup is finished; `data` will hold the
RocksDB with every message and every setting in it; `log` exists because the setup wizard's
default log destination is a path under `/var/log/stalwart` the image does not create, and
without the mount you get startup errors about a directory that is not there.

## 3. Secrets

One secret: the bootstrap administrator credential, generated here on the server. Replace
`<DOMAIN>` on the first two lines with your real hostname before you paste.

```bash
umask 077
cat > /srv/stalwart/.env <<EOF
STALWART_HOSTNAME=<DOMAIN>
STALWART_PUBLIC_URL=https://<DOMAIN>
STALWART_RECOVERY_ADMIN=admin:$(openssl rand -hex 24)
EOF
chmod 600 /srv/stalwart/.env
umask 022
ls -l /srv/stalwart/.env
```

You should see: mode `-rw-------` and your own username twice. Your bootstrap username is
`admin` and the password is the part after the colon; read it once with
`sudo grep STALWART_RECOVERY_ADMIN /srv/stalwart/.env` when step 7 asks for it.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/stalwart/.env` and
carry on. Setting this value before the first start is the whole point of the step: left
unset, Stalwart generates its own bootstrap password and writes it to the container log in
clear text, once, where it stays for anyone who can read `docker compose logs`. Hex rather
than base64 because Stalwart reads a leading `$`, `_` or `{` in this value as a hash prefix.

Do not paste that file, the credential, or any command output containing it into this chat
window. The agent path never sees those values; this window will hand them to a third party
unless you keep them out of it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/stalwart/compose.yml <<'EOF'
# Stalwart · the deterministic fallback. Authored by caniselfhostit from
# https://stalw.art/docs/install/platform/docker and
# https://stalw.art/docs/install/security
#
# DELIBERATE DEVIATION from every other entry in this catalog: 25, 465 and 993
# are published on every interface rather than on 127.0.0.1, because other mail
# servers open 25 themselves and clients open 465 and 993 themselves, over TLS
# this container terminates. One port stays on loopback and Caddy alone reaches
# it: 8189, the plain HTTP listener carrying the admin UI, JMAP, autoconfig and
# the ACME challenge.
#
# One service: mail, accounts and configuration all live in an embedded RocksDB
# under /var/lib/stalwart. While /etc/stalwart/config.json is absent the server
# runs in bootstrap mode, one HTTP listener on 8080 and no mail ports;
# afterwards it opens 25, 465, 993, 995, 4190, 443 and 8080, the last three
# unpublished. No 587: upstream creates no listener on it. The image runs as
# uid 2000 and ships its own HEALTHCHECK. Digest read 2026-08-14; amd64, arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  stalwart:
    image: stalwartlabs/stalwart:v0.16.17@sha256:a8108e19bd927e172d4d8c128907b8dfc93fd180ae8ee07dccdd42cb97eb9dfa
    container_name: stalwart
    restart: unless-stopped
    # Hostname, public URL and the bootstrap credential. Mode 600.
    env_file: /srv/stalwart/.env
    volumes:
      # config.json, the RocksDB, the log path; all owned by uid 2000.
      - /srv/stalwart/etc:/etc/stalwart
      - /srv/stalwart/data:/var/lib/stalwart
      - /srv/stalwart/log:/var/log/stalwart
    ports:
      - "25:25"
      - "465:465"
      - "993:993"
      # Loopback only: the host's Caddy is the only thing that reaches 8189.
      - "127.0.0.1:8189:8080"
EOF
cd /srv/stalwart && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `docker compose config` prints the line and column it choked on. The usual cause
is a heredoc that was pasted in two pieces, which leaves a stray `EOF` in the middle of the
file. Delete /srv/stalwart/compose.yml and paste the whole block again in one go.

## 5. Caddy and TLS

Copy the Caddyfile first: a syntax error here takes down every other site on the box. Replace
`<DOMAIN>` with your real hostname in the block below before you paste it.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-stalwart
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Stalwart · the Caddy site block for this service. Authored by caniselfhostit
# from https://stalw.art/docs/install/security and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box, which is also STALWART_HOSTNAME in .env and has to match
# the PTR record. The whole hostname is proxied, not only /admin: the same
# listener serves JMAP, WebDAV, autoconfig, MTA-STS, OAuth and the
# acme-challenge path answered while renewing the 465 and 993 certificate.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8189 is the loopback port compose publishes for the container's plain
	# HTTP listener. Not a container port, not in the firewall.
	reverse_proxy 127.0.0.1:8189
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from the reload.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-stalwart /etc/caddy/Caddyfile`, reload, and read what
validate objected to before trying again. The most common cause is a `<DOMAIN>` left literal.
Caddy issues and renews the certificate for the web side by itself. The certificate on 25, 465
and 993 is a different one that Stalwart gets for itself, and step 7 finishes that.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 25/tcp
sudo ufw allow 465/tcp
sudo ufw allow 993/tcp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 25, 80, 443 and 465 and 993, and no rule for
8189.

If you do not: 80/tcp answers the ACME challenge and 443 is Caddy. 25/tcp is how every other
mail server on the internet reaches yours, 465/tcp is where your mail client submits under
implicit TLS, which upstream recommends over 587, and 993/tcp is IMAP. 8189 is bound to
127.0.0.1 so it must not appear, and 995, 4190, 143, 110 and 587 stay closed because the
compose file publishes none of them. One honest note about that output: Docker writes its own
iptables rules for published ports and they are read before ufw's, so 25, 465 and 993 are
reachable whether or not ufw lists them. The `ports:` list in compose.yml is the real control
here; these rules record the intent and cover the host itself.

## 7. Start and verify

With no `config.json` on disk, Stalwart starts in bootstrap mode: one plain HTTP listener on
8080, the setup wizard at `/admin`, and no mail ports at all. They appear after the wizard.

```bash
cd /srv/stalwart
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz/live); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/admin/
curl -sS https://<DOMAIN>/login | grep -c '<title>Sign in</title>'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/account
```

You should see: the loop ending on `200`, then `200`, then `1`, then `401`.

If you do not: a `502` from the loop means Caddy is reaching nothing, so check step 4 and
`docker compose logs --tail 40 stalwart`. A `404` on `/admin/` while `/healthz/live` answers
`200` is a different problem entirely: the web interface is a bundle the server downloads from
GitHub the first time it starts, and both `/admin` and `/account` answer `404` until that
download succeeds, so the fix is outbound HTTPS from the box, not anything in this prompt. The
`1` is the sign-in page rendering from a template compiled into the binary. The `401` is the
admin API refusing a request that carries no credentials, and it is the one line here with
security meaning: if it prints `200`, stop and work out why before going further.

Now open https://<DOMAIN>/admin in a browser and sign in as `admin`, with the password from
`sudo grep STALWART_RECOVERY_ADMIN /srv/stalwart/.env` (the part after the colon). Finish the
setup wizard, leaving the hostname and the default domain as they are filled in and leaving
DKIM key generation on. The wizard shows you the password for the permanent administrator
account exactly once. Put it in your password manager before you click away, because there is
no second chance to read it.

Back in the shell, restart so the mail listeners come up, then shut the bootstrap door behind
you: that recovery credential is honoured on every sign-in for as long as it sits in the
environment, so it does not belong there now that a real administrator exists.

```bash
sudo test -s /srv/stalwart/etc/config.json && echo "config written"
docker compose restart
sleep 20
ss -ltn | grep -E ':(25|465|993) '
RECOVERY=$(grep '^STALWART_RECOVERY_ADMIN=' /srv/stalwart/.env | cut -d= -f2-)
sed -i '/^STALWART_RECOVERY_ADMIN=/d' /srv/stalwart/.env
docker compose up -d --force-recreate
sleep 20
printf 'user = "%s"\n' "$RECOVERY" | curl -sS -K - -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/account
unset RECOVERY
```

You should see: `config written`, three listening lines for 25, 465 and 993, and `401` on the
last line.

If you do not: no `config written` means the wizard did not finish, and nothing below this will
work until it does. Missing listeners mean the restart came too early, so wait and re-run the
`ss` line. That last `401` is the assert that matters: it replays the exact credential that
worked ten minutes ago and is refused, which is the evidence the bootstrap door is shut. The
credential travels in curl's configuration on stdin rather than on the command line, so it
never appears in the process table. If it prints `200`, the recreate did not pick up the edited
file: run `docker compose up -d --force-recreate` again and repeat the curl.

Two things are left, and both are done in the admin UI. First, DNS. Open the domain the wizard
configured and copy the record set the page lists: the MX record pointing at `<DOMAIN>`, the
SPF TXT record, the DKIM TXT record and a DMARC TXT record. DKIM is the one you cannot write
yourself, because it carries a public key that exists only on this server. Paste them into your
DNS provider's control panel. Second, the certificate on the mail ports. Caddy owns port 443 on
this box, so the TLS-ALPN-01 challenge the wizard picked cannot work, and its default
certificate order also reaches for names like `autoconfig.` and `mta-sts.` that do not exist
yet. Open the ACME provider the wizard created, change its challenge type to HTTP-01, then open
the domain and set the certificate's subject alternative names to `<DOMAIN>` and nothing else.
While you are in there, turn on `useXForwarded` in the HTTP settings, so a failed login is
counted against the address it came from rather than against Caddy.

```bash
DOM=$(echo "<DOMAIN>" | cut -d. -f2-)
dig +short MX "$DOM"
dig +short TXT "$DOM"
dig +short TXT "_dmarc.$DOM"
dig +short -x $(dig +short <DOMAIN> | tail -1)
sleep 120
openssl s_client -connect <DOMAIN>:465 -servername <DOMAIN> -verify_return_error </dev/null 2>&1 | grep -E 'Verify return code|issuer='
```

You should see: an MX answer naming `<DOMAIN>`, a TXT answer containing `v=spf1`, a DMARC
answer containing `v=DMARC1`, a PTR answer reading `<DOMAIN>.`, and a last line reading
`Verify return code: 0 (ok)`.

If you do not: DNS propagation runs in hours rather than minutes, so an empty answer a few
minutes after publishing is normal and the fix is to wait and re-run rather than to change
anything. DKIM sits under a selector the wizard chose, so check that one with the exact name
the admin UI printed rather than guessing. Anything other than `0 (ok)` on the last line means
Stalwart is still presenting the self-signed certificate it falls back to when it has none, and
every mail client will refuse to connect: the reason is in
`docker compose logs --tail 60 stalwart` under the ACME events, and it is usually a subject
alternative name that still lists a hostname with no DNS behind it.

## 8. First backup and restore

```bash
cd /srv/stalwart
docker compose stop
sudo tar -czf /srv/stalwart/backups/stalwart-$(date +%F).tar.gz -C /srv/stalwart compose.yml .env etc data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/stalwart/backups/
```

You should see: one `.tar.gz` with a non-zero size.

If you do not: the container is stopped on purpose and it matters. RocksDB is a set of files
under constant write, and one tarred mid-write restores as a corrupt database rather than as a
mailbox. Downtime is under a minute, and mail that arrives during it is retried by the sending
server, which is what SMTP does. Now copy the archive off the box, from your own machine rather
than from the server:

```bash
mkdir -p ~/backups/stalwart
scp vps:/srv/stalwart/backups/*.tar.gz ~/backups/stalwart/
```

A backup on the same disk as the data is not a backup. To restore onto a fresh box: run steps 1
to 6 so the directories, the Caddy block and the firewall exist, do not start the container,
then `sudo tar -xzf <archive> -C /srv/stalwart compose.yml .env etc data`, then
`sudo chown -R 2000:2000 /srv/stalwart/etc /srv/stalwart/data`, then `docker compose up -d`.
The `.env` has to be back before the first start, and `etc/config.json` has to be back too, or
the server comes up in bootstrap mode and offers the setup wizard to whoever finds it first.
`data/` is every message anyone has ever sent you.

## 9. Updating later

New versions are listed at https://github.com/stalwartlabs/stalwart/releases and reach Docker
Hub under the same tag string, and https://github.com/stalwartlabs/stalwart/tree/main/UPGRADING
carries a note per version. Take a backup first, then edit the image line in
/srv/stalwart/compose.yml to the new tag and its digest:

```bash
cd /srv/stalwart
docker compose pull
docker compose up -d
docker compose logs --tail 40 stalwart
```

You should see: the new version starting, and no error about a database schema.

If you do not: Stalwart migrates its own database on the way up and refuses to start rather
than run against a schema it does not recognise, which is the correct behaviour and the reason
the backup comes first. Re-run the four checks from step 7 before calling the update done. The
web interface updates on its own schedule, separately from the server, because it is a bundle
the server re-downloads from GitHub.

## 10. What will probably go wrong

Your mail will land in spam folders, and nothing in this prompt fixes that on the day you run
it. I had MX, SPF, DKIM, DMARC and a matching PTR record all correct, and the first message I
sent to a large provider went to the junk folder anyway. That is not a misconfiguration, it is
the system working: this IP address has no sending history, and that history is the product the
provider you are leaving actually sells you. It is earned over weeks, by sending small volumes
of mail that people open and reply to, from an address whose DNS has stopped changing. The
failure mode to watch for is impatience: importing ten years of archives and sending a
newsletter in week one is how a fresh address gets itself blocklisted. Send to yourself, then
to a friend, then to a colleague, and read a DMARC aggregate report before you move anything
that matters.

## 11. Out of scope

- Do not configure an external directory, LDAP or OpenID Connect in the wizard. The internal
  directory is what creates the administrator account this prompt depends on, and choosing
  another skips that step entirely.
- Do not enable the POP3, ManageSieve, plain IMAP or 587 listeners, and do not publish their
  ports. Upstream's own advice is to run the ports you use and no others.
- Do not install a webmail client. Stalwart serves JMAP, IMAP, CalDAV and CardDAV, and a client
  is a separate application on its own hostname with its own install.
- Do not turn on the enterprise features in the admin UI. They need a license key from Stalwart
  Labs, and this is the community build.
