<!-- DRAFT — not yet style-guide compliant, not verified -->

<!--
  First-pass install prompt for Claude Code. It has not been through
  docs/prompt-style-guide.md and it has not been run end-to-end on a clean
  machine, so nothing on the page claims it has. Phase 1 rewrites this to the
  style guide and the harness earns (or refuses) the stamp.
-->

Install Vaultwarden on my VPS behind Caddy, with TLS, and prove it works before you tell me it does.

**What you can assume.** Prompt Zero is done: `ssh vps` works from this machine, the server is Ubuntu 24.04 with Docker and the compose plugin installed, and my user is in the `docker` group. I own the domain and I have already pointed an A record for the hostname below at the server's IP.

**Ask me for these two things first, then stop asking me things:**

- the hostname, e.g. `vault.example.com`
- an email address for Let's Encrypt expiry warnings

**Do it in this order.**

1. Confirm the hostname resolves to this server before touching anything else. If it does not, stop and tell me — a certificate request against a hostname that does not resolve burns a Let's Encrypt rate-limit slot.
2. Create `/srv/vaultwarden/` with a `data/` directory inside it. Everything for this app lives under that one path.
3. Write `/srv/vaultwarden/compose.yml` with two services and no host ports on the app:
   - `vaultwarden` — image `vaultwarden/server:1.37.1-alpine`, `restart: unless-stopped`, volume `./data:/data`, environment `DOMAIN`, `SIGNUPS_ALLOWED=false`, `ADMIN_TOKEN`. No `ports:` block at all.
   - `caddy` — image `caddy:2.11.4-alpine`, publishing `80:80`, `443:443` and `443:443/udp`, mounting `./Caddyfile` read-only, with named volumes for `/data` and `/config`.
4. Write `/srv/vaultwarden/Caddyfile` that serves the hostname, sets the ACME email from the environment, and reverse-proxies to `vaultwarden:80` with `header_up X-Real-IP {remote_host}`. Add HSTS, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`.
5. Generate the admin passphrase **on the server**, never in this conversation: `openssl rand -base64 33`. Hash it with Vaultwarden's own generator by piping the passphrase twice into `docker run --rm -i vaultwarden/server:1.37.1-alpine /vaultwarden hash --preset owasp`, and keep the `$argon2id$...` line.
6. Write `/srv/vaultwarden/.env` with mode 600 containing `DOMAIN`, `DOMAIN_HOST`, `ACME_EMAIL` and `ADMIN_TOKEN`. **Escape every `$` in the Argon2 hash as `$$`** before writing it — docker compose expands `$` inside `.env` values and will silently mangle the hash otherwise. This is the step people get wrong.
7. Open only 80/tcp, 443/tcp and 443/udp on the firewall. Leave everything else closed.
8. `docker compose pull && docker compose up -d`, then poll `https://<hostname>/` until it returns HTTP 200. Show me the first screen: it should say **"Create account"** on the Vaultwarden login page. If it does not return 200 within about two minutes, show me `docker compose logs caddy` and stop.
9. Take the first backup before you finish: stop the `vaultwarden` service, `tar -czf` the `data/` directory and `.env` into `~/backups/vaultwarden/`, start it again. Tell me plainly that a backup on the same machine is not a backup.
10. Print the path to the file holding my admin passphrase and tell me to move it into the vault and delete it.

**Do not:** put any secret in your replies to me, enable signups, expose the app on a host port, use a `:latest` tag, install anything with a piped shell script, or configure SMTP — this install does not need mail, and the page says so.

**When you are done, tell me in three lines:** the URL, where the backup went, and what I still have to do myself (create the account, point the Bitwarden apps at the server, move the passphrase).
