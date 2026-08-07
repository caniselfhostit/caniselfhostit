This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing XWiki 17.10.11 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1. From the moment step 7 starts the containers until you have created
the administrator account in the browser, anybody who opens `<DOMAIN>` can create it instead of
you: XWiki lets a signed-out visitor run its setup wizard for exactly as long as the wiki has
no registered user. Do not start step 7 unless you can finish step 7.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `3072` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that
does not resolve and failed attempts count against a rate limit you cannot see. The memory
floor is the one not to argue with. XWiki is Java: the image starts Tomcat with a 1024 MB heap
and runs a LibreOffice process in the same container for office import and export, and
PostgreSQL sits beside both. On a 2 GB box the first failure you see is an OOM kill in the
middle of the setup wizard, and it will not mention memory.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/xwiki /srv/xwiki/backups
sudo install -d -m 700 /srv/xwiki/postgres /srv/xwiki/data
ls -la /srv/xwiki
```

You should see: `backups` owned by you, and `postgres` and `data` both at mode `drwx------`
owned by root.

If you do not: leave those two owned by root on purpose. The PostgreSQL image chowns its own
data directory the first time it starts and refuses one somebody has already claimed, and the
XWiki container's Tomcat runs as root, so it fills `data` with root-owned files as soon as it
boots. `data` is XWiki's permanent directory: the user interface it downloads in step 7, the
search index, the logs, and every file anybody attaches to a page.

## 3. Secrets

One secret, the PostgreSQL password. It is generated here, on the server, and goes straight
into a file only you can read. Hex rather than base64, because the value ends up inside a JDBC
connection string where punctuation helps nobody.

```bash
umask 077
cat > /srv/xwiki/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/xwiki/.env
umask 022
ls -l /srv/xwiki/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/xwiki/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten the
password, which is fine before the database exists and a problem afterwards: PostgreSQL keeps
the password it was created with, so a changed `DB_PASSWORD` against an existing data directory
produces an authentication failure in the XWiki log rather than anything about passwords.

Do not paste that file, that password, or any command output containing it into this chat
window. The agent path never sees the value; this path will hand it to a third party unless you
keep it out. Read it yourself with `sudo grep DB_PASSWORD /srv/xwiki/.env` in a terminal, not
here. There is no administrator password in that file: XWiki seeds no account, and you create
the first one in a browser at step 7.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/xwiki/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/xwiki/compose.yml` and paste again in one go. Do not add `CONTEXT_PATH` to that
environment block. Left unset, the image's entrypoint deploys XWiki as the Tomcat ROOT context,
which is what makes https://<DOMAIN>/ the wiki rather than https://<DOMAIN>/xwiki/.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-xwiki /etc/caddy/Caddyfile`, reload,
and paste again. Caddy requests the certificate on the first request to the hostname and renews
it by itself, so there is nothing to schedule and nothing to renew by hand.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8172` or `5432`.

If you do not: delete anything for `8172` or `5432` with `sudo ufw delete allow 8172`. 8172 is
bound to 127.0.0.1 by the compose file and 5432 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp redirects to HTTPS and answers the ACME
challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so something
has turned it off since, and `sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

Two slow things happen in a row here, and neither is a fault. Tomcat starts and XWiki builds
its whole schema in PostgreSQL, which is what the loop waits for. Then you run the setup
wizard, whose second step downloads the default user interface from upstream's extension
repository, which needs outbound internet from this server and takes minutes.

```bash
cd /srv/xwiki
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sSL -o /dev/null -w '%{http_code}' https://<DOMAIN>/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL https://<DOMAIN>/ | grep -c 'id="distributionWizard"'
curl -sSL https://<DOMAIN>/ | grep -c 'Distribution Wizard'
```

You should see, in order: the loop counting up and reaching `200`, then `1`, then `1`. The
`200` arrives after two redirects, because `/` sends you to `/bin/view/Main/`, which sends you
to the wizard.

If you do not: a `502` that never becomes `200` while `docker compose logs --tail 40 xwiki`
still prints schema updates wants more time rather than a fix, so let all sixty attempts run.
If the loop finishes without a `200`, run `docker compose logs --tail 20 postgres` first,
because a database that never reports healthy is step 2 done wrong, and
`docker compose logs --tail 60 xwiki` second. A `404` where the wizard was expected means
`CONTEXT_PATH` reached the container in step 4. A green `docker compose ps` on its own is not
success.

The first screen at https://<DOMAIN>/ is the wizard, headed `Distribution Wizard`. Open it in a
browser now. Its second step is headed `Admin user`: register the account you want to
administer this wiki with, put that password in your password manager as you type it, because
this install configures no mail and there is no reset route. Then let the `User Interface` step
run to the end. It downloads the whole default flavor and sits on a progress bar for minutes.

Once the wizard shows you its report, confirm it is shut to everyone else:

```bash
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/bin/distribution/XWiki/Distribution | grep -c 'id="distributionWizard"'
```

You should see: `200`, then `0`.

If you do not: a `1` on the second line means the wizard is still open to signed-out visitors,
which means the administrator account did not get created, so go back to the browser and finish
that step before you leave this running. That check is the security assert here: XWiki offers a
signed-out visitor the wizard only while the wiki has no registered user, so a `0` is the proof
that the window closed behind you.

## 8. First backup and restore

Two artifacts, and you need both. The database holds every page, revision, comment and user.
The file archive holds the permanent directory, where the attachments actually are, plus the
two files that rebuild the service around them.

```bash
cd /srv/xwiki
docker compose exec -T postgres pg_dump -U xwiki -d xwiki | gzip > /srv/xwiki/backups/xwiki-db-$(date +%F).sql.gz
sudo tar -czf /srv/xwiki/backups/xwiki-files-$(date +%F).tar.gz -C /srv/xwiki compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/xwiki/backups/
```

You should see: two files, the dump a few hundred kilobytes and the archive a few hundred
megabytes on a fresh install, because the flavor and the search index are inside it. Nothing
goes offline: `pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway, so run the dump line without `| gzip` to read the error. The
`tar` needs `sudo` because the container wrote `data` as root.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/xwiki
scp vps:/srv/xwiki/backups/* ~/backups/xwiki/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/xwiki/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty wiki:

```bash
cd /srv/xwiki
docker compose down
sudo rm -rf /srv/xwiki/postgres /srv/xwiki/data
sudo install -d -m 700 /srv/xwiki/postgres /srv/xwiki/data
sudo tar -xzf /srv/xwiki/backups/xwiki-files-$(date +%F).tar.gz -C /srv/xwiki compose.yml .env data
docker compose up -d postgres
sleep 30
gunzip -c /srv/xwiki/backups/xwiki-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U xwiki -d xwiki
docker compose up -d
sleep 60
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `200` from the last command,
and your wiki back in a browser with the account you made still working.

If you do not: `role "xwiki" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand why both artifacts are
in that sequence: XWiki has kept attachment content on disk rather than in the database since
version 10.5, so a dump restored without `data` gives you every page back with every attachment
a broken link.

## 9. Updating later

New versions are listed at https://github.com/xwiki/xwiki-platform/releases, and the tag each
one maps to is in https://github.com/docker-library/official-images/blob/master/library/xwiki.
Stay on the 17.10.x line: it is the long-term one, and the 18.x tags are the monthly release
train. Take both backup artifacts first, then edit the `image:` line in /srv/xwiki/compose.yml
to the new tag and its digest.

```bash
cd /srv/xwiki
docker compose pull
docker compose up -d
docker compose logs --tail 40 xwiki
```

You should see: schema migration output, then Tomcat starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. A version bump
also makes the wizard reappear for its user-interface step the next time you open the wiki,
which is the upgrade working rather than failing. Re-run the checks from step 7 before you call
the update done.

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
- Do not install the Confluence import extension now. It is a contributed extension you install
  from the Extension Manager once you have a wiki to import into.
- Do not point `SOLR_BASE_URL` at an external Solr. The embedded index in the permanent
  directory is the choice here, and a second search service is a third container.
