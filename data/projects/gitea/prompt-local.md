You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Gitea 1.27.1 under ~/selfhost/gitea, answering at http://localhost:8208.

## 1. Preflight

Say this to the user before step 2 runs. Git remotes that point at localhost only work on this
computer. A laptop and a desktop will not share the same origin without a real hostname later.
This path still teaches the forge loop: create an account, close registration, push over HTTPS
with a token. SSH is not published here either.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. Gitea needs
1024 MB of RAM available and 10 GB free on the home disk, and the image publishes amd64 and
arm64. If available RAM is under 1024 MB or free disk is under 10 GB, print both numbers and
stop. Do not install and hope.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running. Do not continue until they confirm.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/gitea/data ~/selfhost/gitea/backups
ls -la ~/selfhost/gitea
```

Assert: `data` and `backups` exist. `data` holds repos, SQLite, attachments and `app.ini`.

## 4. Secrets

No secret is generated and there is no `.env` file. The install wizard creates the admin account
in the browser. The risk on a public host does not apply the same way on loopback, but
registration still closes after the first account so a later bind change cannot leave an open
signup form.

## 5. compose.yml

```bash
cat > ~/selfhost/gitea/compose.yml <<'EOF'
# Gitea · the compose file for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker ............. https://docs.gitea.com/installation/install-with-docker
#   config cheat sheet . https://docs.gitea.com/administration/config-cheat-sheet
#
# One service on the computer you are sitting at. Paths are relative to
# ~/selfhost/gitea/. ROOT_URL is http://localhost:8208/ on this path. SSH is
# not published. Digest read from Docker Hub on 2026-08-07 for tag 1.27.1.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  gitea:
    image: gitea/gitea:1.27.1@sha256:34e3f6b75f5cbb6aebce588037fc5a53c84213e4d4b00da0a8d73e031a558e52
    container_name: gitea
    restart: unless-stopped
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      GITEA__database__DB_TYPE: sqlite3
      GITEA__server__DOMAIN: localhost
      GITEA__server__ROOT_URL: http://localhost:8208/
      GITEA__server__DISABLE_SSH: "true"
      GITEA__server__START_SSH_SERVER: "false"
      # Flip to "true" after the first account claims the instance (step 7).
      GITEA__service__DISABLE_REGISTRATION: "false"
    volumes:
      - ./data:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8208.
      - "127.0.0.1:8208:3000"
EOF
cd ~/selfhost/gitea && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. One service, ROOT_URL set to http://localhost:8208/, no SSH.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. 8208 is bound to 127.0.0.1 only. Confirm:

```bash
grep -c '"127.0.0.1:' ~/selfhost/gitea/compose.yml
```

Assert: that count is exactly `1`.

## 7. Start and verify

```bash
cd ~/selfhost/gitea
docker compose pull
docker compose up -d
for i in $(seq 1 36); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8208/); echo "$i $code"; case "$code" in 200|301|302|303|307|308) break ;; esac; sleep 5; done
curl -sSL http://localhost:8208/ | grep -ciE 'gitea|install|register|sign'
docker compose ps
```

Assert: loop ends with 2xx/3xx and the body matches Gitea or the install surface. If the port is
already allocated, find what holds 8208 and stop until it is free.

STOP: tell the user to open http://localhost:8208/, finish the install wizard if shown, create
the first admin account, and confirm they are signed in. Do not continue until they confirm.

Close registration:

```bash
cd ~/selfhost/gitea
sed -i.bak 's/GITEA__service__DISABLE_REGISTRATION: "false"/GITEA__service__DISABLE_REGISTRATION: "true"/' compose.yml
docker compose up -d
sleep 8
echo -n 'disable_flag_count='; grep -c 'DISABLE_REGISTRATION: "true"' ~/selfhost/gitea/compose.yml
curl -sSL http://localhost:8208/user/sign_up -o /tmp/gitea-signup-followed.html
echo -n 'open_form_markers='; grep -ciE 'name="user_name"|id="user_name"' /tmp/gitea-signup-followed.html
```

Assert: `disable_flag_count` is `1` and `open_form_markers` is `0`. If the form is still open,
stop.

Handoff: create a repo in the UI, generate a personal access token, then:

```bash
git clone http://localhost:8208/<username>/<repo>.git
```

Push with username + token. Prefer HTTPS over any SSH remote the UI suggests.

STOP: do not continue until they confirm a push works or they explicitly defer the push. Do not continue until they confirm.

## 8. First backup and restore

```bash
cd ~/selfhost/gitea
docker compose stop
tar -C ~/selfhost/gitea -czf ~/selfhost/gitea/backups/gitea-$(date +%F).tar.gz data compose.yml
docker compose start
ls -lh ~/selfhost/gitea/backups/
```

Assert: archive exists and is non-empty. Print its size. Copy it off this computer to a sync
folder or USB stick. To restore: `docker compose down`, move aside `data`, untar, `docker compose up -d`.
`data/` is every repository and the account database.

## 9. Updating later

Releases: https://github.com/go-gitea/gitea/releases. Backup first, edit the image line in
~/selfhost/gitea/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/gitea
docker compose pull
docker compose up -d
docker compose logs --tail 40 gitea
```

Confirm sign-in still works and `DISABLE_REGISTRATION` is still `"true"`.

## 10. What will probably go wrong

You will try an SSH remote against localhost:22 and get connection refused. This install never
started an SSH listener for git. Use HTTPS and a token. Second: leaving registration open after
the first account, so the next person on the same machine can create another admin. Flip the
flag. Third: filling the disk under `data/` with large binaries without LFS planning; watch free
space before big pushes.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS on this path.
- Do not rebind 8208 to 0.0.0.0.
- Do not publish git over SSH.
- Do not skip closing registration after the first account.
