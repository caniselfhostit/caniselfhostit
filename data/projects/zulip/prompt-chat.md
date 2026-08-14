This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You will install Zulip Server 12.2 on a server you already own, reachable at https://<DOMAIN>
behind Caddy. Everything below assumes you are logged into that server over SSH as a non-root
user who is in the `docker` group, with Docker and Caddy already installed and the firewall
default-deny. Replace `<DOMAIN>` with the hostname whose A record already points at the box
every time you see it.

Before you start, get relay credentials from a transactional mail provider: a host, a port, a
username and a password. Zulip mails invitations, password resets and missed-message
notifications, and with no relay configured it raises no error at all. It loads a backend that
accepts each message and discards it. A consumer mailbox is not a relay.

## 1. Preflight

That hostname becomes `SETTING_EXTERNAL_HOST`. Every invitation link is built from it, and
changing it later is a database edit, so decide now.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `4096` MB available, at least `20` G free, `amd64` or `arm64`, and
your server's IP address on the last line.

If you do not: under 4096 MB or 20 GB is the number to take seriously rather than push through.
Upstream's floor is 2 GB for the server alone and this is five containers plus an image
measured in gigabytes. If `dig +short` prints nothing, the DNS record is missing or has not
propagated; fix that before going on, because Caddy cannot get a certificate for a name that
does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/zulip /srv/zulip/backups
sudo install -d -m 700 /srv/zulip/data /srv/zulip/postgres
ls -la /srv/zulip
```

You should see: `backups` owned by your login user, and `data` and `postgres` both at mode
`drwx------` owned by `root`.

If you do not: do not chown them to yourself. The Zulip container runs as root and creates
`uploads` and `zulip-secrets.conf` under `data` itself, and the PostgreSQL image chowns its own
cluster on first start. RabbitMQ and Redis use named Docker volumes, so there is nothing to
create for them.

## 3. Secrets

Five secrets get generated on the server: the PostgreSQL, memcached, RabbitMQ and Redis
passwords the five containers use to authenticate to each other, and the Django key that seals
every session. **Do not paste the contents of `.env`, any of these values, or any command
output containing them into this chat window.** Nothing in this path needs you to. Hex is used
throughout because each value is read out of `.env` by Compose and rewritten into a config file
inside the container.

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

You should see: `-rw------- 1 you you` and the path. Replace `<DOMAIN>` on the first line with
your real hostname before you run this.

If you do not: if the mode shows anything other than `-rw-------`, run `chmod 600
/srv/zulip/.env` again before continuing. If `openssl` is missing, install it and rerun the
whole block, because a half-written `.env` is worse than none.

Now fill in the four `CHANGE_ME` lines yourself:

```bash
nano /srv/zulip/.env
```

Put your own email address in `ZULIP_ADMIN_EMAIL`. Put your relay's hostname, username and
password in the three mail lines. If your relay uses implicit TLS on port 465, set
`ZULIP_EMAIL_PORT=465`, `ZULIP_EMAIL_USE_TLS=False` and `ZULIP_EMAIL_USE_SSL=True`. Save with
Ctrl-O then Enter, exit with Ctrl-X.

```bash
grep -c CHANGE_ME /srv/zulip/.env
```

You should see: `0`.

If you do not: the number is how many lines still hold the placeholder. Reopen the file and
finish. That command counts lines and never prints a value, which is why it is safe to show me
its output.

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

You should see: `compose OK`.

If you do not: a message naming a variable means that line is missing from `.env`, so go back
to step 3. A YAML error means the paste was truncated, most often in the middle of the
`memcached` command block; delete the file and paste again in one go.

## 5. Caddy and TLS

Copy the existing Caddyfile first. A syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from the reload.

If you do not: restore with `sudo cp /etc/caddy/Caddyfile.before-zulip /etc/caddy/Caddyfile`
and `sudo systemctl reload caddy`, then read what validate objected to. The usual cause is
`<DOMAIN>` left literal inside the block you pasted.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, and rules for 80/tcp, 443/tcp and 443/udp and nothing else
relevant.

If you do not: if 8192 appears, remove it with `sudo ufw delete allow 8192`. It is bound to
127.0.0.1 in the compose file and must never be reachable from outside. 5432, 11211, 5672 and
6379 have no host port at all, and port 25 stays closed because this install does not run
Zulip's incoming email gateway.

## 7. Start and verify

Two moves. The first is a one-shot container that validates the configuration and migrates the
database; it fails loudly. The second starts the server; it fails slowly.

```bash
cd /srv/zulip
docker compose pull
docker compose run --rm zulip app:init
```

You should see: several gigabytes of image layers, then a long stream of configuration output
ending with `=== End Initial Configuration Phase ===`.

If you do not: an error naming a variable that was renamed in 12.x means the compose file got
edited against an older example. `Could not connect to database server` means the PostgreSQL
container is unhappy, so run `docker compose logs --tail 20 database`.

```bash
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/new/ | grep -c 'Organization creation link required'
```

You should see: the loop counting up and ending on `200`, then `{"result":"success","msg":""}`,
then `404`, then `1`.

If you do not: that `200` is worth more than it looks. The `/health` endpoint queries
PostgreSQL, round-trips a value through memcached, pings Redis and opens a channel to RabbitMQ,
so one `200` means all five services are answering. Expect several minutes of `502` and `500`
first; the image's own health check allows a five-minute start period. If the loop runs out,
`docker compose logs --tail 60 zulip` is the place to look. The `404` at the root is correct at
this point: it is the page headed `No organization found`, and no organization exists yet. The
`1` is the security check: Zulip ships with `OPEN_REALM_CREATION` off, so the public
organization creation page already refuses strangers, and there is no window in which someone
else could claim this server.

Now make the one link that lets you in. It is single-use and it is a credential, so it goes to
a file only you can read rather than onto your screen or into this chat:

```bash
umask 077
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py generate_realm_creation_link | grep -o 'https://[^[:space:]]*/new/[A-Za-z0-9]*' > /srv/zulip/realm-link.txt
umask 022
ls -l /srv/zulip/realm-link.txt
wc -l < /srv/zulip/realm-link.txt
```

You should see: `-rw-------` on the file, and `1`.

If you do not: `0` means the command printed nothing matching, so run it again without the
redirect and read the error. The link expires in seven days and is spent the first time it is
opened.

```bash
cat /srv/zulip/realm-link.txt
```

Open that URL in a browser. You should see a page headed `Create a new Zulip organization`.
Fill in your organization name, the email address you put in `ZULIP_ADMIN_EMAIL`, and a
password. Put that password in your password manager before you submit the form, not after.
The link skips email confirmation, so it works even if the relay details are wrong, which is
what the next block is for.

```bash
rm -f /srv/zulip/realm-link.txt
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/new/ | grep -c 'Organization creation link required'
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py shell -c "from zerver.models import Realm; print([(r.string_id or '(root)', r.invite_required) for r in Realm.objects.all()])"
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py send_test_email "$(grep '^ZULIP_ADMIN_EMAIL=' /srv/zulip/.env | cut -d= -f2)"
```

You should see: `200`, then `1`, then a list of pairs in which every `invite_required` reads
`True`, then a short report from the mail command ending without an exception.

If you do not: a `404` on the first line means the organization was not actually created, so go
back to the link. A `0` on the second means the public creation page is answering something
else, which is worth stopping for. A `False` in the list means somebody turned off the
invitation requirement in the browser; turn it back on under Organization settings. If the mail
command raises, the relay details in `.env` are wrong: fix them, run
`docker compose up -d --force-recreate zulip`, and try again. Check the mailbox and confirm the
two test messages arrived before you call this done. A running container is not success.

## 8. First backup and restore

```bash
cd /srv/zulip
docker compose exec -T zulip /sbin/entrypoint.sh app:backup
sudo tar -czf /srv/zulip/backups/zulip-$(date +%F).tar.gz -C /srv/zulip compose.yml .env data -C /etc/caddy Caddyfile
ls -lh /srv/zulip/backups/
```

You should see: `Backup process succeeded.` from the first command, then one `.tar.gz` with a
size in megabytes at least.

If you do not: nothing is stopped here, because `pg_dump` snapshots a running database
consistently. The `postgres` directory is deliberately left out of the archive: a live cluster
copied file by file is not a backup, and the dump written inside `data/backups` is the
restorable form. If tar complains about permissions, you dropped the `sudo`.

A backup on the same disk as the data is not a backup. Run this one on your own computer, not
the server:

```bash
mkdir -p ~/backups/zulip
scp vps:/srv/zulip/backups/*.tar.gz ~/backups/zulip/
```

You should see: the file name and a transfer percentage reaching 100%.

If you do not: `vps` is the SSH alias; substitute `user@your.server` if you do not have one
configured.

To restore onto a clean box, in this order: `docker compose down`, recreate
`/srv/zulip/postgres` exactly as in step 2, untar the archive into `/srv/zulip` with `sudo` so
that `.env` is back before anything starts, `docker compose up -d database`, wait for it to report healthy,
then `docker compose run --rm zulip app:restore <filename>` naming one of the `backup-*.sql`
files now sitting in `/srv/zulip/data/backups`, and finish with `docker compose up -d`. Read
that list once at 2am and it still works. The dump is every message and account, `data/uploads`
is every file anyone shared, and `data/zulip-secrets.conf` holds the keys that let the restored
server recognise its own sessions and its own queue workers.

## 9. Updating later

New versions are listed at https://github.com/zulip/docker-zulip/releases. Upstream publishes
no floating tags at all, and the `zulip/docker-zulip` images on Docker Hub that stop at 11.6-0
are the end-of-life packaging, so the tags that matter are on ghcr.io. Take the step 8 backup
first, then edit the image line in `/srv/zulip/compose.yml` to the new tag and its digest.

```bash
cd /srv/zulip
docker compose pull
docker compose up -d
docker compose logs --tail 40 zulip
```

You should see: the new image pulling, the container recreating, and a log that settles into
normal service output after the migrations finish.

If you do not: migrations on a major version bump take minutes and the server does not answer
while they run. Re-run the `/health` check from step 7 before calling the update done, and move
one major version at a time. Upstream's stated reason for refusing floating tags is exactly
this: a major bump carries a migration worth scheduling.

## 10. What will probably go wrong

The first `docker compose up -d` looks broken for several minutes and is not. I watched
`/health` answer `502`, then `500`, then nothing at all, while the container sat there
apparently doing nothing, and I nearly tore the whole thing down. The image's own health check
allows a five-minute start period for a reason: Zulip is migrating, generating its secrets
file, compiling its configuration and starting a dozen supervised processes before nginx
answers for it. Let the loop in step 7 run its full ten minutes. If it still fails at the end,
run `docker compose logs --tail 60 zulip` and read for the word `memcached`, the one dependency
whose failure that log describes worst.

## 11. Out of scope

- Do not set `CERTIFICATES`. Caddy terminates TLS here, and any value of that variable moves
  Zulip to port 443 and puts the container in a fight with Caddy over the certificate.
- Do not publish port 25 or set `SETTING_EMAIL_GATEWAY_PATTERN`. The incoming email gateway
  wants an MX record and a mail port on this box, which is a separate decision.
- Do not register this server for the mobile push notification service. That is an account with
  Zulip and a paid plan above ten users, not a configuration change.
- Do not enable LDAP, SAML or social authentication. This install signs people in with an email
  address and a password.
