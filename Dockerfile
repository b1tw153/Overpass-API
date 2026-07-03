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

RUN mkdir -p /build/src/m4 "$OVERPASS_DIR/db" "$OVERPASS_DIR/diff" "$OVERPASS_DIR/backup" "$OVERPASS_DIR/log" "$OVERPASS_DIR/run" "$OVERPASS_DIR/static" "$OVERPASS_DIR/tmp" && \
    cd /build/src && \
    autoreconf -i && \
    CXXFLAGS='-O3' CFLAGS='-O3' ./configure --prefix="$OVERPASS_DIR" --enable-lz4 && \
    make -j$(nproc) install && \
    cp -pr /build/src/rules "$OVERPASS_DIR"

FROM debian:bookworm-slim

COPY --from=builder /opt/overpass /opt/overpass

RUN apt-get update && apt-get install -y --no-install-recommends \
    aria2 \
    bzip2 \
    ca-certificates \
    curl \
    fcgiwrap \
    gettext-base \
    inotify-tools \
    libexpat1 \
    liblz4-1 \
    logrotate \
    munin-node \
    nginx \
    osmium-tool \
    rsync \
    tini \
    zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && rm /etc/nginx/sites-enabled/default \
    && groupadd -g 10001 overpass \
    && useradd -u 10001 -g 10001 -m -s /bin/bash overpass \
    && chown -R overpass:overpass /opt/overpass

COPY etc/nginx.conf.template /etc/nginx/nginx.conf.template
RUN chown overpass:overpass /etc/nginx/nginx.conf.template \
    && chown overpass:overpass /etc/nginx/nginx.conf

COPY --chown=overpass:overpass static/ /opt/overpass/static/

COPY etc/munin-node.conf.template /etc/munin/munin-node.conf.template
COPY src/munin/ /usr/share/munin/plugins/
RUN chmod +x /usr/share/munin/plugins/osm_db_lag \
             /usr/share/munin/plugins/osm_db_request_count \
             /usr/share/munin/plugins/osm_dispatcher \
             /usr/share/munin/plugins/osm_interpreter \
             /usr/share/munin/plugins/osm_mem_status \
             /usr/share/munin/plugins/osm_nginx_access \
             /usr/share/munin/plugins/osm_nginx_queue \
             /usr/share/munin/plugins/osm_nginx_status \
             /usr/share/munin/plugins/osm_timeout_status \
             /usr/share/munin/plugins/cgroup_cpu \
             /usr/share/munin/plugins/cgroup_memory \
             /usr/share/munin/plugins/cgroup_swap \
             /usr/share/munin/plugins/container_uptime \
    && rm -f /etc/munin/plugins/* \
    && for plugin in df \
                     df_inode \
                     forks \
                     threads \
                     osm_db_lag \
                     osm_db_request_count \
                     osm_dispatcher \
                     osm_interpreter \
                     osm_nginx_access \
                     osm_nginx_queue \
                     osm_nginx_status \
       ; do \
         ln -s "/usr/share/munin/plugins/$plugin" "/etc/munin/plugins/$plugin"; \
       done \
    && ln -s /usr/share/munin/plugins/cgroup_cpu       /etc/munin/plugins/cpu \
    && ln -s /usr/share/munin/plugins/cgroup_memory    /etc/munin/plugins/memory \
    && ln -s /usr/share/munin/plugins/cgroup_swap      /etc/munin/plugins/swap \
    && ln -s /usr/share/munin/plugins/container_uptime /etc/munin/plugins/uptime \
    && chown -R overpass:overpass /etc/munin /var/lib/munin-node

ENV OVERPASS_BIN_DIR="/opt/overpass/bin"

ENV OVERPASS_DB_DIR="/opt/overpass/db"

ENV OVERPASS_DIFF_DIR="/opt/overpass/diff"

ENV OVERPASS_BACKUP_DIR="/opt/overpass/backup"

ENV OVERPASS_LOG_DIR="/opt/overpass/log"

USER overpass

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/overpass/bin/entrypoint.sh"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -fsS http://localhost:8080/api/status
