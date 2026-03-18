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

RUN mkdir -p /build/src/m4 "$OVERPASS_DIR/db" "$OVERPASS_DIR/diff" && \
    cd /build/src && \
    autoreconf -i && \
    CXXFLAGS='-O2' CFLAGS='-O2' ./configure --prefix="$OVERPASS_DIR" --enable-lz4 && \
    make install && \
    cp -pr /build/src/rules "$OVERPASS_DIR/db/"

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    fcgiwrap \
    libexpat1 \
    liblz4-1 \
    nginx \
    tini \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/overpass /opt/overpass

COPY etc/overpass.conf /etc/nginx/conf.d/

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/overpass/bin/entrypoint.sh"]
