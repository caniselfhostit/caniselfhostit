This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Tolgee 3.218.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. The hostname you pick becomes `TOLGEE_FRONT_END_URL` and the `apiUrl`
in every application you wire to this server, so moving it later means editing each of them.
Pick the one you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. On the memory line, 2 GB
is not padding: this is a Java service beside a PostgreSQL, and the image's docker profile sizes
an in-memory cache at a million entries. A 1 GB box will start and then be killed under its
first import.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/tolgee /srv/tolgee/backups
sudo install -d -m 700 /srv/tolgee/postgres /srv/tolgee/data
ls -la /srv/tolgee
```

You should see: `backups` owned by you, and `postgres` and `data` at mode `drwx------` owned by
root.

If you do not: leave both owned by root on purpose. The PostgreSQL image chowns its own data
directory the first time it starts and refuses to initialise one you have already chowned to
yourself. The Tolgee container runs as root as well, and `data` is where it keeps uploaded
screenshots and the JWT key it falls back to.

## 3. Secrets

Three secrets, generated here on the server. `DB_PASSWORD` is the PostgreSQL password.
`TOLGEE_AUTHENTICATION_JWT_SECRET` signs your session tokens, and upstream requires at least 32
characters. `TOLGEE_AUTHENTICATION_INITIAL_PASSWORD` is the password of the `admin` account
Tolgee creates the first time it starts; setting it here means Tolgee does not invent one and
write it to a file inside the container.

```bash
umask 077
cat > /srv/tolgee/.env <<EOF
TOLGEE_FRONT_END_URL=https://<DOMAIN>
DB_PASSWORD=$(openssl rand -hex 32)
TOLGEE_AUTHENTICATION_JWT_SECRET=$(openssl rand -hex 32)
TOLGEE_AUTHENTICATION_INITIAL_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/tolgee/.env
umask 022
ls -l /srv/tolgee/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first line with your real hostname before you paste. Upstream states that leaving
`TOLGEE_FRONT_END_URL` unset on a publicly reachable instance is a security problem, which is
why it is the first line rather than an afterthought.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/tolgee/.env` and carry on.
If the file already existed from an earlier attempt, this block has now overwritten all three
values, which is fine before the database exists and a problem afterwards: PostgreSQL keeps the
password it was created with, so a changed `DB_PASSWORD` on an existing volume shows up as a
connection failure in the Tolgee log rather than as anything about passwords.

Do not paste that file, any of the three values, or any command output containing them into this
chat window. Read the admin password once with
`sudo grep TOLGEE_AUTHENTICATION_INITIAL_PASSWORD /srv/tolgee/.env` and put it straight into your
password manager. There is no mail server here, so there is no reset link if you lose it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/tolgee/compose.yml <<'EOF'
# Tolgee · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   running with docker . https://docs.tolgee.io/platform/self_hosting/running_with_docker
#   configuration ....... https://docs.tolgee.io/platform/self_hosting/configuration
#   image build ......... https://github.com/tolgee/tolgee-platform/blob/v3.218.0/docker/app/Dockerfile
#
# Two services: Tolgee and the PostgreSQL holding every key, translation and
# account. The tolgee/tolgee image is built on postgres:13 and starts that
# bundled database itself unless told not to. Upstream deprecated it and removes
# it in v4, so this file uses the external database shape their own docs
# document, on the PostgreSQL 17 their example names. Digests read from the
# registries on 2026-08-07; both publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: tolgee-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: tolgee
      POSTGRES_USER: tolgee
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /srv/tolgee/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U tolgee -d tolgee"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  tolgee:
    image: tolgee/tolgee:v3.218.0@sha256:1955a9e28fb247bc0404809432d0ee179b43966f5080b8100a70333375db4382
    container_name: tolgee
    restart: unless-stopped
    env_file: /srv/tolgee/.env
    environment:
      # The docker profile in this image ships this false, and false means no
      # login screen and every caller already an administrator.
      TOLGEE_AUTHENTICATION_ENABLED: "true"
      # Nobody signs themselves up. New people arrive by invitation.
      TOLGEE_AUTHENTICATION_REGISTRATIONS_ALLOWED: "false"
      # Do not start the PostgreSQL bundled in this image.
      TOLGEE_POSTGRES_AUTOSTART_ENABLED: "false"
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/tolgee
      SPRING_DATASOURCE_USERNAME: tolgee
      SPRING_DATASOURCE_PASSWORD: ${DB_PASSWORD}
      # Upstream sends daily project, language and user counts. Not from here.
      TOLGEE_TELEMETRY_ENABLED: "false"
    volumes:
      # File storage, plus the JWT key Tolgee falls back to.
      - /srv/tolgee/data:/data
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8178.
      - "127.0.0.1:8178:8080"
    # No healthcheck stanza: the image declares its own on /actuator/health.
    depends_on:
      postgres:
        condition: service_healthy
EOF
cd /srv/tolgee && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/tolgee/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/tolgee/compose.yml` and paste again in one go. Two lines in that file are worth
understanding before you move on. `TOLGEE_AUTHENTICATION_ENABLED` is `true` because the image's
docker profile ships it `false`, and `false` means there is no login screen at all and every
request arrives already logged in as the administrator. `TOLGEE_POSTGRES_AUTOSTART_ENABLED` is
`false` because the image is built on top of postgres:13 and will otherwise start a database
inside itself; upstream deprecated that one and removes it in Tolgee v4.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-tolgee
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Tolgee · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.tolgee.io/platform/self_hosting/running_with_docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also TOLGEE_FRONT_END_URL in .env and the apiUrl every SDK carries, so pick
# the one you intend to keep.

<DOMAIN> {
	# Spring Boot exposes health, info and prometheus on this port and
	# Tolgee permits anything outside /api and /v2 without a token. Health
	# has a job here; the other two hand a stranger every metric it keeps.
	@management path /actuator/info /actuator/prometheus /actuator/prometheus/*
	respond @management 403

	# HSTS is the one Tolgee cannot send for itself, and a project API key
	# rides in a header on every SDK request. The other three repeat what
	# the application already sends, for answers Caddy makes itself.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8178 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8178
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-tolgee /etc/caddy/Caddyfile`, reload, and
paste again. The `@management` matcher in that block is not decoration. Spring Boot publishes
health, info and prometheus on the same port Tolgee serves the dashboard on, and Tolgee's own
security rules let anything outside `/api` and `/v2` through without a token, so without those
two lines your metrics are public.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8178`, `5432` or `25432`.

If you do not: delete anything for those three with `sudo ufw delete allow 8178`. 8178 is bound
to 127.0.0.1 by the compose file, 5432 is never published at all, and 25432 is the port
upstream's examples publish for the bundled database this install never starts. 80/tcp is there
to redirect to HTTPS and to answer the ACME challenge, 443/tcp is the only way in, and 443/udp is
HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero
left this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it
back before you go any further.

## 7. Start and verify

Tolgee runs its own schema migrations on the way up, and a Java service on a small VPS takes over
a minute to answer at all. The loop below is that minute; let it run out before you conclude
anything.

```bash
cd /srv/tolgee
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/public/configuration); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/public/configuration | grep -o '"version":"[^"]*"\|"authentication":[a-z]*\|"allowRegistrations":[a-z]*'
curl -sS https://<DOMAIN>/v2/public/initial-data | grep -o '"userInfo":[^,]*'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/actuator/prometheus
```

You should see, in order: the loop reaching `200`; then `"version":"v3.218.0"`,
`"authentication":true` and `"allowRegistrations":false`; then `"userInfo":null`; then `403`.

If you do not: the third line is the one that decides whether this install is safe to leave
running, so do not skip past it. An unauthenticated request to `/v2/public/initial-data` on a
server with authentication switched off comes back with a populated `userInfo` object, because
Tolgee hands anyone with no token a super-powered session as the administrator. `null` there
means a stranger is nobody. If it shows an object instead, stop and run
`docker compose exec -T tolgee printenv TOLGEE_AUTHENTICATION_ENABLED`; an empty answer means the
environment line in step 4 did not survive, and the fix is to paste step 4 again and
`docker compose up -d --force-recreate`. If the loop never reaches `200`, run
`docker compose logs --tail 20 postgres` first, because a database that never reports healthy is
step 2 done wrong, and `docker compose logs --tail 40 tolgee` second. A Caddy `502` over a
container whose log says `Started Application` means Caddy is reaching nothing on 8178. A running
container is not success.

The first screen at https://<DOMAIN> is headed `Login` over an `Email` box, a `Password` box and
a `Login` button. There is no sign-up link under it, and there should not be: registration is
off, so the only account on this server is yours.

Sign in now. The username is `admin`, typed into the box labelled `Email`, and the password is
the one you read out of .env in step 3.

You should see: the Tolgee dashboard, with a button to create your first project.

If you do not: an invalid-credentials error almost always means you typed an email address into
the `Email` box. Tolgee asks for an email and the initial account is a username, and unless you
changed `TOLGEE_AUTHENTICATION_INITIAL_USERNAME` that username is `admin`. You can put a real
address on the account from the dashboard afterwards.

What happens next is yours to do and this guide does not do it. Create a project, add your
languages, generate a project API key in that project's settings, and point your application's
Tolgee SDK at `apiUrl` https://<DOMAIN> with `apiKey` set to that key. That key can edit
translations, so it belongs in a development configuration rather than a shipped bundle.

## 8. First backup and restore

Two artifacts. The database holds every key, translation, project and account. The config
archive holds the file storage and the three files that rebuild the service around it.

```bash
cd /srv/tolgee
docker compose exec -T postgres pg_dump -U tolgee -d tolgee | gzip > /srv/tolgee/backups/tolgee-db-$(date +%F).sql.gz
sudo tar -czf /srv/tolgee/backups/tolgee-config-$(date +%F).tar.gz -C /srv/tolgee compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/tolgee/backups/
```

You should see: two files, both a few kilobytes on a fresh install. Nothing goes offline:
`pg_dump` snapshots a running database consistently.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `pg_dump` failed and
the shell created the file anyway. Run the dump line without `| gzip` to read the error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/tolgee
scp vps:/srv/tolgee/backups/* ~/backups/tolgee/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/tolgee/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty project:

```bash
cd /srv/tolgee
docker compose down
sudo rm -rf /srv/tolgee/postgres
sudo install -d -m 700 /srv/tolgee/postgres
docker compose up -d postgres
sleep 30
gunzip -c /srv/tolgee/backups/tolgee-db-$(date +%F).sql.gz | docker compose exec -T postgres psql -U tolgee -d tolgee
docker compose up -d
sleep 90
curl -sS https://<DOMAIN>/api/public/configuration | grep -o '"authentication":[a-z]*'
```

You should see: `CREATE TABLE` and `COPY` lines from psql, then `"authentication":true` from the
last command, and your admin login still works.

If you do not: `role "tolgee" does not exist` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Note the order this depends on:
.env has to be in place before PostgreSQL initialises an empty directory, because that is when it
takes `DB_PASSWORD`, and the JWT secret in the same file is what validates the sessions and
tokens already issued. Restore the database without that file and you get an install that no
longer recognises its own logins.

## 9. Updating later

New versions are listed at https://github.com/tolgee/tolgee-platform/releases, and the Docker tag
is the release tag including its leading `v`. Tolgee ships several releases a week, so pick one
and read its notes rather than chasing the newest. Take both backup artifacts first, then edit
the `image:` line in /srv/tolgee/compose.yml to the new tag and its digest.

```bash
cd /srv/tolgee
docker compose pull
docker compose up -d
docker compose logs --tail 30 tolgee
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run the
four checks from step 7 before you call the update done, and sign in as well, because a server
that answers `"authentication":true` can still be failing on something a migration left halfway.

## 10. What will probably go wrong

The login box is labelled `Email` and the account is not an email address. I typed the address I
had used for the server, got an invalid-credentials error, tried it twice more, and went off to
read the container log for an authentication fault that was not there. Upstream says it in a
footnote: Tolgee asks for an email and the initial user is a username, which is `admin` unless
someone changed it. Type `admin` into that box with the password from .env. A real address can go
on the account afterwards, from the dashboard.

## 11. Out of scope

- Do not configure SMTP. Tolgee runs without it, and the price is no invitation mail and no
  password reset, so the password in .env is the whole recovery story.
- Do not set `TOLGEE_AUTHENTICATION_REGISTRATIONS_ALLOWED` to true. Step 7 checks it is false,
  and true on a public hostname means anyone who finds this server can open an account.
- Do not add the LanguageTool container from upstream's optional section. It loads every language
  model at start-up and wants 1 to 1.5 GB of memory on top of what step 1 measured.
- Do not install the Tolgee SDK into your application from here. That needs your repository and
  your API key, and this guide installs the server it talks to.
