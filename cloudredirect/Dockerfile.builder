# Reproducible builder for the bundled 32-bit cloud_redirect.so.
#
# Ubuntu 22.04 ships glibc 2.35, old enough that the resulting auditor/preload
# library loads inside the Steam runtime (building on a host with glibc >= 2.38
# injects a GLIBC_ABI_GNU_TLS dependency the Steam runtime cannot resolve).
# g++-12 is used because upstream json.h relies on a recursive incomplete-type
# container that gcc-11 rejects but gcc-12+ accepts.
FROM ubuntu:22.04

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates git \
      cmake make \
      g++-12 gcc-12 g++-12-multilib gcc-12-multilib \
      libc6-dev-i386 linux-libc-dev linux-libc-dev:i386 \
 && rm -rf /var/lib/apt/lists/*

ENV CC=gcc-12 CXX=g++-12
