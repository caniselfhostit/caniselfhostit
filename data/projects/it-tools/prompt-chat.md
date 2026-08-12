This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing IT Tools 2024.10.22-7ca5933 on a VPS where Prompt Zero is done: `ssh vps`
works, Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record
already points at the box.

Read these before step 1. This produces a public utility page: no login, no account, no first-run
wizard, and every tool is usable by anyone who loads the URL. That is intentional. Caddy
`basic_auth` is the opt-in if you want a password in front; this install does not enable it.
There is no application data directory. The pinned tag was published 2024-10-22 (about 21 months
before the 2026-08-07 digest check); upstream cadence is slow, and `nightly` is not this pin.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `256` MB available, at least `2` G free, `amd64` or `arm64`, and your
server's IP. If dig is empty, add the A record and wait.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/it-tools /srv/it-tools/backups
ls -la /srv/it-tools
```

You should see `backups` under `/srv/it-tools`. There is no `data/` directory: the container is a
stateless static UI. Bookmarks live in the browser if at all.

## 3. Secrets

No secret is generated and there is no `.env` file. There is no claim race because there is
nothing to claim. If you want a password on the URL later, use Caddy `basic_auth` with
`caddy hash-password`, then validate and reload. Do not invent a first-run setup step for
software that has none.

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

You should see `compose OK`. One service, no volumes, no env_file. Do not add a Caddy service
here. Upstream's docs show `docker run` lines; this compose is our deterministic wrapper around
that image (officialCompose: none; upstream publishes no compose stack).

## 5. Caddy and TLS

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

Set `DOMAIN_HOST` to your real hostname before sed. `caddy validate` and reload must both exit
0. If validate fails, restore `/etc/caddy/Caddyfile.before-it-tools`, reload, and fix the syntax.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see Status active, 80 and 443 open, nothing for 8209. 8209 stays closed because
compose binds it to 127.0.0.1.

## 7. Start and verify

```bash
cd /srv/it-tools
docker compose pull
docker compose up -d
for i in $(seq 1 24); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 5; done
curl -sSL https://<DOMAIN>/ | grep -ciE 'it-tools|IT Tools|token|encode|hash|Base64'
docker compose ps
```

You should see the loop end with `200` and a body grep count greater than `0`. If you get 502,
re-check step 5. There is no sign-in to complete and no wizard to finish. The security posture is
consent to publication, not a closed account door.

STOP: open https://<DOMAIN> in a private window, try one tool (for example Base64 encode), and
confirm two things: the page loads without a login, and you are content for anyone who can reach
the hostname to use the same tools. Do not continue until they confirm.

## 8. First backup and restore

Nearly stateless. Archive compose.yml and the live Caddyfile only. Do not invent an empty
`data/` directory to tar.

```bash
cd /srv/it-tools
sudo tar -czf /srv/it-tools/backups/it-tools-$(date +%F).tar.gz \
  -C /srv/it-tools compose.yml \
  -C /etc/caddy Caddyfile
ls -lh /srv/it-tools/backups/
```

The archive must exist and be non-empty; print its size. No need to stop the container. From your
laptop:

```bash
mkdir -p ~/backups/it-tools
scp vps:/srv/it-tools/backups/*.tar.gz ~/backups/it-tools/
```

To restore: put compose back under `/srv/it-tools`, put the Caddy block back if needed,
`docker compose up -d`. There is no user content on the server to lose. Browser form history is
not part of this backup.

## 9. Updating later

Releases: https://github.com/CorentinTh/it-tools/releases. **This pin is old until you move it:**
tag `2024.10.22-7ca5933` was published 2024-10-22, about 21 months before the 2026-08-07 check.
Docker Hub also has `nightly`; do not float to nightly from this path. When a newer stable tag
exists that you trust, backup compose and Caddy, edit the image line to the new tag and digest:

```bash
cd /srv/it-tools
docker compose pull
docker compose up -d
docker compose logs --tail 20 it-tools
```

Re-run step 7's curl and body grep. Treat upgrades like any dependency that will see secrets
users paste into forms.

## 10. What will probably go wrong

You will paste a production secret into a tool on this host, share the hostname in a chat, and
later wonder who else used the same URL. Client-side execution beats a random website; a public
hostname without basic_auth is still public. Second: assuming the pin is current because the
container is healthy. Check releases before you need a fix that only exists upstream. Third: a
corporate content filter that blocks tool paths on your own domain; fix the filter, not the
image pin.

## 11. Out of scope

- Do not add a Caddy container to compose. Caddy already runs under systemd on this host.
- Do not publish 8209 on `0.0.0.0` or open it in the firewall.
- Do not invent accounts, a first-run wizard, or a claim-race warning for software that has none.
- Do not add basic_auth unless you explicitly decide after the public-by-design consent stop.
- Do not switch the image to `latest` or `nightly` without a deliberate pin decision.

Honesty about Raycast: this install replaces the habit of pasting into random web utilities. It
does not replace a launcher, clipboard history, window management or an extension host. If you
came from a Raycast Pro comparison, keep that distinction clear.

Hostname discipline: the Caddy site name and the browser URL must match. Publication discipline:
private-window the page once as a stranger. State discipline: there is almost no state; do not
fake a data volume. Pin discipline: record the next digest when you move off 2024.10.22-7ca5933.

If a step's assert fails, name the earlier step before changing anything else. Preflight is step
1. Compose errors are step 4. Certificate or 502 problems are step 5. Open ports that should be
closed are step 6. A 200 with a blank or wrong body is step 4 or 7. Empty backups are step 8.

NOT YET VERIFIED: no harness run has been recorded against this install path.


Client-side trust model: most tools transform text in the browser. That means the server you
just installed is mainly a delivery vehicle for JavaScript. Self-hosting still matters because
you control which JS bundle runs and who can reach it, but it is not a magical air gap. Keep the
image pin intentional, and prefer basic_auth or a private hostname when the tools will see
employer secrets.

What this does not replace: a password manager, a notes app, a snippet sync service, or Raycast
as a launcher. If a comparison page ranked IT Tools against Raycast Pro, the honest overlap is
only the "open a web utility" habit. Keep paying for a launcher if that is the job you hired
Raycast for.

Operational rhythm: after install, open the page once a week for a month so the bookmark sticks.
If you never open it, turn the container off and reclaim the RAM. If you open it daily, consider
basic_auth or a long random subdomain so search engines and curious scanners are less likely to
find a toolbox full of crypto toys on your domain.

Caddy basic_auth sketch (opt-in only, not part of this install unless you ask for it after the
consent stop):

  # generate a hash on the server
  caddy hash-password
  # then inside the site block, before reverse_proxy:
  # basic_auth {
  #   <username> <hash>
  # }

Validate and reload after any Caddy edit. A syntax error takes down every site on the box, which
is why step 5 copies the live file first.

When curl prints 000 or times out, check DNS, ufw, and `docker compose ps` in that order. When
curl prints 502, check that 8209 is listening on 127.0.0.1 and that Caddy's reverse_proxy target
matches. When curl prints 200 but the body grep is zero, you may be hitting a different service
on the same hostname; inspect the Caddyfile for duplicate site blocks.

Keep the off-box copy of the compose+Caddy archive if you care about recovering the pin and the
hostname wiring. The tools themselves are the image: a `docker compose pull` of the same pin
recreates the UI without restore.

This path is NOT YET VERIFIED on a clean harness machine; treat the asserts as the contract and
stop when they fail.


Mobile browsers will load the same UI if the hostname is public. That is convenient for a phone
on LTE and also means a pocket device is one link away from the same toolbox. If that is too
broad, basic_auth or VPN-only access is the fix, not hoping nobody bookmarks the URL.

Logging: the container logs little about what users paste, which is good. Your reverse proxy
access logs still record who hit the hostname. If access logs are a problem for your threat
model, tighten log retention on the host Caddy, not inside this compose file.

Disk: the image layer is the main disk cost. The backup archive is tiny. Do not allocate a large
volume "just in case"; there is no growing database here.

IPv6: if the AAAA record points somewhere else, browsers may hit the wrong box. Keep DNS boring:
one A record to this VPS unless you know you want dual-stack.

Finally, re-read the consent stop after any change that makes the hostname easier to guess
(short vanity names, public docs that advertise the tools URL). Public by design is a choice you
can reverse with basic_auth; it is harder to reverse a secret that already left the browser.
