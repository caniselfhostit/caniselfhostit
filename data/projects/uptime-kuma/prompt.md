<!-- DRAFT — not yet style-guide compliant, not verified -->

<!--
  First-pass install prompt for Claude Code. It has not been through
  docs/prompt-style-guide.md and it has not been run end-to-end on a clean
  machine, so nothing on the page claims it has. Phase 1 rewrites this to the
  style guide and the harness earns (or refuses) the stamp.
-->

Install Uptime Kuma on my VPS behind Caddy, with TLS, and prove it works before you tell me it does.

**What you can assume.** Prompt Zero is done: `ssh vps` works from this machine, the server is Ubuntu 24.04 with Docker and the compose plugin installed, and my user is in the `docker` group. I own the domain and I have already pointed an A record for the hostname below at the server's IP.

**Ask me for these two things first, then stop asking me things:**

- the hostname, e.g. `status.example.com`
- an email address for Let's Encrypt expiry warnings

**Do it in this order.**

1. Confirm the hostname resolves to this server before touching anything else. If it does not, stop and tell me — a certificate request against a hostname that does not resolve burns a Let's Encrypt rate-limit slot.
2. Create `/srv/uptime-kuma/` with a `data/` directory inside it, on local disk. Uptime Kuma keeps its history in SQLite and needs real POSIX file locks; if `data/` ends up on a network mount the database corrupts silently, so check and tell me if this path is not local.
3. Write `/srv/uptime-kuma/compose.yml` with two services and no host ports on the app:
   - `uptime-kuma` — image `louislam/uptime-kuma:2.5.0`, `restart: unless-stopped`, volume `./data:/app/data`. No `ports:` block at all. Upstream's example publishes 3001 on the host; do not copy that, this machine has a public IP.
   - `caddy` — image `caddy:2.11.4-alpine`, publishing `80:80`, `443:443` and `443:443/udp`, mounting `./Caddyfile` read-only, with named volumes for `/data` and `/config`.
4. Write `/srv/uptime-kuma/Caddyfile` that serves the hostname, sets the ACME email from the environment, and reverse-proxies to `uptime-kuma:3001`. Do not add Upgrade/Connection headers by hand — Caddy negotiates the WebSocket upgrade itself, and hand-written headers are what break the live dashboard.
5. Write `/srv/uptime-kuma/.env` with mode 600 containing `DOMAIN_HOST` and `ACME_EMAIL`. There are no secrets to generate for this install; my admin account gets created in the browser.
6. Open only 80/tcp, 443/tcp and 443/udp on the firewall. Leave everything else closed.
7. `docker compose pull && docker compose up -d`, then poll `https://<hostname>/` until it returns HTTP 200. Show me the first screen: it should be the Uptime Kuma **"Create your admin account"** setup page. If it does not return 200 within about two minutes, show me `docker compose logs caddy` and stop.
8. Take the first backup before you finish: stop the `uptime-kuma` service, `tar -czf` the `data/` directory into `~/backups/uptime-kuma/`, start it again. Do the stop — a SQLite file copied mid-write is not a backup. Tell me plainly that a backup on the same machine is not a backup either.
9. Write me a one-line cron entry or systemd timer that repeats that stop-copy-start backup nightly, but do not install it — show it to me and let me decide.

**Do not:** create the admin account for me, expose the app on a host port, use a `:latest` tag, install anything with a piped shell script, or configure SMTP or any notification channel — I will pick those in the UI.

**When you are done, tell me in four lines:** the URL, that I must create the admin account right now before someone else does, where the backup went, and that this monitor cannot tell me when the machine it runs on is down.
