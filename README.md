# Kong (DB mode) + Noname integration — **Ubuntu / Docker edition**

Fork of [kong_withDB_install_with_noname_integration](https://github.com/mcropsey/kong_withDB_install_with_noname_integration),
which targets Rocky Linux (RHEL-family) with rootful Podman. This repo adds an
**Ubuntu 24.04 + Docker** version of both guides in [`ubuntu-docker/`](ubuntu-docker/).

| Path | Platform | What |
|---|---|---|
| [`ubuntu-docker/kong-ubuntu-docker.md`](ubuntu-docker/kong-ubuntu-docker.md) | Ubuntu 24.04 + Docker | Kong 3.6 + Postgres 16, 9 services/routes/rate limits, ops |
| [`ubuntu-docker/noname-kong-install-ubuntu-docker.md`](ubuntu-docker/noname-kong-install-ubuntu-docker.md) | Ubuntu 24.04 + Docker | Noname `nonamesecurity` v5.0.1 plugin on that gateway |
| [`ubuntu-docker/configure-kong.sh`](ubuntu-docker/configure-kong.sh) | any | Creates the 9 services + routes + rate limits via the Admin API |
| [`kong.md`](kong.md) | Rocky Linux + Podman | original base-gateway guide (192.168.1.104) |
| [`noname_kong_install.md`](noname_kong_install.md) | Rocky Linux + Podman | original Noname plugin guide (192.168.1.104) |

## Reference deployment

Deployed and verified on **192.168.1.91** (`ubuntu-1`, Ubuntu 24.04.5 LTS, Docker 29.1.3)
on 2026-10-30:

- proxy `http://192.168.1.91/` (port 80), Admin API `http://192.168.1.91:8001/`
- Kong 3.6.1, DB reachable, 9 services / 9 routes / 9 rate-limiting plugins
- every route answers through the proxy (jenkins answers 403, which is Jenkins' own anonymous-access response)
- config survives `docker restart kong`
- Noname plugin: **not installed yet**, waiting on the integration-profile Lua files

The main differences from RHEL/Podman (Docker instead of Podman, no SELinux/firewalld,
ufw vs. Docker port publishing, DNS on user-defined networks, password handling, the ~5 s
router rebuild delay) are listed at the top of each Ubuntu guide.
