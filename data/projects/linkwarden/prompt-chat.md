This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Linkwarden 2.16.0 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over
`ssh vps` unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A
record already points at the box. This one is two containers and two secrets, so set aside
an evening rather than a coffee break.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `20` G free, `amd64` or `arm64`,
and your server's IP on the last line.

If you do not: stop here rather than continuing on a smaller box. Preserving a page runs a
headless Chromium, and each saved link can leave a screenshot, a PDF and a single-file
HTML copy behind. On a 1 GB machine the install works and then the OOM killer takes the
archiver out in the middle of your first import, which looks random and is not. An empty
last line means the A record does not exist yet: add it, wait a minute, run
`dig +short <DOMAIN>` again.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/linkwarden /srv/linkwarden/backups /srv/linkwarden/data
sudo install -d -m 700 /srv/linkwarden/postgres
ls -la /srv/linkwarden
```

You should see: `backups`, `data` and `postgres`, with `postgres` at mode `drwx------` and
owned by root.

If you do not: leave `postgres` owned by root on purpose. The PostgreSQL image chowns its
own data directory the first time it starts, and a directory you have already chowned to
yourself makes it refuse with a message about ownership that mentions nothing helpful.

## 3. Secrets

Two secrets: the PostgreSQL password and the NextAuth signing secret. Both are generated
here, on the server, and both go straight into a file only you can read. Hex rather than
base64, because the database password ends up inside a connection URL where the base64
alphabet would need escaping.

```bash
umask 077
cat > /srv/linkwarden/.env <<EOF
NEXTAUTH_URL=https://<DOMAIN>/api/v1/auth
NEXT_PUBLIC_DISABLE_REGISTRATION=false
NEXTAUTH_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/linkwarden/.env
umask 022
ls -l /srv/linkwarden/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Read both values
once with `sudo grep -E 'POSTGRES_PASSWORD|NEXTAUTH_SECRET' /srv/linkwarden/.env` and put
them in your password manager.

If you do not: replace `<DOMAIN>` in the first line with your real hostname before you
paste, and keep the `/api/v1/auth` suffix exactly as it is. Upstream documents that suffix
as a requirement, and login fails in a way that looks like a wrong password if it is
missing.

Do not paste the contents of that file, either secret, or any command output containing
them into this chat window. Nothing in the rest of this guide needs them, and once they
are in a transcript they are somebody else's copy.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/linkwarden/compose.yml <<'EOF'
# Linkwarden · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   setup and env vars . https://docs.linkwarden.app/self-hosting/setup
#   variable reference . https://docs.linkwarden.app/self-hosting/environment-variables
#   reverse proxy ...... https://docs.linkwarden.app/self-hosting/reverse-proxy
#
# Two services: the app, and the PostgreSQL it needs. MeiliSearch is deliberately
# absent, because Linkwarden only starts its search client when MEILI_MASTER_KEY
# is set, so leaving it out costs a container and a secret. Tags and digests were
# read from the registries on 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: linkwarden-db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - /srv/linkwarden/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  linkwarden:
    image: ghcr.io/linkwarden/linkwarden:v2.16.0@sha256:d805877fb707d160b809027c302f84cfba11a248d7fdc12de90b4791f98e6b55
    container_name: linkwarden
    restart: unless-stopped
    env_file: /srv/linkwarden/.env
    environment:
      # Built here, not in .env: compose expands ${...} in this file.
      DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
    volumes:
      # Archives, screenshots, PDFs, uploads. STORAGE_FOLDER defaults to `data`
      # and the image's working directory is /data, hence /data/data.
      - /srv/linkwarden/data:/data/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8085.
      - "127.0.0.1:8085:3000"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/linkwarden && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/linkwarden/.env not found` means step 3 did not write the
file. `services must be a mapping` means the indentation was lost between the page and
your terminal: run `rm /srv/linkwarden/compose.yml` and paste the block again in one go.
Note what is not in this file: MeiliSearch. Linkwarden only starts its search client when
`MEILI_MASTER_KEY` is set, so leaving it out costs a container and a secret rather than
breaking anything.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>`
in the block with your hostname before you paste. The first line takes a copy, because a
syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-linkwarden
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Linkwarden · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.linkwarden.app/self-hosting/reverse-proxy and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. Upstream documents nginx
# only, and every forwarding header their example sets by hand is one Caddy sets
# on its own, which is why there is no header_up line below.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8085 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8085
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-linkwarden /etc/caddy/Caddyfile`,
reload, and paste again. Upstream's reverse proxy page documents nginx and sets four
forwarding headers by hand; Caddy sets all of them itself, which is why there is nothing
like that below the `reverse_proxy` line.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8085` or `5432`.

If you do not: delete anything for `8085` or `5432` with `sudo ufw delete allow 8085`.
8085 is bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the
database has no host port that a firewall rule could even apply to. 80/tcp redirects to
HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3.

## 7. Start and verify

The first boot is slow. Prisma applies the whole database schema before the app answers
anything, so expect a 502 for the first few minutes.

```bash
cd /srv/linkwarden
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL https://<DOMAIN>/ | grep -ci 'linkwarden'
```

You should see: the loop printing `502` a few times and then `200`, and the second command
printing a number greater than `0`.

If you do not: if the loop runs the whole ten minutes, look at both containers rather than
guessing. `docker compose ps` should show `linkwarden-db` as `healthy`; if it is not, that
is step 2, and `docker compose logs --tail 20 postgres` will say so in one line about
ownership. If the database is healthy and the answer is still 502, run
`docker compose logs -f linkwarden` and watch: if migration lines are moving, wait. A
container listed in `docker ps` is not proof of anything.

Now open https://<DOMAIN> in a browser. The first screen is a login form with fields for a
username and a password, and a link to create an account. Open https://<DOMAIN>/register
and create your account now, because registration is open until you close it in the next
command and this is the one window in the install a stranger could walk into.

Once you can sign in, close registration. A restart is not enough here: upstream documents
that the containers have to be recreated for a changed `.env` to take effect.

```bash
cd /srv/linkwarden
sed -i 's/^NEXT_PUBLIC_DISABLE_REGISTRATION=false$/NEXT_PUBLIC_DISABLE_REGISTRATION=true/' /srv/linkwarden/.env
grep NEXT_PUBLIC_DISABLE_REGISTRATION /srv/linkwarden/.env
docker compose down
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
```

You should see: `NEXT_PUBLIC_DISABLE_REGISTRATION=true` from the grep, then the loop
reaching `200` again. Then sign out, try to create a second account at
https://<DOMAIN>/register, and confirm it is refused.

If you do not: a second account that still succeeds means `docker compose down` did not
actually run, so check `grep` printed `true` and run
`docker compose down && docker compose up -d` again. Do not leave this step half done.
Registration on a bookmark server that anyone can find is an invitation.

## 8. First backup and restore

Two artifacts, because there are two kinds of state. The database holds the links, the
tags and your account. The data directory holds the archived copies, which no database
dump contains.

```bash
cd /srv/linkwarden
docker compose exec -T postgres pg_dump -U postgres -d postgres | gzip > /srv/linkwarden/backups/linkwarden-db-$(date +%F).sql.gz
sudo tar -C /srv/linkwarden -czf /srv/linkwarden/backups/linkwarden-files-$(date +%F).tar.gz data .env
ls -lh /srv/linkwarden/backups/
```

You should see: two files, the `.sql.gz` a few kilobytes on a fresh install and the
`.tar.gz` similar. Nothing goes offline: `pg_dump` snapshots a running database
consistently, which is exactly why the database is dumped rather than copied off disk.

If you do not: a `.sql.gz` of 20 bytes is an empty dump, which means `pg_dump` failed and
the shell still created the file. Run the dump line without the `| gzip` part to read the
error.

A backup on the same disk as the data is not a backup. Run this one on your own machine,
not on the server:

```bash
mkdir -p ~/backups/linkwarden
scp vps:/srv/linkwarden/backups/* ~/backups/linkwarden/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/linkwarden/`.

If you do not: `Permission denied (publickey)` means you ran it on the server by mistake.
The `vps:` prefix only means something on your own machine.

Now prove the restore, because a backup you have never restored is a guess. Do it today,
while the only thing at risk is a test account:

```bash
cd /srv/linkwarden
docker compose down
sudo rm -rf /srv/linkwarden/data /srv/linkwarden/postgres
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/linkwarden/data
sudo install -d -m 700 /srv/linkwarden/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/linkwarden/backups/linkwarden-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U postgres -d postgres
sudo tar -C /srv/linkwarden -xzf /srv/linkwarden/backups/linkwarden-files-$(date +%F).tar.gz
docker compose up -d
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then a login page where your
account still works.

If you do not: `role "postgres" does not exist` means the database container had not
finished initialising, so wait and run the `gunzip` line again. The dump alone gives you
your links with dead previews; the archive alone gives you files nothing points at. Both
or neither.

## 9. Updating later

New versions are listed at https://github.com/linkwarden/linkwarden/releases. Take both
backup artifacts first, then edit the `image:` line in /srv/linkwarden/compose.yml to the
new tag and its digest.

```bash
cd /srv/linkwarden
docker compose pull
docker compose up -d
docker compose logs --tail 30 linkwarden
```

You should see: migration lines, then the app starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. A database
that has been migrated by a newer version will not load into an older image, which is why
the backup goes first rather than second.

## 10. What will probably go wrong

The first four minutes. `docker compose up -d` returned straight away, both containers
showed as running, and the hostname answered 502 for long enough that I reached for the
rollback. Nothing was broken: Prisma was applying the schema, and the app answers nothing
until that finishes. The tell is `docker compose logs -f linkwarden`, where the migration
lines visibly progress. If the log is moving, wait. If it has been silent for two minutes
and you are still getting a 502, look at the database container instead.

## 11. Out of scope

- Do not add MeiliSearch. It is a third container and a third secret, and search over the
  text of archived pages is not what this install gives you.
- Do not configure SMTP. Email verification and password reset stay off, which is
  survivable when you are the only account.
- Do not wire up an SSO or OAuth provider. Credentials login is on, and it is the only
  path here.
- Do not set an AI tagging key. Automatic tagging sends page text to a third party, and
  that is a decision to make on purpose later.
