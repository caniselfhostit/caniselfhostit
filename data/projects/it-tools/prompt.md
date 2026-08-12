You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install IT Tools 2024.10.22-7ca5933 on that server, reachable at https://<DOMAIN>, behind the
existing Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say two things when you ask. One: this produces
a public utility page. There is no login, no account and no first-run wizard, and every tool on
the page is usable by anyone who loads the URL. Two: that is intentional (same posture as a
public status page), and Caddy `basic_auth` is the documented opt-in if they would rather put a
password in front; this install does not enable it.

IT Tools needs 256 MB of RAM available and 2 GB free on /srv. The image is a static web UI and
costs almost nothing at idle. The pinned tag publishes amd64 and arm64. Measure:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 256 MB or free disk is under 2 GB, print both numbers and stop. Do not
install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify a
hostname that does not resolve.

Also say once: the pinned image tag `2024.10.22-7ca5933` was published on 2024-10-22, about 21
months before the 2026-08-07 check that recorded this pin. Upstream release cadence is slow; a
`nightly` tag exists on Docker Hub and is not what this install uses. Block 9 covers how to move
forward when a newer stable identity appears.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/it-tools /srv/it-tools/backups
ls -la /srv/it-tools
```

Assert: `ls -la` shows `backups` owned by the login user. There is no `data/` directory and that
is not an omission: the container serves a static UI, writes no application database, and keeps
no server-side accounts. Bookmarks and "recent tools" live in the browser if at all.

## 3. Secrets

No secret is generated for this install and there is no `.env` file. That is not an oversight,
and there is no default credential for step 7 to close: IT Tools ships no account, no
registration form and no administration screen. There is no claim race, because there is nothing
to claim.

What replaces the credential question here is publication. The page answers everybody, because
that is what a shared utility chest on a URL is for. Tell the user this: if they would rather
the page were behind a password, Caddy's `basic_auth` directive on the site block does that, this
install uses neither basic_auth nor an upstream login, and turning basic_auth on is a decision
about who the page is for. Do not invent a first-run setup step.

## 4. compose.yml

```bash
cat > /srv/it-tools/compose.yml <<'EOF'
# IT Tools · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker run ......... https://github.com/CorentinTh/it-tools#self-host
#
# One service. Static web UI served by the image; no application database, no
# accounts, no env secrets. Upstream publishes docker run lines rather than a
# maintained multi-service compose file (officialCompose: none).
# Tag 2024.10.22-7ca5933 was published 2024-10-22; digest read from Docker Hub
# on 2026-08-07. See block 9 of the prompts for the age of this pin.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  it-tools:
    image: corentinth/it-tools:2024.10.22-7ca5933@sha256:8b8128748339583ca951af03dfe02a9a4d7363f61a216226fc28030731a5a61f
    container_name: it-tools
    restart: unless-stopped
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8209.
      - "127.0.0.1:8209:80"
EOF
cd /srv/it-tools && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, one published port, no volumes, no env_file. Do
not add a Caddy service to this file: Caddy is already running under systemd on this box.

## 5. Caddy and TLS

Write the site block under `/srv/it-tools/Caddyfile`, then append it to the live Caddyfile with
`<DOMAIN>` replaced. Copy the live file first: a syntax error here takes down every other site
on the box.

```bash
cat > /srv/it-tools/Caddyfile <<'EOF'
# IT Tools · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Everything served here
# is public by design: there are no accounts. Caddy basic_auth is an opt-in if
# you would rather the URL not be world-readable.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8209 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8209
}
EOF
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-it-tools
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
DOMAIN_HOST=<DOMAIN>
sed "s|<DOMAIN>|${DOMAIN_HOST}|g" /srv/it-tools/Caddyfile | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Set `DOMAIN_HOST` to the real hostname from step 1 before running `sed`. Assert: `caddy validate`
exits 0 and the reload exits 0. If validate fails, restore
`/etc/caddy/Caddyfile.before-it-tools`, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own.

If the user later wants a password on the URL, the opt-in is a `basic_auth` directive inside the
site block (Caddy docs), with a hash generated by `caddy hash-password`, then validate and
reload. Do not add that unless they ask after understanding the page is public today.

## 6. Firewall

Two ports open, both Caddy's:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8209 stays closed because compose binds it to 127.0.0.1. Assert: `ufw status verbose`
prints `Status: active`, shows 80, 443/tcp and 443/udp, and no rule mentioning 8209.

## 7. Start and verify

```bash
cd /srv/it-tools
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sSL https://<DOMAIN>/ | grep -ciE 'it-tools|IT Tools|token|encode|hash|Base64'
docker compose ps
```

Assert all of the following, and print what you received. The loop ends printing `200`. The
grep count is greater than `0` because the UI names tools or the product. If Caddy returns 502
with a running container, step 5 is the likely cause. A running container is not success.

There is no sign-in to complete and no wizard to finish. The security posture here is consent to
publication, not a closed door.

STOP: tell the user to open https://<DOMAIN> in a private window, try one tool (for example a
Base64 encode of a short string), and confirm two things back to you: that the page loads
without a login, and that they are content for anyone who can guess or learn the hostname to use
the same tools, because that is now true. Do not continue until they confirm.

## 8. First backup and restore

This install is nearly stateless. The archive is the compose file and the live Caddy site block.
There is no application `data/` directory to include, and inventing one would back up empty
space. Say that plainly to the user.

```bash
cd /srv/it-tools
sudo tar -czf /srv/it-tools/backups/it-tools-$(date +%F).tar.gz \
  -C /srv/it-tools compose.yml \
  -C /etc/caddy Caddyfile
ls -lh /srv/it-tools/backups/
```

Assert: the archive exists and is non-empty. Print its size. There is no need to stop the
container for this backup: nothing under `/srv/it-tools` is being written by the app. Never
append `|| true` to this tar.

From the user's machine:

```bash
mkdir -p ~/backups/it-tools
scp vps:/srv/it-tools/backups/*.tar.gz ~/backups/it-tools/
```

To restore: put `compose.yml` back under `/srv/it-tools`, put the Caddy block back if that is
what was lost, `docker compose up -d`. Losing the image pin costs a careful re-edit of compose;
losing the Caddy block costs the site name on this box. There is no user content on the server to
lose, which is the honest upside of a stateless UI.

## 9. Updating later

Releases: https://github.com/CorentinTh/it-tools/releases. The image tags follow the calver-style
identity upstream publishes (for example `2024.10.22-7ca5933`). **This pin is old on purpose
until a newer stable identity is verified:** the tag was published 2024-10-22, about 21 months
before the 2026-08-07 digest check. Docker Hub also carries `nightly`; do not float to nightly
from this prompt. When a newer release tag exists that you trust, take a backup of compose and
Caddy, edit the image line to the new tag and digest, then:

```bash
cd /srv/it-tools
docker compose pull
docker compose up -d
docker compose logs --tail 20 it-tools
```

Re-run step 7's curl and body grep before calling the update done. Because tools run in the
browser against the JS you just shipped, treat upgrades like any dependency that will see secrets
users paste into forms.

## 10. What will probably go wrong

You will paste a production secret into a tool on this host, close the tab, and later wonder who
else loaded the same URL. The tools are client-side, which is why self-hosting beats a random
website, but the hostname is still public without basic_auth. I treated it like a private lab
once and shared the link in a chat; the fix was either basic_auth or a hostname nobody else had.
The second failure mode is assuming the pin is "current" because the container is healthy: the
tag can be more than a year old and still run fine. Check releases before you need a fix that
only exists upstream.

## 11. Out of scope

- Do not add a Caddy container to the compose file. Caddy already runs under systemd on this box.
- Do not publish 8209 on `0.0.0.0` or open it in the firewall.
- Do not invent accounts, a first-run wizard, or a claim-race warning for software that has none.
- Do not add basic_auth unless the user explicitly asks after the public-by-design consent stop.
- Do not switch the image to `latest` or `nightly` without a deliberate pin decision.
