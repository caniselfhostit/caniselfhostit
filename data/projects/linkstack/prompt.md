You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install LinkStack 4.8.6 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Say why when you ask: this hostname goes on every profile link and QR code they hand out, and
moving it later means reprinting whatever the code is on. Its A record must already point at
this server.

LinkStack needs 512 MB of RAM available and 5 GB free on /srv. The image publishes amd64,
arm64 and two 32-bit arm variants. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 512 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a hostname that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/linkstack /srv/linkstack/backups
ls -la /srv/linkstack
```

Assert: `ls -la` shows `backups` owned by the login user. Two files live here, the compose file
and the environment file step 3 writes. The application, its themes, its uploads and its SQLite
database sit in a Docker volume instead, because the image ships the application at /htdocs and
Docker fills an empty named volume from the image while a bind mount would leave it empty.
Step 8 is how those files leave it.

## 3. Secrets

No secret is generated for this install and there is no `openssl rand` here. LinkStack's only
credential is the administrator account, created in a browser at step 7. What this step writes
is configuration: the hostname Apache answers to, which the compose file reads.

Write this with `<DOMAIN>` replaced by the real hostname on both lines:

```bash
umask 077
cat > /srv/linkstack/.env <<'EOF'
HTTP_SERVER_NAME=<DOMAIN>
HTTPS_SERVER_NAME=<DOMAIN>
EOF
chmod 600 /srv/linkstack/.env
umask 022
cat /srv/linkstack/.env
```

Assert: `cat` prints exactly two lines, both carrying the real hostname, and no `<DOMAIN>`
survives anywhere in the file.

Tell the user there are two files called `.env` here and they are different. This one is
Compose's and carries the Apache server name; the application keeps its own at /htdocs inside
the container, which steps 7 and 8 reach with `docker compose exec`.

## 4. compose.yml

```bash
cat > /srv/linkstack/compose.yml <<'EOF'
# LinkStack · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker setup ....... https://docs.linkstack.org/docker/setup/
#   reverse proxies .... https://docs.linkstack.org/docker/reverse-proxies/
#   image build ........ https://github.com/LinkStackOrg/linkstack-docker/blob/main/Dockerfile
#   app configuration .. https://github.com/LinkStackOrg/LinkStack/blob/v4.8.6/.env
#
# One container: Alpine, Apache 2 and PHP 8.3, carrying LinkStack 4.8.6 and the
# SQLite file it keeps links and users in. There is no database service here.
#
# /htdocs is a named volume and not a bind mount, and that is not a style
# choice. The image ships the application at /htdocs, and Docker copies image
# content into an empty named volume only, never into a bind mount, so a bind
# mount would start the container on an empty document root. Upstream documents
# that path as downloading the release yourself and giving the files uid 100
# and gid 101, which this install does not do.
#
# The pin is a digest with no tag, because upstream publishes no version tags:
# linkstackorg/linkstack carries a rolling tag plus four architecture tags from
# 2023. This is the manifest list digest read from Docker Hub on 2026-08-06.
# /htdocs/version.json inside it reads 4.8.6, and the list covers linux/amd64,
# linux/arm/v6, linux/arm/v7 and linux/arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  linkstack:
    image: linkstackorg/linkstack@sha256:1c8b05399ee459ac601bac3eede7fbe765d1b6b7be725663b57f3220610958bf
    container_name: linkstack
    restart: unless-stopped
    # HTTP_SERVER_NAME and HTTPS_SERVER_NAME are Apache's ServerName. They carry
    # the hostname, so they live in .env beside this file rather than in it.
    env_file: /srv/linkstack/.env
    environment:
      TZ: UTC
      # Apache's log level. The image default is info, which narrates every
      # start-up; warn keeps the container log to lines worth reading.
      LOG_LEVEL: warn
      PHP_MEMORY_LIMIT: 256M
      UPLOAD_MAX_FILESIZE: 8M
    volumes:
      - linkstack-htdocs:/htdocs
    ports:
      # Loopback only: the host's Caddy is the one thing that reaches 8121, and
      # it reaches the container's plain HTTP port. The container also listens
      # on 443 with a self-signed certificate, and this file never publishes it.
      # The image's own health check is curl against http://localhost, so the
      # HTTP port is the one upstream tests too.
      - "127.0.0.1:8121:80"

volumes:
  linkstack-htdocs:
EOF
cd /srv/linkstack && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Do not add a second service. The database is a SQLite file
inside the same container, which is what makes this a one-container install.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-linkstack
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# LinkStack · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.linkstack.org/docker/reverse-proxies/,
# https://docs.linkstack.org/docker/setup/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also HTTP_SERVER_NAME in .env, and it is the address printed on the profiles
# and QR codes people scan, so it is the value here worth choosing once.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		-Server
	}

	# 8121 is the loopback port compose publishes, and it maps to the
	# container's plain HTTP port. Upstream's own example proxies to the
	# container's 443 with certificate checking switched off; this block does
	# not, because that certificate is self-signed and skipping the check on
	# a hop is worse than not making the hop over TLS at all. The scheme the
	# application prints in its own pages comes from FORCE_HTTPS in the app's
	# .env, which step 7 turns on, so nothing here needs the back end to
	# speak TLS.
	reverse_proxy 127.0.0.1:8121
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-linkstack, reload, and report what it objected to. Caddy requests
the certificate on the first request and renews it on its own, so there is nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a box Prompt Zero configured they change
nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8121 stays closed because compose binds it to 127.0.0.1, so a rule for it would
cover traffic that cannot arrive. Assert: `ufw status verbose` prints `Status: active`, shows
80, 443/tcp and 443/udp, and no rule mentioning 8121.

## 7. Start and verify

Read the whole block before running any of it. Between the container starting and the user
finishing the setup wizard, that wizard is open to whoever loads the page.

```bash
cd /srv/linkstack
docker compose pull
docker compose up -d
for i in $(seq 1 30); do state=$(docker inspect --format '{{.State.Health.Status}}' linkstack 2>/dev/null || echo starting); echo "$i $state"; [ "$state" = healthy ] && break; sleep 5; done
docker compose exec -T linkstack sed -i 's/^FORCE_HTTPS=false$/FORCE_HTTPS=true/' /htdocs/.env
docker compose exec -T linkstack grep '^FORCE_HTTPS=' /htdocs/.env
curl -sSL -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sSL https://<DOMAIN>/ | grep -c 'Setup LinkStack'
```

Assert all four, and print what you received for each: the loop ends on `healthy`; the grep
prints `FORCE_HTTPS=true`, which is what makes the application write `https://` into pages
served through Caddy; the curl prints `200`; the last command prints a number greater than `0`.
If any misses, stop, run `docker compose logs --tail 40 linkstack`, and name the likely earlier
step: a `502` points at step 4 or 5, and a certificate error usually means the A record was
created minutes ago and Caddy is still retrying. A running container is not success.

The first screen at https://<DOMAIN> shows the heading `Setup LinkStack` and a language menu.

STOP: tell the user to open https://<DOMAIN> now and work through the five setup screens, and
wait. Do not continue until they confirm. Tell them the three answers that matter: choose
SQLite when it asks for a database type, use a password from their password manager on the
admin screen, and on the last screen set `Enable registration` to `No` unless they intend to
run a site other people sign up to. Tell them to do it now, not after lunch; step 10 says why.

Once they confirm, prove the install closed behind them:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
docker compose exec -T linkstack sh -c 'test ! -f /htdocs/INSTALLING && echo "installer removed"'
curl -sSL https://<DOMAIN>/login | grep -c 'Sign In'
docker compose exec -T linkstack sh -c "sed -i 's/^APP_DEBUG=true$/APP_DEBUG=false/; s/^APP_ENV=local$/APP_ENV=production/' /htdocs/.env"
docker compose exec -T linkstack grep -E '^APP_(DEBUG|ENV)=' /htdocs/.env
```

Assert, all four: `/register` prints `404`, the application's answer once registration is off
and the security check in this block; `installer removed` prints, so the setup routes are gone;
the login page count is greater than `0`; and the last grep prints `APP_DEBUG=false` and
`APP_ENV=production`, so a PHP error now shows a generic page rather than a stack trace with
file paths in it. All four must pass before you report success.

## 8. First backup and restore

Two artifacts: the data archive holds what the user made, the config archive the files that
rebuild the service around it.

```bash
cd /srv/linkstack
docker compose exec -T linkstack tar -czf - -C /htdocs .env database assets/img themes > /srv/linkstack/backups/linkstack-data-$(date +%F).tar.gz
sudo tar -czf /srv/linkstack/backups/linkstack-config-$(date +%F).tar.gz -C /srv/linkstack compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/linkstack/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. The data archive is small
because it leaves out the application code, which comes back from the pinned image. The `.env`
in it carries `APP_KEY`; without that key the sessions and password-reset links in a restored
database stop verifying, so it is the one file here that cannot be replaced.

A backup on the same disk is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/linkstack
scp vps:/srv/linkstack/backups/* ~/backups/linkstack/
```

To restore: `docker compose down -v`, which drops the volume on purpose, then
`docker compose up -d` to refill /htdocs from the image, wait for health, then
`docker compose exec -T linkstack tar -xzf - -C /htdocs < backups/linkstack-data-DATE.tar.gz`
with the real filename, then
`docker compose exec -T linkstack rm -f /htdocs/INSTALLING` because the fresh image brings the
setup marker back and the installer would otherwise be live again. Reload https://<DOMAIN> and
sign in. Those four commands are the whole disaster plan: the links, the theme and the uploaded
images are all in the one archive.

## 9. Updating later

Two things move here, separately, which is unusual enough to say out loud.

The application in /htdocs updates from inside. Upstream's documented path for this image is
the update notice in the admin panel and its one-click updater, which rewrites the files in the
volume. Take both archives from step 8 first, because that updater changes the application
underneath a running container.

The runtime, meaning Alpine, Apache and PHP, updates by digest. New digests appear at
https://hub.docker.com/r/linkstackorg/linkstack/tags after a release at
https://github.com/LinkStackOrg/LinkStack/releases. Edit the image line in
/srv/linkstack/compose.yml to the new digest, then:

```bash
cd /srv/linkstack
docker compose pull
docker compose up -d
docker compose logs --tail 20 linkstack
```

That replaces the container and leaves /htdocs alone, because Docker only fills a volume that
is empty. Re-run step 7's `curl` checks before calling the update done.

## 10. What will probably go wrong

The minute between step 7 starting the container and the user finishing the wizard is the one
genuinely dangerous minute in this install, and it does not look dangerous. I read the
installer's routes while writing this: while the setup marker file is present, every one of
them answers without a login, and one of them exists to skip the wizard by seeding an
administrator whose password is a fixed string published in the project's source. A hostname
that resolves publicly gets scanned within minutes of its first certificate. So do not start
the container and then go and make coffee. If the user cannot sit down with the form right now,
run `docker compose stop` and begin step 7 again when they can.

## 11. Out of scope

- Do not choose MySQL in the setup wizard. SQLite inside the container is what makes this one
  container and one archive; MySQL means a second service this prompt does not install.
- Do not configure SMTP. LinkStack ships a built-in mail setting that relays through a service
  the project runs, and changing it is a decision about someone else's terms.
- Do not run the in-app updater or the theme updater during this install. Both rewrite files in
  the volume, and step 8 has not run yet.
- Do not publish the container's 443 or open 8121 in the firewall. Caddy is the only way in.
