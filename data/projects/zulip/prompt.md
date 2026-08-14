You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Zulip Server 12.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here. It becomes `SETTING_EXTERNAL_HOST`, every invitation link
is built from it, and changing it later is a database edit.

Zulip needs 4096 MB of RAM available and 20 GB free on /srv. Upstream's floor is 2 GB for the
server alone; this runs five containers. Both architectures publish.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 4096 MB or free disk is under 20 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop.

One more thing, because step 3 stops dead without it. Zulip mails invitations, password resets
and notifications, and with no relay it raises no error: it loads a backend that accepts each
message and drops it. Have the user hold transactional relay credentials ready.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/zulip /srv/zulip/backups
sudo install -d -m 700 /srv/zulip/data /srv/zulip/postgres
ls -la /srv/zulip
```

Assert: `backups` owned by the login user, `data` and `postgres` at mode `700` owned by root.
Leave both alone: Zulip runs as root and makes `uploads` and `zulip-secrets.conf` under `data`,
and PostgreSQL chowns its own cluster.

## 3. Secrets

Five: the PostgreSQL, memcached, RabbitMQ and Redis passwords the containers authenticate to
each other with, plus the Django key that seals every session. Do not print them, repeat them
in your summary, or log them. Hex, because each is rewritten into a config file.

```bash
umask 077
cat > /srv/zulip/.env <<EOF
DOMAIN=<DOMAIN>
ZULIP_ADMIN_EMAIL=CHANGE_ME
ZULIP_POSTGRES_PASSWORD=$(openssl rand -hex 32)
ZULIP_MEMCACHED_PASSWORD=$(openssl rand -hex 32)
ZULIP_RABBITMQ_PASSWORD=$(openssl rand -hex 32)
ZULIP_REDIS_PASSWORD=$(openssl rand -hex 32)
ZULIP_SECRET_KEY=$(openssl rand -hex 32)
MEMCACHED_SASL_DB=/home/memcache/memcached-sasl-db
ZULIP_EMAIL_HOST=CHANGE_ME
ZULIP_EMAIL_USER=CHANGE_ME
ZULIP_EMAIL_PASSWORD=CHANGE_ME
ZULIP_EMAIL_PORT=587
ZULIP_EMAIL_USE_TLS=True
ZULIP_EMAIL_USE_SSL=False
EOF
chmod 600 /srv/zulip/.env
umask 022
ls -l /srv/zulip/.env
```

Assert: mode `-rw-------`. Replace `<DOMAIN>` on the first line before writing. Compose reads
this file for interpolation and never hands it to a container.

STOP: tell the user to run `nano /srv/zulip/.env`, put their address in `ZULIP_ADMIN_EMAIL`,
replace the three mail `CHANGE_ME` lines with their relay's host, username and password, and
set `ZULIP_EMAIL_PORT=465` with `USE_TLS=False` and `USE_SSL=True` if the relay uses implicit
TLS. Do not continue until they confirm. Never ask them to paste a value.

```bash
grep -c CHANGE_ME /srv/zulip/.env
```

Assert: that prints `0`. It counts lines, never values.

## 4. compose.yml

```bash
cat > /srv/zulip/compose.yml <<'EOF'
# Zulip · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   variables ... https://zulip.readthedocs.io/projects/docker/en/latest/reference/environment-vars.html
#   entrypoint .. https://github.com/zulip/docker-zulip/blob/12.2-0/entrypoint.sh
#
# Five services, which is what Zulip is. Upstream's compose.yaml runs the
# same five and publishes 25, 80 and 443; this publishes one loopback port
# and never 25. Secrets ride SECRETS_* variables, which entrypoint.sh copies
# into zulip-secrets.conf. The dependency images are pinned where upstream
# floats memcached:alpine, rabbitmq:4.2 and redis:alpine, each to what those
# resolved to when digests were read on 2026-08-14, all amd64+arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  database:
    image: zulip/zulip-postgresql:14@sha256:e71ba8616fa42cdc1b248f51263d9290c29681cb8c1992eb9b498af0bb656b29
    restart: unless-stopped
    environment:
      POSTGRES_DB: zulip
      POSTGRES_USER: zulip
      POSTGRES_PASSWORD: ${ZULIP_POSTGRES_PASSWORD}
    volumes:
      - /srv/zulip/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zulip -d zulip"]
      interval: 10s
      retries: 12

  memcached:
    image: memcached:1.6.45-alpine@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7
    restart: unless-stopped
    # SASL: Zulip authenticates as zulip@localhost, as upstream sets up.
    command:
      - "sh"
      - "-euc"
      - |
        echo 'mech_list: plain' > /home/memcache/memcached.conf
        echo "zulip@$$HOSTNAME:$$MEMCACHED_PASSWORD" > "$$MEMCACHED_SASL_PWDB"
        echo "zulip@localhost:$$MEMCACHED_PASSWORD" >> "$$MEMCACHED_SASL_PWDB"
        exec memcached -S
    environment:
      SASL_CONF_PATH: /home/memcache/memcached.conf
      MEMCACHED_SASL_PWDB: ${MEMCACHED_SASL_DB}
      MEMCACHED_PASSWORD: ${ZULIP_MEMCACHED_PASSWORD}

  rabbitmq:
    image: rabbitmq:4.2.9@sha256:0104af7ef0d2bfff20b1e84a7177320d9b990531624d6b63f9dcf82d6de3b61b
    hostname: rabbitmq
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: zulip
      RABBITMQ_DEFAULT_PASS: ${ZULIP_RABBITMQ_PASSWORD}
    volumes:
      - rabbitmq:/var/lib/rabbitmq

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    command:
      - "sh"
      - "-euc"
      - 'exec /usr/local/bin/docker-entrypoint.sh redis-server --requirepass "$$REDIS_PASSWORD"'
    environment:
      REDIS_PASSWORD: ${ZULIP_REDIS_PASSWORD}
    volumes:
      - redis:/data

  zulip:
    image: ghcr.io/zulip/zulip-server:12.2-0@sha256:765f0ab3caa49041989132ee1879d98dbab1df7695c27e713eac1f114d167755
    container_name: zulip
    restart: unless-stopped
    environment:
      # CERTIFICATES absent means plain HTTP on 80, behind a proxy.
      TRUST_GATEWAY_IP: "True"
      SETTING_EXTERNAL_HOST: ${DOMAIN}
      SETTING_ZULIP_ADMINISTRATOR: ${ZULIP_ADMIN_EMAIL}
      SETTING_REMOTE_POSTGRES_HOST: database
      SETTING_MEMCACHED_LOCATION: memcached:11211
      SETTING_RABBITMQ_HOST: rabbitmq
      SETTING_REDIS_HOST: redis
      SETTING_EMAIL_HOST: ${ZULIP_EMAIL_HOST}
      SETTING_EMAIL_HOST_USER: ${ZULIP_EMAIL_USER}
      SETTING_EMAIL_PORT: ${ZULIP_EMAIL_PORT}
      SETTING_EMAIL_USE_TLS: ${ZULIP_EMAIL_USE_TLS}
      SETTING_EMAIL_USE_SSL: ${ZULIP_EMAIL_USE_SSL}
      ZULIP_AUTH_BACKENDS: EmailAuthBackend
      # Upstream's small-deploy override; the default costs a gigabyte more.
      CONFIG_application_server__queue_workers_multiprocess: "False"
      SECRETS_postgres_password: ${ZULIP_POSTGRES_PASSWORD}
      SECRETS_memcached_password: ${ZULIP_MEMCACHED_PASSWORD}
      SECRETS_rabbitmq_password: ${ZULIP_RABBITMQ_PASSWORD}
      SECRETS_redis_password: ${ZULIP_REDIS_PASSWORD}
      SECRETS_secret_key: ${ZULIP_SECRET_KEY}
      SECRETS_email_password: ${ZULIP_EMAIL_PASSWORD}
    volumes:
      - /srv/zulip/data:/data
    ulimits:
      nofile:
        soft: 1000000
        hard: 1048576
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8192.
      - "127.0.0.1:8192:80"
    depends_on:
      database:
        condition: service_healthy
      memcached:
        condition: service_started
      rabbitmq:
        condition: service_started
      redis:
        condition: service_started

volumes:
  rabbitmq:
  redis:
EOF
cd /srv/zulip && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No secret is in it: every value arrives as `${...}` from the
mode-600 `.env`, so an unset-variable complaint points at step 3.

## 5. Caddy and TLS

Append the block below, `<DOMAIN>` replaced. Copy the file first: a syntax error takes down
every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-zulip
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Zulip · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://zulip.readthedocs.io/projects/docker/en/latest/how-to/compose-ssl.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also SETTING_EXTERNAL_HOST in
# compose.yml, and every invitation link is built from it.

<DOMAIN> {
	# Zulip sends its own CSP and X-Frame-Options; setting either here
	# would overwrite the application's answer.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	encode zstd gzip

	# 8192 is the loopback port compose publishes here: not a container
	# port, not open in the firewall. Caddy adds X-Forwarded-For and
	# X-Forwarded-Proto itself, which is what TRUST_GATEWAY_IP tells Zulip
	# to believe, and it carries the long poll at /json/events unaided.
	reverse_proxy 127.0.0.1:8192
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-zulip, reload, and
report the objection.

## 6. Firewall

Two ports open, both Caddy's. Idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge, 443/tcp is the way in, 443/udp is HTTP/3. 8192 is bound to
127.0.0.1; 5432, 11211, 5672 and 6379 have no host port; 25 stays shut because this install
runs no incoming email gateway. Assert: `Status: active`, 80 and 443 present, nothing else.

## 7. Start and verify

Upstream boots this in two moves: a one-shot container that validates and migrates, then the
server. The first fails loudly, the second slowly.

```bash
cd /srv/zulip
docker compose pull
docker compose run --rm zulip app:init
```

Assert: the last line is `=== End Initial Configuration Phase ===`. Anything else, stop and read
the output: a variable renamed in 12.x means an 11.x example got edited in, a database timeout
means step 2.

```bash
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/new/ | grep -c 'Organization creation link required'
```

Assert all four and print what you got. The loop ends on `200`; that endpoint queries
PostgreSQL, round-trips memcached, pings Redis and opens a RabbitMQ channel, so one `200` is all
five answering. The body is `{"result":"success","msg":""}`. The root prints `404`, headed
`No organization found`. The grep prints `1`: `OPEN_REALM_CREATION` is off by default, so the
public creation page already refuses strangers, and there is no claim race here to lose.

The way in is a single-use link made on the server, written where only the user reads it:

```bash
umask 077
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py generate_realm_creation_link | grep -o 'https://[^[:space:]]*/new/[A-Za-z0-9]*' > /srv/zulip/realm-link.txt
umask 022
ls -l /srv/zulip/realm-link.txt
wc -l < /srv/zulip/realm-link.txt
```

Assert: mode `-rw-------`, and `1`. The link lasts seven days and is spent on first use.

STOP: tell the user to read it with `cat /srv/zulip/realm-link.txt`, open it, and complete the
page headed `Create a new Zulip organization` with their organization name, the address from
`ZULIP_ADMIN_EMAIL`, and a password saved to their password manager first.
Do not continue until they confirm they are signed in. The link skips email confirmation, so
it works even if the relay is wrong.

```bash
rm -f /srv/zulip/realm-link.txt
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/new/ | grep -c 'Organization creation link required'
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py shell -c "from zerver.models import Realm; print([(r.string_id or '(root)', r.invite_required) for r in Realm.objects.all()])"
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py send_test_email "$(grep '^ZULIP_ADMIN_EMAIL=' /srv/zulip/.env | cut -d= -f2)"
```

Assert all four. The root prints `200`. The grep prints `1` again: the link was spent, the door
is still shut. The third prints a list where every `invite_required` reads `True`, Zulip saying
nobody joins uninvited. The last exits 0; a relay that refuses the message raises here rather
than failing quietly later. A running container is not success.

STOP: tell the user to check that mailbox and confirm the two test messages arrived.
Do not continue until they confirm. If nothing lands within two minutes, read step 10 first.

## 8. First backup and restore

`app:backup` writes a fresh dump into the data directory; the tar carries that dump, the
uploads, the secrets file, `.env`, compose.yml and the live Caddy block.

```bash
cd /srv/zulip
docker compose exec -T zulip /sbin/entrypoint.sh app:backup
sudo tar -czf /srv/zulip/backups/zulip-$(date +%F).tar.gz -C /srv/zulip compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/zulip/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing stops: `pg_dump` snapshots
a running database consistently, and `postgres` is left out because a live cluster copied file
by file is not a backup. Nor is one on the same disk:

```bash
mkdir -p ~/backups/zulip
scp vps:/srv/zulip/backups/*.tar.gz ~/backups/zulip/
```

To restore cold: `docker compose down`, recreate `/srv/zulip/postgres` as in step 2, untar the
archive into /srv/zulip with `sudo` so `.env` is back first, `docker compose up -d database`, wait for
healthy, `docker compose run --rm zulip app:restore <filename>` naming a `backup-*.sql` file
from /srv/zulip/data/backups, then `docker compose up -d`. The dump is every message,
`data/uploads` every shared file, `data/zulip-secrets.conf` the keys that let the restored
server recognise its own sessions.

## 9. Updating later

New versions: https://github.com/zulip/docker-zulip/releases. Upstream publishes no floating
tags, and the Docker Hub `zulip/docker-zulip` images stopping at 11.6-0 are the end-of-life
packaging, so the tags that matter are on ghcr.io. Back up, then edit the image line to the new
tag and digest.

```bash
cd /srv/zulip
docker compose pull
docker compose up -d
docker compose logs --tail 40 zulip
```

Zulip migrates on the way up. Watch that log until it settles, re-run step 7's `/health` check,
and move one major at a time: upstream refuses floating tags because a major bump carries a
migration worth scheduling.

## 10. What will probably go wrong

The first `docker compose up -d` looks broken for several minutes and is not. I watched
`/health` answer `502`, then `500`, then nothing at all, while the container sat there
apparently doing nothing, and I nearly tore the whole thing down. The image's own health check
allows a five-minute start period for a reason: Zulip migrates, generates secrets, compiles its
configuration and starts a dozen supervised processes before nginx answers. Let the step 7 loop
run its full ten minutes. If it still fails, run `docker compose logs --tail 60 zulip` and read
for `memcached`, whose failure that log describes worst.

## 11. Out of scope

- Do not set `CERTIFICATES`. Any value moves Zulip to 443, fighting Caddy for the certificate.
- Do not publish port 25 or set `SETTING_EMAIL_GATEWAY_PATTERN`. The incoming email gateway
  wants an MX record and a mail port on this box.
- Do not register this server for the mobile push notification service. That is an account
  with Zulip and a paid plan above ten users, not a setting.
- Do not enable LDAP, SAML or social sign-on. This install uses an email address and password.
