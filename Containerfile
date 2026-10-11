# pi-podman image — minimal tooling for Pi inside a rootless container.
# Pi itself, credentials, settings, and sessions are bind-mounted from the
# host at run time (same version and history as the host installation).
FROM docker.io/library/node:24-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates git ripgrep less procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
