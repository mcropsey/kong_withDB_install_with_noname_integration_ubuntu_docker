# Noname API Security — Kong Plugin Install (Ubuntu 24.04 + Docker, 192.168.1.91)

Installs the **nonamesecurity** Kong plugin (v5.0.1) on the Kong 3.6.1 gateway built by
[`kong-ubuntu-docker.md`](kong-ubuntu-docker.md): `kong` + `kong-db` containers on
`kongnet`, **DB mode**, with config managed as **YAML through decK**
([`deck-yaml-config.md`](deck-yaml-config.md)).

It follows Noname's own *Kong Plugin – Docker* install
(docs.nonamesecurity.com/kong-plugin-docker): **build the plugin into a custom Kong image**,
load it with `KONG_PLUGINS`, then turn it on. Turning it on is a `kong.yaml` entry here,
in place of the vendor's `curl … /plugins`. The RHEL/Podman version for .103 is
[`../rhel-podman/noname-kong-install-rhel.md`](../rhel-podman/noname-kong-install-rhel.md).

> **Status on .91 (2026-10-30): not installed.** The gateway runs the stock `kong:3.6` image.
> The build was tested with a dummy stand-in plugin (it built, loaded, was turned on from YAML
> and ran on proxied traffic). The real install needs the integration-profile zip.

## The plan in one table

| Part | What | Where |
|---|---|---|
| 1. Code | plugin Lua files **copied into a custom image** `kong-noname:<kong>-<plugin>` | [`../noname-image/Dockerfile`](../noname-image/Dockerfile), Steps 1–2 |
| 2. Load | `KONG_PLUGINS=bundled,nonamesecurity` on the `kong` container, run from that image | Step 3 |
| 3. Turn on | `- name: nonamesecurity` in `deck/kong.yaml`, then `./kong-config.sh apply` | Step 4 |

Same as what worked in DB-less mode (`kong-crapi-and-kong-noname-integration` repo): the
same `KONG_PLUGINS` value and the same `- name: nonamesecurity` YAML entry. The only change
is that the code is in an image, not mounted from `/opt/kong/plugins`.

**Why an image rather than mounting the folder:** it's the vendor's main method. The
plugin code is versioned by image tag, so rolling back means running the old tag. The
gateway also stops depending on files that have to stay in `/opt`. On SELinux hosts (.103)
no relabeling is needed.

## How the plugin behaves (read first)

- **Inspection is asynchronous**: traffic records are batched and sent to the engine in the
  background, adding almost no latency.
- **Prevention is inline and fail-open**: requests are checked against cached rules with a
  short timeout (`NN_PREVENTION_CHECK_TIMEOUT_MS`, default 50 ms). A slow or down engine
  never stalls traffic.
- **Prevention is ON by default** (`NN_PREVENTION_ENABLED = true`). Blocked requests get
  **403**. For inspection only, set it to `false` in `schema.lua` **before building**.
- **Priority 2501**: runs before `rate-limiting` (910). A block is a Noname 403, not a
  Kong 429.
- Payloads over **1 MB** (`NN_MAX_PAYLOAD_SIZE`) aren't fully inspected. Errors fail
  open and log `[NONAME] Critical error … failing open`.
- The full `schema.lua` field list is under *Configuration reference* in
  [`../noname_kong_install.md`](../noname_kong_install.md#configuration-reference-schemalua-v501).
  Most runtime settings (timeouts, batch size, prevention on/off) are managed in the API
  Security UI and fetched live, with no rebuild.

---

## Prerequisites

```bash
ssh mcropsey@192.168.1.91
docker ps --format '{{.Names}}  {{.Status}}'          # kong  Up ... (healthy), kong-db  Up ...
docker inspect kong --format '{{.Config.Image}}'      # kong:3.6
curl -s localhost:8001/ | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'   # 3.6.1
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker && git pull
cd ubuntu-docker/deck && ./kong-config.sh diff | tail -3                       # 0 / 0 / 0
```

Check that .91 can reach the engine (use the host from `NN_ENGINE_URL`):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://michaelc-lab.nonamesec.com/engine?structure=base64-payload"
```

Get the plugin: in the API Security UI go to **Settings > Integrations > Traffic Source &
Prevention > Add Integration > Kong**, name the profile, choose the engine, **Create**, and
download the zip. Only `kong/plugins/nonamesecurity/` (6 `.lua` files) is used here. The
`.rock`, `.rockspec`, `spec/` and `fake-lambda-custom-plugin/` aren't needed.

> `schema.lua` in the zip is **pre-filled for this integration profile** (engine URL, source
> index, **source key**). Use that exact file. It's a credential: never commit it. The
> repo's `.gitignore` blocks `nonamesecurity/`, and the build folder lives outside the repo.

---

## Step 1 — Stage the build folder on .91

```bash
# from the machine with the unzipped download (e.g. the Mac)
tar czf - -C ~/Downloads/noname-security-kong-policy kong/plugins/nonamesecurity | \
  ssh mcropsey@192.168.1.91 'mkdir -p ~/kong-noname-build && tar xzf - -C ~/kong-noname-build'

# on .91: add the Dockerfile from the repo, lock the folder down (it holds the source key)
cp ~/kong_withDB_install_with_noname_integration_ubuntu_docker/noname-image/Dockerfile ~/kong-noname-build/
chmod -R go-rwx ~/kong-noname-build
ls ~/kong-noname-build ~/kong-noname-build/kong/plugins/nonamesecurity
grep -E 'NN_VERSION|NN_ENGINE_URL|NN_PREVENTION_ENABLED' ~/kong-noname-build/kong/plugins/nonamesecurity/schema.lua
```

Expected layout:

```
~/kong-noname-build/
├── Dockerfile
└── kong/plugins/nonamesecurity/
    ├── batch_queue.lua  configuration.lua  handler.lua
    └── prevention.lua   schema.lua         utils.lua
```

For inspection only (no blocking), set `NN_PREVENTION_ENABLED` to `false` in that
`schema.lua` **now**, before building.

## Step 2 — Build the image

```bash
cd ~/kong-noname-build
docker build -t kong-noname:3.6-5.0.1 .
docker images kong-noname                       # kong-noname  3.6-5.0.1  ...
docker run --rm kong-noname:3.6-5.0.1 ls -l /usr/local/share/lua/5.1/kong/plugins/nonamesecurity   # 6 files, -rw-r--r--
```

- **Tag = `<kong version>-<plugin version>`.** Each plugin update gets a new tag, and old
  tags stay available for rollback.
- **The base is `kong:3.6`** (the image the gateway runs now). Don't use the vendor
  example's `kong/kong-gateway:3.14`: that's the Enterprise image at a different version,
  and Postgres was migrated for 3.6.
- `DEPRECATED: The legacy builder is deprecated …` is harmless. Ubuntu's `docker.io`
  ships without buildx. Run `sudo apt install docker-buildx` to make it go away.
- **Never `docker push` this image.** It contains the source key.

## Step 3 — Recreate the Kong container from the new image

This is the only container recreation. Postgres and the `kong-db-data` volume are untouched,
so all services, routes and rate limits carry over. Expect a few seconds of proxy downtime.

```bash
PW=$(cat ~/.kong-db-password)
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
  kong-noname:3.6-5.0.1
```

Compared with base-guide Step 6, there are two changes: the `KONG_PLUGINS` line, and the
image name. There's no `-v` mount. **Keep `bundled`** in `KONG_PLUGINS`, or
`rate-limiting` and every other stock plugin disappears.

Check the code is loaded (it isn't turned on yet):

```bash
sleep 10
docker ps --filter name=kong --format '{{.Names}}  {{.Image}}  {{.Status}}'    # kong  kong-noname:3.6-5.0.1  Up ... (healthy)
curl -s localhost:8001/ | python3 -c 'import json,sys; print("nonamesecurity" in json.load(sys.stdin)["plugins"]["available_on_server"])'   # True
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker/ubuntu-docker/deck && ./kong-config.sh diff | tail -3   # still 0 / 0 / 0
```

## Step 4 — Turn it on in `kong.yaml`

Add a top-level `plugins:` section to `ubuntu-docker/deck/kong.yaml`, at the same indent as
`services:`. Global means it covers every service:

```yaml
plugins:
- name: nonamesecurity
```

**Or only one service:** put `- name: nonamesecurity` in that service's own `plugins:`
list, next to its `rate-limiting`. No `config:` is needed in either case, because the
settings come from `schema.lua` and the UI.

```bash
./kong-config.sh diff        # expect: creating plugin nonamesecurity (global), nothing deleted
./kong-config.sh apply
git commit -am "kong(.91): enable nonamesecurity" && git push
```

Don't use the vendor doc's `curl -X POST …/plugins --data name=nonamesecurity`. It works,
but the next `apply` **deletes** anything not in the YAML, and Noname would silently stop.

## Step 5 — Verify end-to-end

```bash
curl -s localhost:8001/ | python3 -c 'import json,sys; print(json.load(sys.stdin)["plugins"]["enabled_in_cluster"])'
# includes 'nonamesecurity' and 'rate-limiting'
sleep 5
curl -sI -H 'Host: crapi.cropseyit.com' http://localhost/ | grep -iE '^HTTP|x-ratelimit-limit-minute'   # 200 + header
docker logs kong 2>&1 | grep -iE '\[(error|crit)\]|NONAME'       # nothing alarming
```

Then send real traffic through a proxied app and check that it shows up in the API
Security UI (Settings > Integrations). With prevention on, blocked requests return **403**.

---

## Updating to a new plugin version

A new version (or a new integration profile) means **new files and a new tag**. The YAML
entry doesn't change: "no re-association is needed".

```bash
# 1. fresh zip → replace the WHOLE plugin folder (never merge files)
rm -rf ~/kong-noname-build/kong/plugins/nonamesecurity
#    ...re-run the Step 1 tar pipe...
chmod -R go-rwx ~/kong-noname-build
grep NN_VERSION ~/kong-noname-build/kong/plugins/nonamesecurity/schema.lua   # e.g. 5.0.2

# 2. build a new tag
cd ~/kong-noname-build && docker build -t kong-noname:3.6-5.0.2 .

# 3. Step 3 again with the new tag
# 4. confirm
docker exec kong grep NN_VERSION /usr/local/share/lua/5.1/kong/plugins/nonamesecurity/schema.lua
```

**Roll back the code:** repeat Step 3 with the previous tag (`kong-noname:3.6-5.0.1`).
Clean up old tags when you no longer need them: `docker rmi kong-noname:<old-tag>`.

**Changing a `schema.lua`-only setting** (e.g. prevention on/off, debug) also needs a
rebuild. Edit the file in `~/kong-noname-build`, build a new tag (e.g. `3.6-5.0.1-b`),
then Step 3. Most runtime settings are in the UI and need no rebuild. See the configuration
reference.

**Upgrading Kong itself** (e.g. 3.6 → 3.x): change `FROM` in the Dockerfile, rebuild, run
`kong migrations up` with the new image (as in the base guide's *Upgrading*), then Step 3.

## Debug logging

You need **both**: `NN_DEBUG_ENABLED = true` in `schema.lua` (then rebuild, new tag) **and**
`-e KONG_LOG_LEVEL=info` added to the Step 3 `docker run`. Then:

```bash
docker logs -f kong 2>&1 | grep NONAME
```

## Rollback / uninstall

The order is the reverse of the install: **YAML entry first, then the container.**

```bash
# 1. remove "- name: nonamesecurity" from kong.yaml, then
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker/ubuntu-docker/deck
./kong-config.sh apply                 # diff shows: deleting plugin nonamesecurity

# 2. back to the stock image (= base guide Step 6)
PW=$(cat ~/.kong-db-password)
docker rm -f kong
docker run -d --name kong --network kongnet --restart unless-stopped \
  -p 80:8000 -p 8001:8001 \
  -e KONG_DATABASE=postgres -e KONG_PG_HOST=kong-db -e KONG_PG_USER=kong \
  -e KONG_PG_PASSWORD="$PW" -e KONG_PG_DATABASE=kong \
  -e KONG_PROXY_LISTEN=0.0.0.0:8000 -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  kong:3.6

# 3. full cleanup
docker rmi $(docker images kong-noname -q)
rm -rf ~/kong-noname-build
```

If you do step 2 before step 1, Kong won't start (`plugin 'nonamesecurity' not found`,
because the DB still has the instance). Fix: run Step 3 with the Noname image again, then
do step 1.

Then delete the integration profile in the API Security UI. Data already collected is not
removed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Container keeps restarting, `plugin 'nonamesecurity' not found` | the DB has the instance, but the container is on the stock image or `KONG_PLUGINS` lacks it. Check `docker inspect kong --format '{{.Config.Image}}'` and `KONG_PLUGINS` |
| `validate` says `No plugin named 'nonamesecurity'` | YAML entry added before Step 3. The apply is blocked (nothing broke). Do Step 3, then apply |
| `rate-limiting` disappeared | `bundled` missing from `KONG_PLUGINS` |
| `permission denied` loading `.lua` files | image built without the `chmod` line. Use the repo's Dockerfile and rebuild |
| Files in the image are stale | you rebuilt with the same tag and an old container is running, or the folder was merged rather than replaced. Use a new tag, replace the folder |
| Loads fine, nothing in the UI | YAML entry missing (`./kong-config.sh diff`), or .91 can't reach the engine (Prerequisites `curl`) |
| No `[NONAME]` log lines | needs both `NN_DEBUG_ENABLED = true` (rebuilt) and `KONG_LOG_LEVEL=info` |
| Prevention not blocking | `NN_PREVENTION_ENABLED` is `false`, or no matching rules in the UI. With debug on, look for `[NONAME] Blocking request …` |
