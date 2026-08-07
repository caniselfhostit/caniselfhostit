You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install XWiki 17.10.11 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the first person to open
that hostname after step 7 starts the containers becomes the wiki's administrator, because
upstream lets a guest run the setup wizard while the wiki has no registered user. This is not
an install to walk away from half-finished.

XWiki is Java. The image starts Tomcat with a 1024 MB heap and runs LibreOffice in the same
container for office import and export, with PostgreSQL beside it, so this install needs
3072 MB of RAM available and 10 GB free on /srv. Both images publish amd64 and arm64. Measure
all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 3072 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope: on a 2 GB box the failure arrives as an OOM kill mid-wizard rather than
as a message about memory. If `dig +short` prints nothing, print that and stop.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/xwiki /srv/xwiki/backups
sudo install -d -m 700 /srv/xwiki/postgres /srv/xwiki/data
ls -la /srv/xwiki
```

Assert: `ls -la` shows `backups` owned by the login user, and `postgres` and `data` both at
mode `drwx------` owned by root. Leave both alone: the PostgreSQL image chowns its own data
directory, and the XWiki container's Tomcat runs as root, so `data` fills with root-owned files
the moment step 7 runs. `data` is the permanent directory, holding the downloaded user
interface, the Solr index, the logs, and every file anybody attaches to a page.

## 3. Secrets

One secret: the PostgreSQL password. Generate it on the server, do not print it, do not repeat
it in your summary, and keep it out of every log line. Hex rather than base64, because the
value is substituted into a JDBC connection string where punctuation helps nobody.

```bash
umask 077
cat > /srv/xwiki/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/xwiki/.env
umask 022
ls -l /srv/xwiki/.env
```

Assert: the file exists with mode `-rw-------`. Docker Compose reads this same file for the
`${DB_PASSWORD}` substitution in compose.yml and hands the value to both containers. There is
no administrator password here: XWiki seeds no account, and the human creates the first one in
the browser at step 7. Do not enable `xwiki.superadminpassword`; it is commented out in the
shipped configuration, which disables that account, and that is the state to leave it in.

## 4. compose.yml

```bash
cat > /srv/xwiki/compose.yml <<'EOF'
# XWiki · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image tags .... https://github.com/docker-library/official-images/blob/master/library/xwiki
#   image sources . https://github.com/xwiki/xwiki-docker/tree/master/17/postgres-tomcat
#
# Two services: XWiki on Tomcat, and the PostgreSQL that holds every page.
# 17.10.11 is the line the official-images file above labels LTS; the 18.x tags
# are the monthly stable line. The image carries the XWiki WAR but not the
# default set of wiki pages, so the wizard downloads those on first boot into
# the permanent directory mounted below, which also holds the Solr index and
# every attachment: file storage has been XWiki's attachment default since
# 10.5. `init: true` reaps the LibreOffice children the JVM leaves as zombies,
# as upstream does. Digests read 2026-08-07; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: xwiki-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: xwiki
      POSTGRES_USER: xwiki
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      # Upstream initialises it this way; encoding is fixed at create time.
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale-provider=builtin --locale=C.UTF-8"
    volumes:
      - /srv/xwiki/postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U xwiki -d xwiki"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  xwiki:
    image: xwiki:17.10.11-postgres-tomcat@sha256:f1b36072ed82d2e7414b3b12b670d4ddf981f32698f70a8fa8deb606fe989621
    container_name: xwiki
    restart: unless-stopped
    init: true
    # DB_PASSWORD arrives from /srv/xwiki/.env, mode 600. The entrypoint
    # writes it and the three below into WEB-INF/hibernate.cfg.xml.
    env_file: /srv/xwiki/.env
    environment:
      DB_HOST: postgres
      DB_DATABASE: xwiki
      DB_USER: xwiki
      # No JAVA_OPTS: setenv.sh gives Tomcat a 1024 MB heap, and JAVA_OPTS
      # is where you raise it.
    volumes:
      - /srv/xwiki/data:/usr/local/xwiki
    healthcheck:
      # Tomcat boots, then XWiki builds its schema: long start period.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8080/bin/view/Main/ || exit 1"]
      interval: 15s
      retries: 20
      start_period: 300s
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8172.
      - "127.0.0.1:8172:8080"
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/xwiki && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Do not set `CONTEXT_PATH`: left unset, the entrypoint deploys
XWiki as the Tomcat ROOT context, which makes https://<DOMAIN>/ the wiki rather than
https://<DOMAIN>/xwiki/.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-xwiki
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# XWiki · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/xwiki/xwiki-docker/blob/master/17/postgres-tomcat/docker-compose.yml and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. XWiki builds the
# links inside a page relative to the request it answered, so it follows this
# hostname without being told it.

<DOMAIN> {
	# Pages, search results and the JavaScript bundles are all text.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8172 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall. XWiki's realtime
	# editing rides a WebSocket, and reverse_proxy performs that upgrade
	# with no extra directive.
	reverse_proxy 127.0.0.1:8172
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-xwiki, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and
443/udp is HTTP/3. 8172 stays closed because compose binds it to 127.0.0.1, and 5432 because
compose publishes no host port for it. Assert: `ufw status verbose` prints `Status: active`,
shows 80, 443/tcp and 443/udp, and no rule naming 8172 or 5432.

## 7. Start and verify

Two slow things happen in a row, and neither is a fault. Tomcat starts and XWiki builds its
whole schema, which is the loop below. Then a human runs the wizard, whose second step
downloads the default user interface from upstream's extension repository, which needs
outbound internet from this server and takes minutes.

```bash
cd /srv/xwiki
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL https://<DOMAIN>/ | grep -c 'id="distributionWizard"'
curl -sSL https://<DOMAIN>/ | grep -c 'Distribution Wizard'
```

Assert all three and print what you received for each. The loop ends printing `200`, after
two redirects: `/` goes to `/bin/view/Main/`, which goes to the wizard. Both greps print `1`.
If any of the three misses, stop, run `docker compose logs --tail 60 xwiki` and
`docker compose logs --tail 20 postgres`, and name the likely earlier step: a database that
never reports healthy points at step 2, a `502` while the XWiki log still prints schema updates
wants more time rather than a fix, and a `404` where the wizard was expected means
`CONTEXT_PATH` reached the container in step 4. A running container is not success.

The first screen at https://<DOMAIN>/ is the wizard, headed `Distribution Wizard`, and its
second step is headed `Admin user`.

STOP: tell the user to open https://<DOMAIN>/ now, work through the wizard, register the
administrator on the `Admin user` step, let the `User Interface` step finish, and wait.
Do not continue until they confirm they reached the report at the end. Tell them to put that
password in their password manager first: this install configures no mail, so there is no
reset route.

Once they confirm, prove the wizard is shut to everyone else:

```bash
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/bin/distribution/XWiki/Distribution | grep -c 'id="distributionWizard"'
```

Assert: the first prints `200` and the second prints `0`, which is the security assert here.
Upstream gives a signed-out visitor the wizard only while the main wiki has no registered user,
so once the administrator exists a stranger asking for that URL gets a login form. Both asserts
must pass before you report success.

## 8. First backup and restore

Two artifacts, and you need both. The database holds every page, revision, comment and user.
The archive holds the permanent directory, where the attachments actually are, plus the two
files that rebuild the service around them.

```bash
cd /srv/xwiki
docker compose exec -T postgres pg_dump -U xwiki -d xwiki | gzip > /srv/xwiki/backups/xwiki-db-$(date +%F).sql.gz
sudo tar -czf /srv/xwiki/backups/xwiki-files-$(date +%F).tar.gz -C /srv/xwiki compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/xwiki/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently. The archive runs under sudo because the
container wrote that directory as root.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/xwiki
scp vps:/srv/xwiki/backups/* ~/backups/xwiki/
```

To restore: `docker compose down`, `sudo rm -rf /srv/xwiki/postgres /srv/xwiki/data`, recreate
both as step 2 does, untar the archive into /srv/xwiki so `.env` and the permanent directory
are back before anything starts, `docker compose up -d postgres`, wait about 30 seconds for it
to report healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U xwiki -d xwiki`, then `docker compose up -d`. Tell the
user why both matter: the dump alone restores a wiki whose every attachment is a broken link,
because XWiki has kept attachment content on disk rather than in the database since 10.5.

## 9. Updating later

New versions are listed at https://github.com/xwiki/xwiki-platform/releases, and the tag each
maps to is in https://github.com/docker-library/official-images/blob/master/library/xwiki. Stay
on 17.10.x: it is the long-term line, and 18.x is the monthly release train. Take both backup
artifacts first, then edit the image line in /srv/xwiki/compose.yml to the new tag and digest:

```bash
cd /srv/xwiki
docker compose pull
docker compose up -d
docker compose logs --tail 40 xwiki
```

XWiki migrates its own schema on the way up, and a version bump makes the wizard reappear for
its user-interface step, which is expected. Watch that log until it settles, then re-run
step 7's checks before calling the update done.

## 10. What will probably go wrong

You will think the wizard has frozen. I did. Its second step downloads the whole default user
interface from upstream's extension repository, and the browser sits on a progress bar for
several minutes while `docker compose logs -f xwiki` prints almost nothing. Before that, the
first boot spends minutes creating the schema while Caddy answers `502` to everything. Let the
loop in step 7 run all sixty attempts, and once the wizard is on screen leave it alone until it
moves by itself. If that step does fail, the cause is almost always that this server has no
outbound internet access, not XWiki.

## 11. Out of scope

- Do not configure SMTP. XWiki runs without it, and every notification and password reset it
  would have emailed stays inside the web interface.
- Do not replace /usr/local/xwiki/data/xwiki.cfg to force `xwiki.url.protocol=https`. Links
  inside a page are relative, so the wiki works over TLS as installed; that setting changes
  only the absolute URLs in feeds, and swapping the file replaces every other default in it.
- Do not install the Confluence import extension now. It is a contributed extension the user
  installs from the Extension Manager once they have a wiki to import into.
- Do not point `SOLR_BASE_URL` at an external Solr. The embedded index in the permanent
  directory is the choice here, and a second search service is a third container.
