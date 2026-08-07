You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Tolgee 3.218.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. Say this when you ask: the hostname becomes
`TOLGEE_FRONT_END_URL` and the `apiUrl` in every application wired to this server, so moving it
later means editing each one.

Tolgee needs 2048 MB of RAM available and 10 GB free on /srv: a JVM beside a PostgreSQL, with an
in-memory cache the image's docker profile sizes at a million entries. Both images publish amd64
and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve, and failures count against a rate limit.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/tolgee /srv/tolgee/backups
sudo install -d -m 700 /srv/tolgee/postgres /srv/tolgee/data
ls -la /srv/tolgee
```

Assert: `ls -la` shows `backups` owned by the login user, and `postgres` and `data` at mode
`drwx------` owned by root. Leave both alone. The PostgreSQL image chowns its own directory on
first start, and the Tolgee container runs as root and writes `data` itself.

## 3. Secrets

Three secrets, all generated here on the server. `DB_PASSWORD` is the PostgreSQL password.
`TOLGEE_AUTHENTICATION_JWT_SECRET` signs the session tokens, and upstream requires at least 32
characters. `TOLGEE_AUTHENTICATION_INITIAL_PASSWORD` is the password of the `admin` account
Tolgee creates on first start; setting it here means Tolgee does not invent one and write it to a
file inside the container. Do not print any of the three and keep them out of every log line.

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

Assert: the file exists with mode `-rw-------` and the login user's name twice. Replace
`<DOMAIN>` on the first line with the real hostname before writing; upstream states that leaving
`TOLGEE_FRONT_END_URL` unset on a publicly reachable instance is a security problem. Docker
Compose reads this file both for the `${...}` substitutions in compose.yml and as `env_file`.

## 4. compose.yml

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

Assert: that prints `compose OK`. The container listens on 8080 and compose publishes it on 8178,
loopback only. Upstream's single-container quick start runs the database inside the Tolgee image;
this file refuses that, because the bundled server is a PostgreSQL 13 that went end of life in
November 2025 and that upstream removes in v4.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

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

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-tolgee, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's. Idempotent, so on a Prompt Zero box they change nothing:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, and 443/udp
is HTTP/3. 8178 stays closed because compose binds it to 127.0.0.1, and 5432 because compose never
publishes it. Upstream's examples publish 25432 for the bundled database, which this install never
starts. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and 443/udp, and
no rule mentioning 8178, 5432 or 25432.

## 7. Start and verify

Tolgee runs its own schema migrations on the way up, and a Java service on a small VPS takes over
a minute to answer at all. The loop is that minute.

```bash
cd /srv/tolgee
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/public/configuration); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/public/configuration | grep -o '"version":"[^"]*"\|"authentication":[a-z]*\|"allowRegistrations":[a-z]*'
curl -sS https://<DOMAIN>/v2/public/initial-data | grep -o '"userInfo":[^,]*'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/actuator/prometheus
```

Assert all four and print what you received. The loop ends on `200`. The second command prints
`"version":"v3.218.0"`, `"authentication":true` and `"allowRegistrations":false`. The third
prints `"userInfo":null`. The fourth prints `403`.

The third decides whether this install is safe to leave running. On the image's own default,
`TOLGEE_AUTHENTICATION_ENABLED` is false, there is no login screen, and Tolgee hands every caller
a super-powered session as the administrator, so an anonymous request comes back with a populated
`userInfo` object. `null` means a stranger is nobody. Anything else: stop, do not report success,
run `docker compose exec -T tolgee printenv TOLGEE_AUTHENTICATION_ENABLED`.

If the loop never reaches `200`, stop, run `docker compose logs --tail 40 tolgee` and
`docker compose logs --tail 20 postgres`, and name the likely earlier step: a database that never
reports healthy points at step 2, a repeated connection refusal points at the datasource lines in
step 4, and a Caddy `502` over a container that logs `Started Application` means Caddy is reaching
nothing on 8178. A running container is not success.

The first screen at https://<DOMAIN> is headed `Login` over an `Email` box, a `Password` box and
a `Login` button, with no sign-up link under it because registration is off.

STOP: tell the user to read their password with
`sudo grep TOLGEE_AUTHENTICATION_INITIAL_PASSWORD /srv/tolgee/.env`, put it in their password
manager, sign in at https://<DOMAIN> with the username `admin` typed into the `Email` box, and
confirm they see the dashboard. Wait. Do not continue until they confirm.

Then tell them the next step is theirs and this prompt does not do it: create a project, add the
languages, generate a project API key in that project's settings, and point their application's
Tolgee SDK at this server with `apiUrl` set to https://<DOMAIN> and `apiKey` set to that key. The
key can edit translations, so it belongs in a development configuration, not a shipped bundle.

## 8. First backup and restore

Two artifacts. The database holds every key, translation, project and account. The config archive
holds the file storage and the files that rebuild the service around it.

```bash
cd /srv/tolgee
docker compose exec -T postgres pg_dump -U tolgee -d tolgee | gzip > /srv/tolgee/backups/tolgee-db-$(date +%F).sql.gz
sudo tar -czf /srv/tolgee/backups/tolgee-config-$(date +%F).tar.gz -C /srv/tolgee compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/tolgee/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently.

A backup on the same disk is not a backup. Run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/tolgee
scp vps:/srv/tolgee/backups/* ~/backups/tolgee/
```

To restore: `docker compose down`, `sudo rm -rf /srv/tolgee/postgres`, recreate that directory as
in step 2, untar the config archive into /srv/tolgee so .env is back before anything starts,
`docker compose up -d postgres`, wait about 30 seconds for it to report healthy, pipe `gunzip -c`
on the `.sql.gz` into `docker compose exec -T postgres psql -U tolgee -d tolgee`, then
`docker compose up -d`. That order matters twice over: PostgreSQL takes its password from .env the
moment it initialises an empty directory, and the JWT secret in the same file validates every
session already issued.

## 9. Updating later

New versions are listed at https://github.com/tolgee/tolgee-platform/releases, and the Docker tag
is the release tag with its leading `v`. Tolgee ships several a week, so pick one and read its
notes rather than chasing the newest. Take both backups first, then edit the image line in
/srv/tolgee/compose.yml to the new tag and its digest:

```bash
cd /srv/tolgee
docker compose pull
docker compose up -d
docker compose logs --tail 30 tolgee
```

Tolgee migrates its own schema on the way up, so watch that log until it settles, then re-run
step 7's four checks before calling the update done.

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
- Do not set `TOLGEE_AUTHENTICATION_REGISTRATIONS_ALLOWED` to true. Step 7 asserts it is false,
  and true on a public hostname means anyone who finds this server can open an account.
- Do not add the LanguageTool container from upstream's optional section. It loads every language
  model at start-up and wants 1 to 1.5 GB on top of what step 1 measured.
- Do not install the Tolgee SDK into the user's application. That needs their repository and their
  API key, and this prompt installs the server it talks to.
