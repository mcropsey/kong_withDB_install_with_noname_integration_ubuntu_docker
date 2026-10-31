# Kong 3.6 with the Noname "nonamesecurity" plugin built in (the vendor-recommended install).
#
# Build context = a folder holding this Dockerfile plus the zip's plugin folder:
#   <build-dir>/Dockerfile
#   <build-dir>/kong/plugins/nonamesecurity/*.lua      (from the integration-profile zip)
#
#   docker build -t kong-noname:3.6-5.0.1 .                          # Ubuntu / Docker
#   sudo podman build --format docker -t kong-noname:3.6-5.0.1 .    # RHEL / rootful Podman
#
# Tag = <kong version>-<plugin version>. Build a NEW tag for every plugin update and keep the old
# one for rollback.
#
# The image contains schema.lua, which holds the integration's SOURCE KEY. Keep the image
# on the gateway host: never push it to a public registry, never commit the plugin folder.
#
# The base MUST match the Kong version the Postgres DB was migrated for (kong:3.6 = 3.6.1).
# The vendor doc's "kong/kong-gateway:3.14" is the Enterprise image: don't use it here.
FROM docker.io/library/kong:3.6

USER root
COPY kong/plugins/nonamesecurity /usr/local/share/lua/5.1/kong/plugins/nonamesecurity
# the zip/unzip can leave files 0600 (unreadable by the kong user); make them world-readable
RUN chmod -R a+rX /usr/local/share/lua/5.1/kong/plugins/nonamesecurity
USER kong
