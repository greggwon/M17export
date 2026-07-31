# syntax=docker/dockerfile:1.7
# =============================================================================
# mrefd - M17 reflector daemon
# Two-stage build: compile against Debian 12, run on Debian 12 slim.
# Multi-arch friendly (linux/amd64, linux/arm64, linux/arm/v7) via buildx.
# =============================================================================

# --- build stage -------------------------------------------------------------
FROM debian:12-slim AS build

ARG MREFD_BUILD_DEBUG=false
ARG MREFD_BUILD_DHT=true

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        g++ \
        libcurl4-gnutls-dev \
        libopendht-dev \
        nlohmann-json3-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Copy the mrefd source tree (the submodule) into the build context.
COPY mrefd/ /src/

# Upstream bug: users.cpp:53 uses '>>' (shift) where '>' (compare) was intended
# when trimming the last-heard list to LASTHEARD_USERS_MAX_SIZE (=40).
# On 64-bit the compiler stays silent but the resize never fires (list grows
# unbounded). On 32-bit ARM the shift-count overflow trips -Werror.
# Reported/PR upstream; patched here so the fix takes effect on every arch.
RUN sed -i 's|m_Users\.size() >> LASTHEARD_USERS_MAX_SIZE|m_Users.size() > LASTHEARD_USERS_MAX_SIZE|' /src/users.cpp

# Render a compile-time mrefd.mk from the build args.
# BINDIR and CFGDIR are the in-container install paths.
RUN cat > /src/mrefd.mk <<EOF
USESYMLINK = false
BINDIR = /usr/local/bin
CFGDIR = /etc/mrefd
DEBUG = ${MREFD_BUILD_DEBUG}
DHT = ${MREFD_BUILD_DHT}
DAEMON = false
EOF

RUN make -j"$(nproc)" && \
    strip mrefd && \
    install -Dm755 mrefd /out/usr/local/bin/mrefd


# --- runtime stage -----------------------------------------------------------
FROM debian:12-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# libopendht is only needed if the binary was built with DHT=true. Installing
# it unconditionally keeps the image single-variant and avoids a dead-code
# apt-get invocation; it costs ~2MB.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libopendht2 \
        libcurl3-gnutls \
        ca-certificates \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1000 mrefd \
    && useradd  --system --uid 1000 --gid mrefd --home-dir /var/lib/mrefd \
                --shell /usr/sbin/nologin mrefd \
    && mkdir -p /etc/mrefd /var/lib/mrefd /var/log/mrefd /var/run/mrefd \
    && chown -R mrefd:mrefd /etc/mrefd /var/lib/mrefd /var/log/mrefd /var/run/mrefd

COPY --from=build /out/usr/local/bin/mrefd /usr/local/bin/mrefd
COPY docker/mrefd/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER mrefd

# UDP - M17 protocol (default 17000)
EXPOSE 17000/udp
# UDP - Ham-DHT peer discovery
EXPOSE 17171/udp

# tini reaps zombies and forwards signals so `docker stop` shuts mrefd down cleanly.
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
