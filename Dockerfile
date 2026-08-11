# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.24
ARG TRIVY_VERSION=0.73.0
ARG BUSYBOX_VERSION=1.38.0
ARG GO_VERSION=1.26.5
ARG ACFS_VERSION=0.4.0

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS acfs-fetcher
ARG TARGETARCH
ARG TARGETVARIANT
ARG ACFS_VERSION

RUN apk add --no-cache ca-certificates curl

WORKDIR /work

RUN case "${TARGETARCH}/${TARGETVARIANT}" in \
    amd64/*) acfs_arch='amd64' ;; \
    386/*) acfs_arch='386' ;; \
    arm64/*) acfs_arch='arm64' ;; \
    arm/v7) acfs_arch='armv7' ;; \
    ppc64le/*) acfs_arch='ppc64le' ;; \
    s390x/*) acfs_arch='s390x' ;; \
    *) echo "unsupported TARGETARCH/TARGETVARIANT: ${TARGETARCH}/${TARGETVARIANT}" >&2; exit 1 ;; \
    esac && \
    acfs_file="acfs_linux_${acfs_arch}" && \
    release_url="https://github.com/getarcaneapp/acfs/releases/download/v${ACFS_VERSION}" && \
    curl -fsSLO "${release_url}/${acfs_file}" && \
    curl -fsSL "${release_url}/acfs_checksums.txt" -o acfs_checksums.txt && \
    grep "  ${acfs_file}$" acfs_checksums.txt | sha256sum -c - && \
    install -Dm755 "${acfs_file}" /out/usr/local/bin/acfs

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS trivy-fetcher
ARG TARGETARCH
ARG TARGETVARIANT
ARG TRIVY_VERSION

RUN apk add --no-cache ca-certificates curl tar

WORKDIR /work

COPY checksums/trivy.txt /checksums/trivy_checksums.txt

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

COPY checksums/busybox.sha256 /checksums/busybox.tar.bz2.sha256
COPY dist/busybox.config /tmp/busybox.config
COPY dist/applets.txt /tmp/applets.txt

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
    yes n | make oldconfig

RUN make -j"$(getconf _NPROCESSORS_ONLN)"

RUN install -Dm755 busybox /out/bin/busybox && \
    mkdir -p /out/tmp /out/root/.cache && \
    while IFS= read -r applet; do \
      [ -n "${applet}" ] || continue; \
      ln -s /bin/busybox "/out/bin/${applet}"; \
    done < /tmp/applets.txt && \
    chmod 1777 /out/tmp

FROM scratch AS busybox-runtime
COPY --from=busybox-builder /out/bin/ /bin/
COPY --from=busybox-builder /out/tmp /tmp
COPY --from=busybox-builder /out/root/.cache /root/.cache

ENV PATH="/usr/local/bin:/bin" \
    SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
    TMPDIR="/tmp" \
    XDG_CACHE_HOME="/root/.cache"

ENTRYPOINT []

FROM busybox-runtime

ARG GO_VERSION
ARG ACFS_VERSION

LABEL app.getarcane.tools.acfs.version="${ACFS_VERSION}" \
    app.getarcane.tools.acfs.go-version="${GO_VERSION}"

COPY --from=trivy-fetcher /out/usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=trivy-fetcher /out/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=acfs-fetcher /out/usr/local/bin/acfs /usr/local/bin/acfs
