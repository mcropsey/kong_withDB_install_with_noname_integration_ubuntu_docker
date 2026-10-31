# Kong on 192.168.1.103 (Rocky Linux 10.2 + rootful Podman) — deployment record

Kong 3.6.1 (DB mode, Postgres 16) was deployed on **192.168.1.103** (`hv-rocky-linux-6`,
also `server1` of the RHCSA practice set) on 2026-10-30, following the original RHEL guide
[`../kong.md`](../kong.md). After Step 8, the config was handed over to **decK**, so
[`deck/kong.yaml`](deck/kong.yaml) is now the source of truth. See
[`deck-yaml-config-rhel.md`](deck-yaml-config-rhel.md).

| Item | Value on .103 |
|---|---|
| OS | Rocky Linux 10.2 (Red Quartz), kernel 6.12 |
| Podman | 5.8.2 (rootful, `sudo podman`), netavark networking |
| Containers | `kong` (`docker.io/library/kong:3.6`), `kong-db` (`docker.io/library/postgres:16`), both `--restart unless-stopped` |
| Network / volume | `kongnet` 10.90.0.0/24 (`dns_enabled: true`), volume `kong-db-data` |
| Endpoints | proxy `http://192.168.1.103/`, Admin API `http://192.168.1.103:8001/` |
| DB password | `~/.kong-db-password` (mode 600, user `mcropsey`) |
| Config | 9 services / 9 routes / 9 rate limits, managed by `deck/kong.yaml` |
| SELinux | **Enforcing** (unchanged) |
| firewalld | **active** (unchanged) |

## Steps followed, and where they differ from `kong.md`

| `kong.md` step | What was done on .103 |
|---|---|
| **1 — Host prep** (disable firewalld, SELinux permissive) | **Not done. SELinux stays Enforcing, firewalld stays running.** See below |
| 2 — `kongnet` network | as written (`dns_enabled: true`) |
| 3 — pull images | as written |
| 4 — Postgres | as written, plus the password saved to `~/.kong-db-password` (mode 600) so later steps and decK sessions don't depend on one shell's `$PW`. Readiness was checked with `pg_isready` |
| 5 — migrations | as written: `64 migrations processed / 64 executed / Database is up-to-date` |
| 6 — Kong | as written |
| 7 — baseline checks | db reachable, version 3.6.1, 0 services, unknown host → 404, no `[error]`/`[crit]` log lines |
| 8 — config | the same 27 Admin API calls, run with [`../ubuntu-docker/configure-kong.sh`](../ubuntu-docker/configure-kong.sh). Then decK took over (`deck gateway diff` against `deck/kong.yaml` = 0/0/0) |
| 9 — verify | 9/9/9. All hosts 200 except jenkins **403** (Jenkins' own anonymous-access reply, `Server: Jetty`). `X-RateLimit-*` headers present. Reachable from .98 |
| *(extra)* boot persistence | `sudo systemctl enable podman-restart.service`. See below |

### Why Step 1 was skipped (and why Kong works anyway)

Turning off SELinux and the firewall on this box was blocked by the assistant's
security-policy check. It's also part of an RHCSA practice set, where you want SELinux
enforcing. It turned out not to be needed:

- **SELinux:** Postgres keeps its data in a Podman **named volume** (`kong-db-data`), which
  Podman labels correctly by itself. Kong has no host mounts. After deploy, restart and
  decK sync, `getenforce` = `Enforcing`, with **0 AVC denials** in the kernel log.
- **firewalld:** Podman's netavark sets up the published-port DNAT/forward rules itself, so
  ports 80 and 8001 were reachable from the LAN **with firewalld running and no ports
  added** to the `public` zone (which lists only `cockpit dhcpv6-client ssh`). Like
  Docker vs. ufw on Ubuntu, this means **firewalld does not protect the Admin API.**
  To restrict it, recreate the `kong` container with `-p 127.0.0.1:8001:8001`.

**Noname plugin:** install it with the custom-image method in
[`noname-kong-install-rhel.md`](noname-kong-install-rhel.md). It needs no host mount, so it
also needs no SELinux change. This was tested on .103 with a dummy stand-in plugin, with
SELinux enforcing. (If you ever use the older folder-mount method from
[`../noname_kong_install.md`](../noname_kong_install.md) here, SELinux enforcing blocks the
mount unless you add `Z`: `...:ro,Z`.)

### Containers coming back after a reboot

With Podman, `--restart unless-stopped` only applies after a reboot if
**`podman-restart.service`** is enabled. There's no always-running daemon like `dockerd`.
It was disabled on .103, and `kong.md` doesn't mention it:

```bash
sudo systemctl enable podman-restart.service
systemctl is-enabled podman-restart.service     # enabled
```

## Day-to-day

All config changes now go through YAML. See [`deck-yaml-config-rhel.md`](deck-yaml-config-rhel.md).
Container ops (logs, restart, upgrades, teardown) are as in [`../kong.md`](../kong.md#ops-quick-reference),
with the DB password from `~/.kong-db-password`.
