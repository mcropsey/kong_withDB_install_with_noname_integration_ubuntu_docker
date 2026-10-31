# Kong on 192.168.1.100 (Rocky Linux 9.8 + rootful Podman) — YAML config + Noname image

**192.168.1.100** (`hv-rocky-linux-3`) is the gateway that **runs Noname**. It was built
earlier with the original guides ([`../kong.md`](../kong.md) +
[`../noname_kong_install.md`](../noname_kong_install.md)): DB mode, plugin code mounted from
`/opt`, plugin turned on with curl. On **2026-10-30** it was converted, with no config
changes, to:

1. **YAML as the source of truth**: [`deck-100/kong.yaml`](deck-100/kong.yaml), applied with
   decK, the same as .91 and .103.
2. **Noname built into an image** (`kong-noname:3.6-5.0.1`, the vendor's method), with no
   host mount. See [`noname-kong-install-rhel.md`](noname-kong-install-rhel.md).

Jenkins on this host (`:8080`, under **Docker**, separate from Kong's Podman) was not
touched.

## Before → after

| | Before | After |
|---|---|---|
| Kong image | `docker.io/library/kong:3.6` | **`localhost/kong-noname:3.6-5.0.1`** (built from `kong:3.6` + plugin v5.0.1) |
| Plugin code | bind mount `/opt/kong/plugins/nonamesecurity` → container (`:ro`) | **inside the image**, no mounts |
| `KONG_PLUGINS` | `bundled,nonamesecurity` | same |
| Config changes | curl against the Admin API | **edit `deck-100/kong.yaml` → `./kong-config.sh apply`** |
| Noname instance | global, created with `curl POST /plugins` | same record, now declared in YAML as `- name: nonamesecurity` |
| Config content | 9 services, 9 routes, 9 rate limits + global `nonamesecurity` | **identical** (decK diff 0 / 0 / 0) |

Unchanged: Postgres container `kong-db` + volume, network `kongnet`, ports `80`/`8001`, DB
password in `/opt/kong/kong-db-password` (root, 600), `podman-restart.service` enabled
(containers come back at boot). SELinux is **disabled** and firewalld **inactive** on this
host, as they were before.

## What was done

1. **decK v1.69.0** → `/usr/local/bin/deck` (sha256 checked). Repo cloned to
   `~/kong_withDB_install_with_noname_integration_ubuntu_docker`.
2. **Full backup first:** `deck gateway dump` → `~/kong-backups/kong-pre-deck-20261030-224356.yaml`
   (mode 600: it includes Noname's settings, **source key** included).
3. Wrote [`deck-100/kong.yaml`](deck-100/kong.yaml) (9 apps + `plugins: - name: nonamesecurity`).
   `./kong-config.sh diff` = **0 / 0 / 0**, so the YAML describes the live gateway exactly.
   Nothing was changed by taking over.
4. **Built the image** from the plugin files the gateway was already running:
   `~/kong-noname-build/` = the repo's [`../noname-image/Dockerfile`](../noname-image/Dockerfile)
   + a copy of `/opt/kong/plugins/nonamesecurity` (folder mode 700) →
   `sudo podman build --format docker -t kong-noname:3.6-5.0.1 .`. The 6 `.lua` files in the
   image are **sha256-identical** to `/opt`, readable (`-rw-r--r--`), and Kong's
   `HEALTHCHECK` is kept.
5. **Recreated `kong`** from the image with the same settings and no mount. The Admin API
   was back in **3 s**. Every app answered the same before and after (all 200,
   jenkins 403 = Jenkins' own anonymous-access reply).

Checks after the switch: `(healthy)`. `enabled_in_cluster` = `rate-limiting, nonamesecurity`.
Rate-limit headers present. 0 `[error]`/`[crit]`/`[NONAME]` log lines under traffic. The
Noname engine is reachable from the host (200). decK diff 0 before and after a
`podman restart kong`. The LAN reaches the gateway (from .98).

> Check the **API Security UI** (Settings > Integrations) to confirm that .100's traffic is
> still arriving after the switch.

---

## Changing config (routes, services, plugins…)

The same YAML workflow as the other gateways. The cookbook is in
[`../ubuntu-docker/deck-yaml-config.md`](../ubuntu-docker/deck-yaml-config.md#cookbook).
Apply is a **full sync**: anything not in `deck-100/kong.yaml` is deleted, **including the
`nonamesecurity` entry if someone removes it**. Keep that entry.

.100 has **no GitHub credentials**, so edit on .98 (or ubuntu-1..3) and push, then on .100:

```bash
ssh mcropsey@192.168.1.100
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker && git pull
cd rhel-podman/deck-100
./kong-config.sh diff          # read it: nothing unexpected deleted
./kong-config.sh apply         # backs up to ~/kong-backups, asks y/N, syncs
```

Or apply from .98 directly once decK is installed there:
`KONG_ADDR=http://192.168.1.100:8001 rhel-podman/deck-100/kong-config.sh diff`.

## Rebuilding the Noname image (new plugin version, or a `schema.lua` change)

Most Noname settings (timeouts, batch size, prevention on/off…) are managed in the **API
Security UI** and need no rebuild. Rebuild only for **a new plugin version / new integration
profile** (new zip) or a **`schema.lua`-only setting** (e.g. `NN_DEBUG_ENABLED`). The YAML
entry never changes.

```bash
ssh mcropsey@192.168.1.100
cd ~/kong-noname-build

# 1. new files: replace the WHOLE folder from the new zip (never merge)
rm -rf kong/plugins/nonamesecurity
cp -r ~/<unzipped-new-download>/kong/plugins/nonamesecurity kong/plugins/
chmod -R go-rwx ~/kong-noname-build
grep NN_VERSION kong/plugins/nonamesecurity/schema.lua            # e.g. 5.0.2
#    (schema.lua-only change: edit kong/plugins/nonamesecurity/schema.lua here instead)

# 2. build a NEW tag (keep the old one for rollback)
sudo podman build --format docker -t kong-noname:3.6-5.0.2 .      # schema edit: e.g. 3.6-5.0.1-b

# 3. switch: recreates kong with the same settings, auto-rolls back if it doesn't come up
~/kong_withDB_install_with_noname_integration_ubuntu_docker/rhel-podman/kong-recreate-podman.sh kong-noname:3.6-5.0.2

# 4. confirm
sudo podman exec kong grep NN_VERSION /usr/local/share/lua/5.1/kong/plugins/nonamesecurity/schema.lua
cd ~/kong_withDB_install_with_noname_integration_ubuntu_docker/rhel-podman/deck-100 && ./kong-config.sh diff   # 0 / 0 / 0
```

[`kong-recreate-podman.sh`](kong-recreate-podman.sh) reads the DB password from
`/opt/kong/kong-db-password`, recreates `kong` with the same ports/env and
`KONG_PLUGINS=bundled,nonamesecurity`, and waits up to 60 s for the Admin API. If it
doesn't come up, it prints the log and **puts the previous container back** (image,
plugins and mounts). Tested on .103: a deliberately broken switch rolled back by itself in
about 70 s, and a normal switch took about 10 s.

## Rollback options

| To | Do |
|---|---|
| previous Noname build | `kong-recreate-podman.sh kong-noname:<previous-tag>` |
| the old mount-based setup | the original command (stock `kong:3.6` + `-v /opt/kong/plugins/nonamesecurity:...:ro`), still valid because `/opt/kong/plugins/nonamesecurity` was left in place |
| config before decK | `./kong-config.sh restore ~/kong-backups/kong-pre-deck-20261030-224356.yaml` |
| no Noname at all | remove the `nonamesecurity` entry from `kong.yaml` → apply **first**, then `PLUGINS=bundled kong-recreate-podman.sh docker.io/library/kong:3.6` |

## Files on .100

| Path | What |
|---|---|
| `~/kong-noname-build/` | image build folder: Dockerfile + plugin files (**source key**, mode 700) |
| `/opt/kong/plugins/nonamesecurity/` | the old mount source. No longer used by the container, kept for rollback |
| `~/noname-security-kong-policy/` | the unzipped vendor download (v5.0.1 + old v4.0.0 rock) |
| `/opt/kong/kong-db-password` | Postgres password (root, 600) |
| `~/kong-backups/` | decK dumps, one before every apply (**contain the source key**) |
| `~/kong_withDB_install_with_noname_integration/` | old clone of the original repo, not used |
| `~/kong_withDB_install_with_noname_integration_ubuntu_docker/` | this repo, which the YAML is applied from |

Never push the `kong-noname` image, and never commit the plugin folder or the backups.
