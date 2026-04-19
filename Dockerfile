# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.23
ARG TRIVY_VERSION=0.70.0
ARG BUSYBOX_VERSION=1.37.0

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS trivy-fetcher
ARG TARGETARCH
ARG TARGETVARIANT
ARG TRIVY_VERSION

RUN apk add --no-cache ca-certificates curl tar

WORKDIR /work

COPY checksums/trivy_0.70.0_checksums.txt /checksums/trivy_checksums.txt

RUN case "${TARGETARCH}/${TARGETVARIANT}" in \
    amd64/*) trivy_arch='64bit' ;; \
    386/*) trivy_arch='32bit' ;; \
    arm64/*) trivy_arch='ARM64' ;; \
    arm/v7) trivy_arch='ARM' ;; \
    ppc64le/*) trivy_arch='PPC64LE' ;; \
    s390x/*) trivy_arch='s390x' ;; \
    *) echo "unsupported TARGETARCH/TARGETVARIANT: ${TARGETARCH}/${TARGETVARIANT}" >&2; exit 1 ;; \
    esac && \
    trivy_file="trivy_${TRIVY_VERSION}_Linux-${trivy_arch}.tar.gz" && \
    curl -fsSLO "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${trivy_file}" && \
    grep "  ${trivy_file}$" /checksums/trivy_checksums.txt | sha256sum -c - && \
    tar -xzf "${trivy_file}" trivy && \
    install -Dm755 trivy /out/usr/local/bin/trivy && \
    install -Dm644 /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt

FROM alpine:${ALPINE_VERSION} AS busybox-builder
ARG BUSYBOX_VERSION

RUN apk add --no-cache build-base bzip2 curl linux-headers perl

WORKDIR /work

COPY checksums/busybox-1.37.0.tar.bz2.sha256 /checksums/busybox.tar.bz2.sha256
COPY busybox.config /tmp/busybox.config

RUN curl -fsSLO "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" && \
    sha256sum -c /checksums/busybox.tar.bz2.sha256 && \
    tar -xjf "busybox-${BUSYBOX_VERSION}.tar.bz2"

WORKDIR /work/busybox-${BUSYBOX_VERSION}

RUN make allnoconfig && \
    while IFS='=' read -r key value; do \
      [ -n "${key}" ] || continue; \
      sed -i \
        -e "/^${key}=.*/d" \
        -e "/^# ${key} is not set/d" \
        .config && \
      printf '%s=%s\n' "${key}" "${value}" >> .config; \
    done < /tmp/busybox.config && \
    yes "" | make oldconfig

RUN make -j"$(getconf _NPROCESSORS_ONLN)"

RUN install -Dm755 busybox /out/bin/busybox && \
    mkdir -p /out/usr/local/bin /out/tmp /out/root/.cache && \
    ln -s /bin/busybox /out/bin/sh && \
    ln -s /bin/busybox /out/bin/sleep && \
    ln -s /bin/busybox /out/bin/find && \
    ln -s /bin/busybox /out/bin/stat && \
    ln -s /bin/busybox /out/bin/readlink && \
    ln -s /bin/busybox /out/bin/head && \
    ln -s /bin/busybox /out/bin/rm && \
    ln -s /bin/busybox /out/bin/mkdir && \
    ln -s /bin/busybox /out/bin/mv && \
    ln -s /bin/busybox /out/bin/rmdir && \
    ln -s /bin/busybox /out/bin/mktemp && \
    ln -s /bin/busybox /out/bin/tar && \
    ln -s /bin/busybox /out/bin/test && \
    chmod 1777 /out/tmp

FROM scratch

COPY --from=busybox-builder /out/ /
COPY --from=trivy-fetcher /out/ /

ENV PATH="/usr/local/bin:/bin" \
    SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
    TMPDIR="/tmp" \
    XDG_CACHE_HOME="/root/.cache"

ENTRYPOINT []
