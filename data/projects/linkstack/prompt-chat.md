This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing LinkStack 4.8.6 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

One thing to settle before step 1. `<DOMAIN>` is the address that ends up on every profile link
and QR code you hand out, and moving it later means reprinting whatever the code is printed on.
Pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `512` MB available, at least `5` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. An IP that is not your
server's usually means a proxying CDN sits in front of the record; turn that off for this
hostname while you install, or the certificate is issued to somebody else's edge.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/linkstack /srv/linkstack/backups
ls -la /srv/linkstack
```

You should see: `backups`, owned by you, and nothing else yet.

If you do not: there is no `data` directory here on purpose, and no ownership to fix. The
application, its themes, its uploads and its SQLite database live in a Docker volume rather
than under /srv, because the image ships the application at /htdocs and Docker fills an empty
named volume from the image while a bind mount would leave that directory empty. Step 8 is how
those files leave the volume and land in `backups`, where you can copy them.

## 3. Secrets

Nothing is generated on this path, and there is no `openssl rand` anywhere in it. LinkStack's
only credential is the administrator account, and you create it in a browser at step 7. The
file below is configuration: the hostname Apache answers to, which the compose file reads.
Replace `<DOMAIN>` on both lines with your real hostname before you paste.

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

You should see: exactly two lines, both carrying your hostname, and no `<DOMAIN>` left in
either.

If you do not: a `<DOMAIN>` that survived means Apache answers to a name that is not yours,
which mostly shows up as a wrong hostname in error pages rather than a broken site, so it is
worth fixing now rather than wondering later. Edit the file and run the `cat` again.

Do not paste the contents of any `.env` file, the administrator password you are about to
choose, or any command output containing either, back into this chat window. That applies twice
over to the application's own `.env` at /htdocs, which step 7 edits: it holds `APP_KEY`, the
value your sessions and password-reset links are signed with. There are two files called `.env`
in this install and they are not the same thing. The one you wrote above belongs to Docker
Compose. The application keeps its own inside the container.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/linkstack/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/linkstack/compose.yml` and paste again in one go. Do not add a second service to
fix anything here. The database is a SQLite file inside the same container, which is what makes
this a one-container install and a single archive at step 8.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-linkstack /etc/caddy/Caddyfile`, reload,
and paste again. The most common cause is a `<DOMAIN>` you replaced in the comment but not in
the site line, or the other way round. Caddy requests the certificate on the first request and
renews it on its own, so there is nothing to schedule and no cron job to check later.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8121`.

If you do not: delete anything for `8121` with `sudo ufw delete allow 8121`. Compose binds that
port to 127.0.0.1, so a firewall rule for it would cover traffic that cannot arrive in the
first place. 80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way
in, and 443/udp is HTTP/3, which Caddy offers by default. `Status: inactive` is a different
problem: Prompt Zero left this firewall on, so something has turned it off since, and
`sudo ufw enable` puts it back before you go any further.

## 7. Start and verify

Read this whole step before you run any of it. Between the container starting and you finishing
the setup wizard, that wizard is open to whoever loads the page, so plan to do both in one
sitting.

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

You should see, in order: the loop reaching `healthy`, then `FORCE_HTTPS=true`, then `200`,
then a number greater than `0`.

If you do not: a loop that never leaves `starting` means the container is not serving, so run
`docker compose logs --tail 40 linkstack`. A `502` from the curl means Caddy is reaching
nothing on 8121, which is step 4 or step 5. A certificate error usually means the A record was
created minutes ago and Caddy is still retrying; wait two minutes and run the curl again.
`FORCE_HTTPS=true` is what makes the application write `https://` into the pages Caddy serves,
and without it the setup form posts to `http://` and your browser blocks it.

The first screen at https://<DOMAIN> shows the heading `Setup LinkStack` and a language menu.
Open it now and work through the five screens. Three answers matter: choose SQLite when it asks
for a database type, use a password from your password manager on the admin screen, and on the
last screen set `Enable registration` to `No` unless you actually want a site other people sign
up to. Then come back here.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register
docker compose exec -T linkstack sh -c 'test ! -f /htdocs/INSTALLING && echo "installer removed"'
curl -sSL https://<DOMAIN>/login | grep -c 'Sign In'
docker compose exec -T linkstack sh -c "sed -i 's/^APP_DEBUG=true$/APP_DEBUG=false/; s/^APP_ENV=local$/APP_ENV=production/' /htdocs/.env"
docker compose exec -T linkstack grep -E '^APP_(DEBUG|ENV)=' /htdocs/.env
```

You should see, in order: `404`, then `installer removed`, then a number greater than `0`, then
`APP_DEBUG=false` and `APP_ENV=production`.

If you do not: a `200` from `/register` means registration is still open, so sign in, open the
admin configuration page, set registration off and run the curl again. That `404` is the
security check in this step and it is worth insisting on. If `installer removed` does not
print, the wizard's last screen never submitted, so go back to https://<DOMAIN> and finish it,
because those setup routes answer without a login. The last two lines turn off the debug mode
the application ships with, so a PHP error now shows a generic page rather than a stack trace
with your file paths in it. A running container is not success; all four of these are.

## 8. First backup and restore

Two artifacts. The data archive holds what you made. The config archive holds the files that
rebuild the service around it.

```bash
cd /srv/linkstack
docker compose exec -T linkstack tar -czf - -C /htdocs .env database assets/img themes > /srv/linkstack/backups/linkstack-data-$(date +%F).tar.gz
sudo tar -czf /srv/linkstack/backups/linkstack-config-$(date +%F).tar.gz -C /srv/linkstack compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/linkstack/backups/
```

You should see: two files, both a few hundred kilobytes on a fresh install.

If you do not: a data archive of about 20 bytes means the `tar` inside the container failed and
the shell created the file anyway. Run the same line without the redirect to read the error.
The archive is small on purpose: it leaves out the application code, which comes back from the
pinned image. The `.env` inside it carries `APP_KEY`, and without that key the sessions and
password-reset links in a restored database stop verifying, so it is the one file in there that
cannot be replaced.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/linkstack
scp vps:/srv/linkstack/backups/* ~/backups/linkstack/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/linkstack/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty page:

```bash
cd /srv/linkstack
docker compose down -v
docker compose up -d
sleep 30
docker compose exec -T linkstack tar -xzf - -C /htdocs < backups/linkstack-data-$(date +%F).tar.gz
docker compose exec -T linkstack rm -f /htdocs/INSTALLING
curl -sSL https://<DOMAIN>/login | grep -c 'Sign In'
```

You should see: `1` or more from the last line, and your own account still signs in.

If you do not: `down -v` is the one place `-v` belongs, because it drops the volume on purpose
so the image can refill /htdocs. If the site shows the setup wizard again, the `rm -f` did not
run: the fresh image brings the setup marker back with it, and removing that file is what turns
the installer off. Those four commands are the whole disaster plan, and the links, the theme
and the uploaded images are all in the one archive.

## 9. Updating later

Two things move here and they move separately, which is unusual enough to say out loud.

The application in /htdocs updates from inside. Upstream's documented path for this image is
the update notice in the admin panel and its one-click updater, which rewrites the files in the
volume. Take both archives from step 8 before you click it.

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

You should see: the container starting once, and no repeating restart.

If you do not: put the old digest back and run the same three commands. This step leaves
/htdocs alone, because Docker only fills a volume that is empty, so a new digest gives you a
newer Apache and PHP and the same application. Re-run step 7's `curl` checks before you call
the update done.

## 10. What will probably go wrong

The minute between step 7 starting the container and you finishing the wizard is the one
genuinely dangerous minute in this install, and it does not look dangerous. I read the
installer's routes while writing this: while the setup marker file is present, every one of
them answers without a login, and one of them exists to skip the wizard by seeding an
administrator whose password is a fixed string published in the project's source. A hostname
that resolves publicly gets scanned within minutes of its first certificate. So do not start
the container and then go and make coffee. If you cannot sit down with the form right now, run
`docker compose stop` and begin step 7 again when you can.

## 11. Out of scope

- Do not choose MySQL in the setup wizard. SQLite inside the container is what makes this one
  container and one archive; MySQL means a second service this prompt does not install.
- Do not configure SMTP. LinkStack ships a built-in mail setting that relays through a service
  the project runs, and changing it is a decision about someone else's terms.
- Do not run the in-app updater or the theme updater during this install. Both rewrite files in
  the volume, and step 8 has not run yet.
- Do not publish the container's 443 or open 8121 in the firewall. Caddy is the only way in.
