# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.23
ARG TRIVY_VERSION=0.72.0
ARG BUSYBOX_VERSION=1.37.0
ARG RUSTIC_VERSION=0.11.2

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

FROM --platform=$TARGETPLATFORM alpine:${ALPINE_VERSION} AS rustic-builder
ARG TARGETARCH
ARG TARGETVARIANT
ARG RUSTIC_VERSION

RUN case "${TARGETARCH}" in \
      amd64|arm64) apk add --no-cache ca-certificates curl tar ;; \
      arm) apk add --no-cache build-base cargo mold musl-dev rust ;; \
      ppc64le|s390x) apk add --no-cache build-base cargo mimalloc2 mold musl-dev rust ;; \
      *) apk add --no-cache build-base cargo musl-dev rust ;; \
    esac

ENV CARGO_HOME=/cargo \
    CARGO_TARGET_DIR=/cargo/target \
    CARGO_PROFILE_RELEASE_LTO=thin \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16

# Rustic publishes static musl binaries for amd64 and arm64. Other release
# architectures are either absent or glibc-linked, so those retain a source
# build. Depot persists the Cargo cache mounts for those fallback builds.
# The final binary link is handled directly because sccache cannot cache it.
# Alpine's Scudo-linked Rust tools abort under QEMU, so preload mimalloc for the
# emulated ppc64le/s390x builds. Disable LTO and use mold on every emulated
# architecture to keep final links inside the publish job timeout. arm/v7,
# ppc64le, and s390x also use light release optimization because full
# optimization exceeds that limit under emulation.
RUN --mount=type=cache,id=rustic-registry-${TARGETARCH}-${TARGETVARIANT},target=/cargo/registry,sharing=locked \
    --mount=type=cache,id=rustic-git-${TARGETARCH}-${TARGETVARIANT},target=/cargo/git,sharing=locked \
    --mount=type=cache,id=rustic-target-${TARGETARCH}-${TARGETVARIANT},target=/cargo/target,sharing=locked \
    mkdir -p /out/lib /out/usr/lib && \
    case "${TARGETARCH}" in \
      amd64) \
        rustic_target='x86_64-unknown-linux-musl'; \
        rustic_sha256='ff5954015236b21d121d43c6a9d690c21613c0a1ea42a767604ba17eec266bd3' \
        ;; \
      arm64) \
        rustic_target='aarch64-unknown-linux-musl'; \
        rustic_sha256='05e9cb88075f62e6cbed304133d4f54f268a38e7d25a5a6844ee366ac87e87ce' \
        ;; \
      *) \
        rustic_target=''; \
        rustic_sha256='' \
        ;; \
    esac && \
    if [ -n "${rustic_target}" ]; then \
      rustic_file="rustic-v${RUSTIC_VERSION}-${rustic_target}.tar.gz"; \
      curl -fsSLO "https://github.com/rustic-rs/rustic/releases/download/v${RUSTIC_VERSION}/${rustic_file}"; \
      printf '%s  %s\n' "${rustic_sha256}" "${rustic_file}" | sha256sum -c -; \
      tar -xzf "${rustic_file}" rustic; \
      install -Dm755 rustic /out/bin/rustic; \
    else \
      if [ "${TARGETARCH}" = 'ppc64le' ] || [ "${TARGETARCH}" = 's390x' ]; then \
        export LD_PRELOAD=/usr/lib/libmimalloc.so.2; \
      fi; \
      if [ "${TARGETARCH}" = 'arm' ] || [ "${TARGETARCH}" = 'ppc64le' ] || [ "${TARGETARCH}" = 's390x' ]; then \
        export CARGO_PROFILE_RELEASE_LTO=false; \
        export RUSTFLAGS='-C link-arg=-fuse-ld=mold'; \
      fi; \
      if [ "${TARGETARCH}" = 'arm' ] || [ "${TARGETARCH}" = 'ppc64le' ] || [ "${TARGETARCH}" = 's390x' ]; then \
        export CARGO_PROFILE_RELEASE_OPT_LEVEL=1; \
      fi; \
      cargo install --locked --version "${RUSTIC_VERSION}" --root /out rustic-rs; \
      strip /out/bin/rustic; \
      cp /lib/ld-musl-*.so.1 /out/lib/; \
      cp /usr/lib/libgcc_s.so.1 /out/usr/lib/; \
    fi

FROM scratch

COPY --from=busybox-builder /out/bin/ /bin/
COPY --from=busybox-builder /out/tmp /tmp
COPY --from=busybox-builder /out/root/.cache /root/.cache
COPY --from=trivy-fetcher /out/usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=rustic-builder /out/bin/rustic /usr/local/bin/rustic
COPY --from=rustic-builder /out/lib/ /lib/
COPY --from=rustic-builder /out/usr/lib/ /usr/lib/
COPY --from=trivy-fetcher /out/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

ENV PATH="/usr/local/bin:/bin" \
    SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt" \
    TMPDIR="/tmp" \
    XDG_CACHE_HOME="/root/.cache"

ENTRYPOINT []
