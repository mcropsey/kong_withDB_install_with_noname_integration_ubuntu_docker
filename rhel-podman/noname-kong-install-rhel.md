# Noname API Security — Kong Plugin Install (Rocky Linux + rootful Podman, 192.168.1.103)

Installs the **nonamesecurity** plugin (v5.0.1) on the Kong 3.6.1 gateway on **.103**
([`kong-rhel-103-deployment.md`](kong-rhel-103-deployment.md)): DB mode, with config managed
as YAML through decK ([`deck-yaml-config-rhel.md`](deck-yaml-config-rhel.md)).

It uses the vendor's **custom-image** method, the same as the Ubuntu guide
[`../ubuntu-docker/noname-kong-install-ubuntu-docker.md`](../ubuntu-docker/noname-kong-install-ubuntu-docker.md).
Read that guide's *How the plugin behaves*, *Updating*, *Rollback* and *Troubleshooting*
sections. They apply here with `docker` → `sudo podman`. This page gives the .103 commands
in full and the Podman/SELinux differences.

> **In production on .100** since 2026-10-30. That's where this method was actually used:
> the existing mount-based install was converted to `kong-noname:3.6-5.0.1`. See
> [`kong-rhel-100.md`](kong-rhel-100.md) for the real run, and for **how to rebuild the
> image later**.
>
> **Status on .103 (2026-10-30): not installed.** The build was tested on .103 with a dummy
> stand-in plugin (rootful Podman, SELinux **Enforcing**): it built, loaded, was turned on from
> YAML and ran on proxied traffic. The real install needs the integration-profile zip.

This replaces the folder-mount method in [`../noname_kong_install.md`](../noname_kong_install.md)
(written for .104). With an image there's no host mount, so **no `:Z` SELinux relabel** is
needed.

## Podman / RHEL differences

| Topic | Note |
|---|---|
| Build as **root** | `sudo podman build`: the gateway runs under rootful Podman, which can't see images built by your user (rootless storage) |
| `--format docker` | Podman builds OCI images by default, and OCI **drops Kong's `HEALTHCHECK`** (`HEALTHCHECK is not supported for OCI image format`). `--format docker` keeps it |
| Image name | stored as `localhost/kong-noname:<tag>`. `kong-noname:<tag>` resolves to it |
| SELinux | Enforcing, nothing needed (no bind mount) |
| Restart at boot | `podman-restart.service` is enabled on .103, so the recreated container comes back after a reboot |
| git push | .103 has no GitHub credentials. Commit the YAML change from .98, then `git pull` on .103 (or apply remotely with `KONG_ADDR`) |

---

## Prerequisites

```bash
ssh mcropsey@192.168.1.103
sudo podman ps --format '{{.Names}}  {{.Image}}  {{.Status}}'   # kong  docker.io/library/kong:3.6  Up …, kong-db  Up …
curl -s localhost:8001/ | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'   # 3.6.1
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker && git pull
cd rhel-podman/deck && ./kong-config.sh diff | tail -3                     # 0 / 0 / 0
curl -sS -o /dev/null -w '%{http_code}\n' "https://michaelc-lab.nonamesec.com/engine?structure=base64-payload"   # engine reachable
```

Download the zip from the API Security UI (**Settings > Integrations > Traffic Source &
Prevention > Add Integration > Kong > Create**). Only `kong/plugins/nonamesecurity/` is used.
`schema.lua` holds the **source key**: never commit it.

## Step 1 — Stage the build folder

```bash
# from the machine with the unzipped download
tar czf - -C ~/Downloads/noname-security-kong-policy kong/plugins/nonamesecurity | \
  ssh mcropsey@192.168.1.103 'mkdir -p ~/kong-noname-build && tar xzf - -C ~/kong-noname-build'

# on .103
cp ~/kong_withDB_install_with_noname_integration_ubuntu_docker/noname-image/Dockerfile ~/kong-noname-build/
chmod -R go-rwx ~/kong-noname-build
grep -E 'NN_VERSION|NN_ENGINE_URL|NN_PREVENTION_ENABLED' ~/kong-noname-build/kong/plugins/nonamesecurity/schema.lua
```

For inspection only, set `NN_PREVENTION_ENABLED` to `false` in `schema.lua` **before building**.

## Step 2 — Build the image (as root, Docker format)

```bash
cd ~/kong-noname-build
sudo podman build --format docker -t kong-noname:3.6-5.0.1 .
sudo podman images kong-noname
sudo podman run --rm kong-noname:3.6-5.0.1 ls -l /usr/local/share/lua/5.1/kong/plugins/nonamesecurity   # 6 files, -rw-r--r--
```

## Step 3 — Recreate the Kong container from the new image

Postgres and its volume are untouched, so config carries over. Expect a few seconds of proxy
downtime.

**Easiest:** use [`kong-recreate-podman.sh`](kong-recreate-podman.sh). It keeps the current
settings, sets `KONG_PLUGINS=bundled,nonamesecurity` and
`KONG_LUA_SSL_TRUSTED_CERTIFICATE=system`, and **rolls back automatically** if Kong doesn't
come up:

```bash
~/kong_withDB_install_with_noname_integration_ubuntu_docker/rhel-podman/kong-recreate-podman.sh kong-noname:3.6-5.0.1
```

**`KONG_LUA_SSL_TRUSTED_CERTIFICATE=system` is required.** Kong has **no** CA bundle for
Lua-side TLS by default, and the plugin verifies the engine's certificate
(`NN_SSL_VERIFY = true`). Without this line every batch fails with
`20: unable to get local issuer certificate` and is dropped **silently** (debug is off by
default): Kong proxies fine, `nonamesecurity` shows as enabled, and **nothing ever reaches the
UI**. That's exactly what happened on .100 until 2026-10-30.

By hand, it's the same thing:

```bash
PW=$(sudo cat /opt/kong/kong-db-password 2>/dev/null || cat ~/.kong-db-password)
sudo podman rm -f kong

sudo podman run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres \
  -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" \
  -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  -e KONG_PLUGINS=bundled,nonamesecurity \
  -e KONG_LUA_SSL_TRUSTED_CERTIFICATE=system \
  kong-noname:3.6-5.0.1

sleep 10
sudo podman ps --filter name=kong --format '{{.Names}}  {{.Image}}  {{.Status}}'   # localhost/kong-noname:3.6-5.0.1  Up … (healthy)
curl -s localhost:8001/ | python3 -c 'import json,sys; print("nonamesecurity" in json.load(sys.stdin)["plugins"]["available_on_server"])'   # True
```

## Step 4 — Turn it on in `rhel-podman/deck/kong.yaml`

Make this change **on .98** (where git can push), commit and push it, then pull and apply on
.103. Add at top level (same indent as `services:`):

```yaml
plugins:
- name: nonamesecurity
```

(or put it in one service's `plugins:` list to scope it).

```bash
# on .103
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker && git pull
cd rhel-podman/deck
./kong-config.sh diff        # creating plugin nonamesecurity (global), nothing deleted
./kong-config.sh apply
```

## Step 5 — Verify

```bash
curl -s localhost:8001/ | python3 -c 'import json,sys; print(json.load(sys.stdin)["plugins"]["enabled_in_cluster"])'   # nonamesecurity + rate-limiting
sleep 5
curl -sI -H 'Host: crapi.cropseyit.com' http://localhost/ | grep -iE '^HTTP|x-ratelimit-limit-minute'
sudo podman logs kong 2>&1 | grep -iE '\[(error|crit)\]|NONAME'
getenforce                                                       # Enforcing
```

Then send real traffic and check that it shows up in the API Security UI.

## Update / roll back / uninstall (Podman commands)

```bash
# new plugin version: replace the folder, then build a NEW tag, then switch to it
sudo podman build --format docker -t kong-noname:3.6-5.0.2 ~/kong-noname-build
~/kong_withDB_install_with_noname_integration_ubuntu_docker/rhel-podman/kong-recreate-podman.sh kong-noname:3.6-5.0.2

# new integration PROFILE (new source index/key): also re-create the instance, see the
#   Ubuntu guide's "Updating" box (DELETE /plugins/<id>, then ./kong-config.sh apply)

# roll the code back: the same script with the previous tag

# uninstall: YAML entry out FIRST, then the stock image
#   remove "- name: nonamesecurity" from kong.yaml (commit on .98, git pull here), then:
./kong-config.sh apply                                          # deleting plugin nonamesecurity
PW=$(cat ~/.kong-db-password); sudo podman rm -f kong
sudo podman run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-db -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  docker.io/library/kong:3.6
sudo podman rmi $(sudo podman images kong-noname -q); rm -rf ~/kong-noname-build
```

Nothing in the UI? Check the CA setting first:
`sudo podman exec kong grep lua_ssl_trusted /usr/local/kong/nginx-kong-inject.conf` must
point at `.ca_combined`. More in the Ubuntu guide's *Troubleshooting* (`docker` → `sudo podman`).

Debug logging: `NN_DEBUG_ENABLED = true` in `schema.lua` (rebuild, new tag) **and**
`-e KONG_LOG_LEVEL=info` in Step 3, then `sudo podman logs -f kong 2>&1 | grep NONAME`.
