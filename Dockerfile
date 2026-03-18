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

# Need to update configure.ac and Makefile.am before continuing
