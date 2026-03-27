FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    libexpat1-dev \
    liblz4-dev \
    libtool \
    m4 \
    pkg-config \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY src /build/src

ENV OVERPASS_DIR=/opt/overpass

RUN mkdir -p /build/src/m4 "$OVERPASS_DIR/db" "$OVERPASS_DIR/diff" "$OVERPASS_DIR/backup" "$OVERPASS_DIR/log" "$OVERPASS_DIR/run" "$OVERPASS_DIR/tmp" && \
    cd /build/src && \
    autoreconf -i && \
    CXXFLAGS='-O2' CFLAGS='-O2' ./configure --prefix="$OVERPASS_DIR" --enable-lz4 && \
    make -j$(nproc) install && \
    cp -pr /build/src/rules "$OVERPASS_DIR/db/"

FROM debian:bookworm-slim

COPY --from=builder /opt/overpass /opt/overpass

RUN apt-get update && apt-get install -y --no-install-recommends \
    aria2 \
    bzip2 \
    ca-certificates \
    curl \
    fcgiwrap \
    libexpat1 \
    liblz4-1 \
    logrotate \
    nginx \
    osmium-tool \
    tini \
    zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && rm /etc/nginx/sites-enabled/default \
    && groupadd -g 10001 overpass \
    && useradd -u 10001 -g 10001 -m -s /bin/bash overpass \
    && chown -R overpass:overpass /opt/overpass

COPY etc/nginx.conf /etc/nginx/nginx.conf

ENV OVERPASS_DB_DIR="/opt/overpass/db"

ENV OVERPASS_DIFF_DIR="/opt/overpass/diff"

ENV OVERPASS_BACKUP_DIR="/opt/overpass/backup"

ENV OVERPASS_LOG_DIR="/opt/overpass/log"

USER overpass

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/overpass/bin/entrypoint.sh"]
