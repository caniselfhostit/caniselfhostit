You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Stalwart 0.16.17 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS, serving mail on ports 25, 465 and 993.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
`<DOMAIN>` is the mail host, `mail.example.com` rather than `example.com`, one label in front of
the domain their addresses live at. It is the SMTP EHLO name, the name on the 993 certificate,
and the name reverse DNS must match.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
dig +short -x $(dig +short <DOMAIN> | tail -1)
timeout 10 bash -c 'exec 3<>/dev/tcp/aspmx.l.google.com/25' && echo "outbound 25 OPEN" || echo "outbound 25 BLOCKED"
```

Stalwart needs 1024 MB of RAM available and 10 GB free on /srv: upstream calls 1 GB enough for
five to ten users, and the disk floor is mail, which only grows. The image publishes amd64 and
arm64. If RAM is under 1024 MB or disk under 10 GB, print both and stop; if the fourth command
prints nothing, stop. The fifth prints the PTR record, which has to read `<DOMAIN>.` exactly.
Only the hosting provider changes that, and step 7 stops on it.

Assert the last line prints `outbound 25 OPEN`. Most VPS providers block outbound 25, because
most abuse comes from rented boxes, and unblock it on request. A box that cannot open 25 outbound
receives mail and delivers none, which looks like a working install for a day.

STOP: if that printed `outbound 25 BLOCKED`, tell the user to ask their hosting provider to unblock outbound port 25 on this server, and wait. Do not continue until they confirm the command prints OPEN.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/stalwart /srv/stalwart/backups
sudo install -d -m 700 -o 2000 -g 2000 /srv/stalwart/etc /srv/stalwart/data /srv/stalwart/log
ls -la /srv/stalwart
```

Assert: `backups` owned by the login user, and `etc`, `data` and `log` at mode `700` owned by uid
`2000`, the uid the image runs as. `etc` holds `config.json`, `data` the RocksDB with every
message in it, `log` the wizard's default log path the image omits.

## 3. Secrets

One secret: the bootstrap administrator credential. Generate it on the server. Do not print it,
repeat it in your summary, or log it. Hex, not base64: Stalwart reads a leading `$`, `_` or `{`
here as a hash prefix.

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

Assert: mode `-rw-------`. Setting this before the first start is the point: left unset, Stalwart
generates its own bootstrap password and writes it to the container log in clear text, where
anyone who reads `docker compose logs` reads it. Step 7 deletes the line.

## 4. compose.yml

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

Assert: `compose OK` prints.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

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

Assert: `caddy validate` and the reload exit 0. If validate fails, restore
/etc/caddy/Caddyfile.before-stalwart, reload and report what it objected to. Caddy renews the web
certificate itself; the 465 and 993 one is separate, and step 7 finishes it.

## 6. Firewall

Six ports open, three of them the point of this page:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw allow 25/tcp
sudo ufw allow 465/tcp
sudo ufw allow 993/tcp
sudo ufw status verbose
```

80 and 443 are Caddy's, 25/tcp is how other mail servers reach this one, 465/tcp is where clients
submit under implicit TLS, which upstream recommends over 587, and 993/tcp is IMAP. 8189 stays
closed as loopback; 995, 4190, 143, 110 and 587 because compose publishes none.

Assert: `ufw status verbose` prints `Status: active`, lists those five, and shows no rule for
8189. Docker's iptables rules are read before ufw's, so compose `ports:` is control.

## 7. Start and verify

With no `config.json`, Stalwart starts in bootstrap mode: one plain HTTP listener on 8080, the
wizard at `/admin`, no mail ports.

```bash
cd /srv/stalwart
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthz/live); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/admin/
curl -sS https://<DOMAIN>/login | grep -c '<title>Sign in</title>'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/account
```

Assert all four; print what you received. The loop ends on `200`. `/admin/` prints `200`: the
web interface is a bundle fetched from GitHub on first start and answers `404` until that
succeeds, so this tests outbound HTTPS. The grep prints `1`, the sign-in page from a
template compiled into the binary. The last prints `401`, the admin API refusing an unauthorised
request. On any miss, stop and run `docker compose logs --tail 40 stalwart`: `502` is step 4;
`404` on `/admin/` with a healthy `/healthz/live` is egress.

STOP: tell the user to open https://<DOMAIN>/admin, sign in as `admin` with the value after the colon in `sudo grep STALWART_RECOVERY_ADMIN /srv/stalwart/.env`, and finish the wizard, leaving the hostname and default domain as filled in and DKIM generation on. The wizard shows the permanent administrator password once and never again. Do not continue until they confirm they saved it.

Restart to bring the mail listeners up, then shut the bootstrap door: that credential works on
every sign-in while it sits in the environment.

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

Assert: `config written` prints, `ss` lists all three ports, and the curl prints `401`. A missing
`config.json` means the wizard did not finish. That curl replays the credential that worked ten
minutes ago and is refused, which is the evidence the door is shut; it rides in curl's config on
stdin, so it never reaches the process table. A `200` means the recreate did not read the file.
A running container is not success.

Two things are left. DNS is what makes the mail authenticate, and DKIM is the record the user
cannot invent, because it carries a key that exists only here.

STOP: tell the user to set reverse DNS for this server's IP address to `<DOMAIN>` at their hosting provider, and to publish the records the admin UI lists on the domain's page: MX pointing at `<DOMAIN>`, SPF, DKIM and DMARC. Do not continue until they confirm the PTR record and all four DNS records.

Then the certificate on 465 and 993, which is Stalwart's own: Caddy owns 443, so the wizard's
TLS-ALPN-01 challenge cannot work, and its default order reaches for names like `autoconfig.`
that do not exist.

STOP: tell the user to set, in the admin UI, the ACME provider's challenge type to HTTP-01, the domain certificate's subject alternative names to `<DOMAIN>` alone, and `useXForwarded` on in the HTTP settings. Do not continue until they confirm all three are saved.

```bash
DOM=$(echo "<DOMAIN>" | cut -d. -f2-)
dig +short MX "$DOM"
dig +short TXT "$DOM"
dig +short TXT "_dmarc.$DOM"
dig +short -x $(dig +short <DOMAIN> | tail -1)
sleep 120
openssl s_client -connect <DOMAIN>:465 -servername <DOMAIN> -verify_return_error </dev/null 2>&1 | grep -E 'Verify return code|issuer='
```

Assert, printing every line: MX names `<DOMAIN>`, the TXT answer contains `v=spf1`, the DMARC
answer contains `v=DMARC1`, the PTR answer reads `<DOMAIN>.`, and the last reads
`Verify return code: 0 (ok)`. DKIM sits under a selector the wizard chose, so check it by the
name the admin UI printed. Propagation runs in hours: re-run before calling an empty answer a
failure. Anything but `0 (ok)` means the self-signed fallback is still there, every mail client
will refuse it, and the reason is in `docker compose logs --tail 60 stalwart`.

## 8. First backup and restore

One archive: the configuration, the RocksDB, `.env`, the live Caddyfile.

```bash
cd /srv/stalwart
docker compose stop
sudo tar -czf /srv/stalwart/backups/stalwart-$(date +%F).tar.gz -C /srv/stalwart compose.yml .env etc data -C /etc/caddy Caddyfile
docker compose start
ls -lh /srv/stalwart/backups/
```

Assert: the archive exists and is non-empty. Print its size. The container is stopped on purpose:
RocksDB is a set of files under active write, and one tarred mid-write restores as a corrupt
database, not a mailbox. Downtime is a minute, and senders retry.

A backup on the same disk is not a backup, so run this on the user's machine:

```bash
mkdir -p ~/backups/stalwart
scp vps:/srv/stalwart/backups/*.tar.gz ~/backups/stalwart/
```

To restore on a fresh box: run steps 1 to 6, do not start the container, then
`sudo tar -xzf <archive> -C /srv/stalwart compose.yml .env etc data`,
`sudo chown -R 2000:2000 /srv/stalwart/etc /srv/stalwart/data`, `docker compose up -d`. `.env`
must be back before the first start, and `etc/config.json` too or the server returns to bootstrap
mode and hands a stranger the wizard.

## 9. Updating later

New versions are at https://github.com/stalwartlabs/stalwart/releases and reach Docker Hub under
the same tag; https://github.com/stalwartlabs/stalwart/tree/main/UPGRADING has a note per version.
Back up, then edit the image line in /srv/stalwart/compose.yml:

```bash
cd /srv/stalwart
docker compose pull
docker compose up -d
docker compose logs --tail 40 stalwart
```

Stalwart migrates its own database on the way up and refuses to start rather than run against a
schema it does not recognise, so watch that log until it settles, then re-run step 7's four
checks. The web interface updates itself, being a GitHub bundle.


## 10. What will probably go wrong

Your mail will land in spam folders, and nothing in this prompt fixes that on the day you run
it. I had MX, SPF, DKIM, DMARC and a matching PTR record all correct, and the first message I
sent to a large provider went to the junk folder anyway. That is not a misconfiguration, it is
the system working: this IP address has no sending history, and that history is the product the
provider you are leaving actually sells. It is earned over weeks, by sending small volumes of
mail people open and reply to from an address whose DNS has stopped changing. The failure mode is
impatience: ten years of archives imported and a newsletter sent in week one is how a fresh
address gets blocklisted.


## 11. Out of scope

- Do not configure an external directory, LDAP or OIDC in the wizard. The internal directory is
  what creates the administrator account this prompt depends on.
- Do not enable the POP3, ManageSieve, plain IMAP or 587 listeners or publish their ports.
  Upstream's advice is to run the ports you use and no more.
- Do not install a webmail client; that is a separate application on its own hostname.
- Do not turn on the enterprise features; they need a key from Stalwart Labs.
