# Noname API Security — Kong Plugin Install (Ubuntu 24.04 + Docker, 192.168.1.91)

Ubuntu/Docker port of [`../noname_kong_install.md`](../noname_kong_install.md). It installs
the **nonamesecurity** Kong plugin (v5.0.1) on the Kong 3.6.1 gateway built by
[`kong-ubuntu-docker.md`](kong-ubuntu-docker.md): `kong` + `kong-db` Docker containers on
network `kongnet`, **DB mode**, host **192.168.1.91**.

> **Status on .91 (2026-10-30): not installed yet.** The base gateway is running. The plugin
> needs the 6 Lua files from the Noname integration-profile download, which weren't on
> hand. Every step below is ready to run once they are.

How the plugin behaves (async inspection, inline fail-open prevention, priority 2501 ahead of
`rate-limiting`, 1 MB payload cap) and the full `schema.lua` field reference are the same
on any host. See **How it works** and **Configuration reference** in the original doc.

## What changed from the RHEL/Podman guide

| Topic | RHEL / Podman | Ubuntu / Docker |
|---|---|---|
| Commands | `sudo podman ...` | `docker ...` (user in the `docker` group) |
| Get the DB password | `podman inspect ... \| tr ',' '\n' \| grep ...` | `cat ~/.kong-db-password` (written in base-guide Step 4), or `docker inspect` (below) |
| SELinux labels on the bind mount | permissive mode, so no `:z` needed | no SELinux. Docker's default AppArmor profile allows the read-only bind mount as is |
| `chown 1000:1000` | uid 1000 is just "the kong uid" | on .91 uid 1000 is **also your login user `mcropsey`**, so the files show up as owned by you on the host. Expected and harmless (the mount is `:ro`) |
| Image | `docker.io/library/kong:3.6` | `kong:3.6` (same image, same Lua path `/usr/local/share/lua/5.1/kong/plugins/`) |

---

## Prerequisites (verify once)

```bash
ssh mcropsey@192.168.1.91
docker ps --format '{{.Names}}  {{.Status}}'          # kong  Up ... (healthy), kong-db  Up ...
docker inspect kong --format '{{range .Config.Env}}{{println .}}{{end}}' | grep KONG_DATABASE   # KONG_DATABASE=postgres
curl -s http://localhost:8001/status | python3 -c 'import json,sys; print("db:", json.load(sys.stdin)["database"]["reachable"])'   # True
ls /opt/kong/plugins 2>/dev/null                       # expect: nothing yet
```

The plugin files (from the integration-profile download, e.g. on the Mac):

```
~/Downloads/noname-security-kong-policy/kong/plugins/nonamesecurity/
├── batch_queue.lua   ├── handler.lua     ├── schema.lua
├── configuration.lua ├── prevention.lua  └── utils.lua
```

`schema.lua` comes **pre-filled** with the engine URL, source index and source key for the
integration profile. Check that they're real values, not placeholders:

```bash
grep -E "NN_ENGINE_URL|NN_SOURCE_INDEX|NN_SOURCE_KEY|NN_PREVENTION_ENABLED" \
  ~/Downloads/noname-security-kong-policy/kong/plugins/nonamesecurity/schema.lua
```

> `schema.lua` holds the **source key**, which is a credential. Don't commit it to git.
> This repo's `.gitignore` blocks `nonamesecurity/` for that reason.

Check that .91 can reach the engine (use the host from `NN_ENGINE_URL`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://michaelc-lab.nonamesec.com/engine?structure=base64-payload"
```

---

## Step 1 — Copy the plugin files onto .91

```bash
# from the machine that has the download
tar czf - -C ~/Downloads/noname-security-kong-policy kong/plugins/nonamesecurity | \
  ssh mcropsey@192.168.1.91 "sudo sh -c 'mkdir -p /opt/kong/plugins && tar xzf - -C /opt'"

# make the tree readable by the kong user (uid 1000) in the container
ssh mcropsey@192.168.1.91 "sudo chown -R 1000:1000 /opt/kong/plugins"

# verify on .91
ssh mcropsey@192.168.1.91 "ls /opt/kong/plugins/nonamesecurity
grep -E 'NN_ENGINE_URL|NN_SOURCE_INDEX' /opt/kong/plugins/nonamesecurity/schema.lua"
```

Only the 6 `nonamesecurity/*.lua` files are needed. The `spec/`, `.busted`, `.rock` and
`fake-lambda-custom-plugin` items in the download are test/dev files.

---

## Step 2 — Recreate the Kong container with the plugin mounted + enabled

You have to recreate the container this one time. Both the **mount** (puts the Lua files on
Kong's Lua path) and **`KONG_PLUGINS`** (tells Kong to load the plugin) are fixed when a
container is created. Kong only loads plugin *code* when the process starts. DB mode
reloads *config* live, but not code.

Postgres and the `kong-db-data` volume are untouched, so all 9 services/routes/rate limits
carry over.

```bash
# on .91
PW=$(cat ~/.kong-db-password)
# (if the file is gone:)
# PW=$(docker inspect kong --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^KONG_PG_PASSWORD=' | cut -d= -f2-)

docker rm -f kong

docker run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres \
  -e KONG_PG_HOST=kong-db \
  -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" \
  -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  -e KONG_PLUGINS=bundled,nonamesecurity \
  -v /opt/kong/plugins/nonamesecurity:/usr/local/share/lua/5.1/kong/plugins/nonamesecurity:ro \
  kong:3.6
```

Two things to get right:

- **Mount just the plugin folder**, not `/opt/kong/plugins`. Mounting the parent over
  `/usr/local/share/lua/5.1/kong/plugins/` hides Kong's bundled plugins and breaks
  `rate-limiting`.
- **Keep `bundled` in `KONG_PLUGINS`** for the same reason.

---

## Step 3 — Confirm the plugin code is loaded

```bash
sleep 10
docker exec kong ls /usr/local/share/lua/5.1/kong/plugins/nonamesecurity   # the 6 .lua files
curl -s http://localhost:8001/ | python3 -c 'import json,sys; print("nonamesecurity" in json.load(sys.stdin)["plugins"]["available_on_server"])'
# expect: True
```

`enabled_in_cluster` only lists plugins that have an instance, so `nonamesecurity` shows up
there after Step 4. Before Step 4, check `available_on_server`.

---

## Step 4 — Register the plugin instance

> **This gateway is YAML-managed** ([`deck-yaml-config.md`](deck-yaml-config.md)). Instead
> of the curl calls below, add
> ```yaml
> plugins:
> - name: nonamesecurity
> ```
> at the top level of [`deck/kong.yaml`](deck/kong.yaml) (or under one service's
> `plugins:`), then run `./kong-config.sh apply`. If you create it with curl, the next YAML
> apply deletes it. Rollback = remove the entry and apply, *before* recreating the
> container without the plugin.

Plain Admin API version (no decK):

The instance lives in Postgres. The body has no config: tuning lives in `schema.lua` and the
API Security UI.

**Global** (every service/route):

```bash
curl -s -X POST http://localhost:8001/plugins \
  -H 'Content-Type: application/json' \
  -d '{"name":"nonamesecurity"}'
```

**Or scoped to one service** (e.g. only crapi):

```bash
curl -s -X POST http://localhost:8001/services/crapi-app/plugins \
  -H 'Content-Type: application/json' \
  -d '{"name":"nonamesecurity"}'
```

> **Order matters in DB mode.** If a `nonamesecurity` instance is in Postgres but the
> container can't load the code, Kong **fails to start** with `plugin 'nonamesecurity' not
> found`. So code (Step 2) goes before the DB record (Step 4). Rollback goes the other way:
> delete the record first, then change the container.

---

## Step 5 — Verify end-to-end

```bash
curl -s http://localhost:8001/plugins | python3 -c \
  'import json,sys; print([p["name"] for p in json.load(sys.stdin)["data"]].count("nonamesecurity"), "nonamesecurity instance(s)")'
curl -s http://localhost:8001/ | python3 -c 'import json,sys; print(json.load(sys.stdin)["plugins"]["enabled_in_cluster"])'
# expect both 'nonamesecurity' and 'rate-limiting'

sleep 5   # router/plugin rebuild, as in the base guide
curl -sI -H 'Host: crapi.cropseyit.com' http://localhost:80/ | grep -iE '^HTTP|x-ratelimit-limit-minute'   # 200 + header
docker logs kong 2>&1 | grep -iE '\[(error|crit)\]'       # expect nothing new
```

Then send **real traffic** through a proxied app and check that it shows up in the API
Security UI (Settings > Integrations). With prevention on, a blocked request returns **403**
(plus the `x-blocked-by-noname` header if `NN_PREVENTION_SEND_HEADER = true`).

---

## Ops

| Change | How | Restart needed? |
|---|---|---|
| Add/remove the plugin **instance** | Admin API `POST`/`DELETE /plugins` | **No** |
| Change services / routes | Admin API | **No** |
| Tune `schema.lua` (e.g. turn prevention off) | edit `/opt/kong/plugins/nonamesecurity/schema.lua` | **Yes**: `docker restart kong` |
| New plugin version / new integration profile | replace the **whole** folder, then restart | **Yes** |
| Change `KONG_PLUGINS` or the mount | recreate the container (Step 2) | **Yes** |

```bash
# new version: re-run the Step 1 tar pipe into a clean folder, then
sudo rm -rf /opt/kong/plugins/nonamesecurity
#   ...Step 1 again...
sudo chown -R 1000:1000 /opt/kong/plugins
docker restart kong
```

## Debug logging

You need **both** of these:

```bash
# 1. turn it on in schema.lua
sudo sed -i 's/NN_DEBUG_ENABLED = { type = "boolean", default = false }/NN_DEBUG_ENABLED = { type = "boolean", default = true }/' \
  /opt/kong/plugins/nonamesecurity/schema.lua

# 2. Kong must log at info (the default "notice" hides it): add
#    -e KONG_LOG_LEVEL=info to the Step 2 docker run (recreate), then
docker logs -f kong 2>&1 | grep NONAME
```

## Rollback

```bash
# 1. delete the instance(s) first
for id in $(curl -s http://localhost:8001/plugins | python3 -c \
    'import json,sys; [print(p["id"]) for p in json.load(sys.stdin)["data"] if p["name"]=="nonamesecurity"]'); do
  curl -s -X DELETE http://localhost:8001/plugins/$id
done

# 2. recreate the container WITHOUT the plugin (= base guide Step 6)
PW=$(cat ~/.kong-db-password)
docker rm -f kong
docker run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-db -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  kong:3.6

# 3. full uninstall
sudo rm -rf /opt/kong/plugins/nonamesecurity
```

Then delete the integration profile in the API Security UI. Data already collected is
**not** removed by uninstalling.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Container keeps restarting | `docker logs kong`. Usually `plugin 'nonamesecurity' not found` (DB record exists, but the mount or `KONG_PLUGINS` is wrong) or missing files |
| `plugin 'nonamesecurity' not found` | `docker exec kong ls /usr/local/share/lua/5.1/kong/plugins/nonamesecurity`. Empty means the mount path is wrong. If the container won't stay up, run `docker run --rm -v /opt/kong/plugins/nonamesecurity:/x:ro kong:3.6 ls -l /x` to check the host files |
| Permission denied reading `.lua` files | `sudo chown -R 1000:1000 /opt/kong/plugins && sudo chmod -R a+rX /opt/kong/plugins` |
| Kong starts but `rate-limiting` is gone | `bundled` was dropped from `KONG_PLUGINS`, or the whole `/opt/kong/plugins` folder was mounted |
| Loads fine, nothing in the UI | No instance (Step 4 never ran), or .91 can't reach the engine (see the `curl` check in *Prerequisites*) |
| No `[NONAME]` log lines | Needs **both** `NN_DEBUG_ENABLED = true` and `-e KONG_LOG_LEVEL=info` |
| Prevention not blocking | `NN_PREVENTION_ENABLED` is `false`, or no matching rules in the UI. With debug on, look for `[NONAME] Blocking request …` |
